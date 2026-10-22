/// HTTP client for the Frogster REST API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../crypto/crypto_engine.dart';
import '../../crypto/primitives.dart';
import '../../crypto/x3dh.dart';
import '../models/models.dart';
import 'server_config.dart';

/// Raised for any non-success response.
class ApiException implements Exception {
  const ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  /// True when the server asked us to slow down. Callers should back off
  /// rather than retry immediately.
  bool get isRateLimited => statusCode == 429;

  /// True when the access token was rejected and a refresh is needed.
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Tokens returned by register and login.
class AuthTokens {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.userId,
    required this.deviceId,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String userId;
  final String deviceId;
  final DateTime expiresAt;
}

/// A user's published key bundles, one per active device.
class KeyBundles {
  const KeyBundles({
    required this.userId,
    required this.username,
    required this.bundles,
  });

  final String userId;
  final String username;
  final List<PreKeyBundle> bundles;
}

/// A chat as the server reports it.
class RemoteChat {
  const RemoteChat({
    required this.id,
    required this.type,
    required this.mode,
    required this.epoch,
    required this.title,
    required this.role,
    required this.lastSeq,
    required this.lastReadSeq,
    required this.peerReadSeq,
    required this.unread,
    required this.members,
    this.last,
  });

  final String id;
  final String type;
  final ChatMode mode;
  final int epoch;

  /// A cloud group's title; empty for everything else.
  final String title;
  final String role;
  final int lastSeq;
  final int lastReadSeq;
  final int peerReadSeq;
  final int unread;
  final List<ChatMember> members;

  /// A cloud chat's newest message.
  final RemoteMessage? last;

  bool get isGroup => type == 'group';

  static RemoteChat fromJson(Map<String, dynamic> json) => RemoteChat(
        id: json['id'] as String,
        type: json['type'] as String,
        mode: ChatMode.parse(json['mode'] as String?),
        epoch: json['epoch'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        role: json['role'] as String? ?? 'member',
        lastSeq: json['last_seq'] as int? ?? 0,
        lastReadSeq: json['last_read_seq'] as int? ?? 0,
        peerReadSeq: json['peer_read_seq'] as int? ?? 0,
        unread: json['unread'] as int? ?? 0,
        members: ((json['members'] as List<dynamic>?) ?? const [])
            .map((m) => ChatMember.fromJson(m as Map<String, dynamic>))
            .toList(),
        last: json['last'] == null
            ? null
            : RemoteMessage.fromJson(json['last'] as Map<String, dynamic>),
      );

  /// This chat as the signed-in user sees it, keeping what only this device
  /// knows -- its preview, a secret group's title -- from [local].
  Chat toChat(String selfUserId, {Chat? local}) {
    final peer = isGroup
        ? null
        : members.where((m) => m.userId != selfUserId).firstOrNull;
    return Chat(
      id: id,
      type: type,
      mode: mode,
      epoch: epoch,
      title: title.isNotEmpty ? title : local?.title,
      peerUsername: peer?.username ?? local?.peerUsername,
      peerDisplayName: peer?.displayName ?? local?.peerDisplayName,
      lastMessagePreview: local?.lastMessagePreview,
      lastMessageAt: local?.lastMessageAt,
      unreadCount: unread,
      members: members,
      role: role,
      peerReadSeq: peerReadSeq,
      syncedSeq: local?.syncedSeq ?? 0,
    );
  }
}

/// A cloud chat message as the server keeps it.
class RemoteMessage {
  const RemoteMessage({
    required this.id,
    required this.seq,
    required this.senderId,
    required this.senderDeviceId,
    required this.timestamp,
    this.kind = '',
    this.targetId,
    this.payload,
    this.editedAt,
    this.deleted = false,
    this.reactions = const {},
  });

  final String id;
  final int seq;
  final String senderId;
  final String senderDeviceId;
  final DateTime timestamp;
  final String kind;
  final String? targetId;

  /// The message as its author wrote it: a [MessagePayload] in JSON.
  final Uint8List? payload;
  final DateTime? editedAt;
  final bool deleted;
  final Map<String, Set<String>> reactions;

  static RemoteMessage fromJson(Map<String, dynamic> json) => RemoteMessage(
        id: json['id'] as String,
        seq: json['seq'] as int,
        senderId: json['sender_id'] as String,
        senderDeviceId: json['sender_device_id'] as String,
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['ts'] as int),
        kind: json['kind'] as String? ?? '',
        targetId: json['target_id'] as String?,
        payload: json['payload'] == null
            ? null
            : base64Decode(json['payload'] as String),
        editedAt: json['edited_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['edited_at'] as int),
        deleted: json['deleted'] as bool? ?? false,
        reactions: ((json['reactions'] as Map<String, dynamic>?) ?? const {})
            .map((emoji, users) => MapEntry(
                  emoji,
                  (users as List<dynamic>).cast<String>().toSet(),
                )),
      );
}

class ApiClient {
  ApiClient({required this.server, HttpClient? httpClient})
      : _http = httpClient ?? server.httpClient();

  final ServerConfig server;
  final HttpClient _http;

  String get baseUrl => server.baseUrl;

  /// Bearer token attached to authenticated requests.
  String? accessToken;
  DateTime? _accessExpiresAt;

  /// Long-lived token exchanged for new access tokens. Rotates on every use.
  String? refreshToken;

  /// Persists a rotated refresh token. Awaited before the new token is used:
  /// the old one is dead the moment the server rotates it, so losing the new
  /// one to a crash would sign the user out.
  Future<void> Function(String refreshToken)? onRefreshTokenRotated;

  final _sessionExpired = StreamController<void>.broadcast();

  /// Fires when the server rejects the refresh token: the session was
  /// revoked (signed out elsewhere, password changed) and only a new sign-in
  /// helps.
  Stream<void> get sessionExpired => _sessionExpired.stream;

  Future<AuthTokens>? _refreshing;

  /// An access token that will not expire in the next minute, refreshing it
  /// first when needed.
  Future<String> validAccessToken() async {
    final token = accessToken;
    final expires = _accessExpiresAt;
    if (token != null &&
        expires != null &&
        expires.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return token;
    }
    return (await refresh()).accessToken;
  }

  /// Exchanges the refresh token for new tokens.
  ///
  /// Concurrent callers share one request: two refreshes racing with the same
  /// token would look to the server exactly like a stolen token being
  /// replayed, and it would revoke the session.
  Future<AuthTokens> refresh() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<AuthTokens> _doRefresh() async {
    final token = refreshToken;
    if (token == null) {
      throw const ApiException(401, 'not signed in');
    }
    try {
      final json = await _send('POST', '/v1/token/refresh',
          {'refresh_token': token}, authenticated: false);
      final tokens = _tokensFrom(json);
      await onRefreshTokenRotated?.call(tokens.refreshToken);
      return tokens;
    } on ApiException catch (e) {
      if (e.isUnauthorized) {
        accessToken = null;
        refreshToken = null;
        _sessionExpired.add(null);
      }
      rethrow;
    }
  }

  /// Ends this device's session on the server. The device and its keys stay
  /// registered; signing in again resumes it.
  Future<void> logout() async {
    try {
      await _post('/v1/logout', const {});
    } finally {
      accessToken = null;
      refreshToken = null;
      _accessExpiresAt = null;
    }
  }

  /// Changes the password. Every other session of the account ends; this one
  /// continues with the returned tokens.
  Future<AuthTokens> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    final json = await _post('/v1/password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    });
    final tokens = _tokensFrom(json);
    await onRefreshTokenRotated?.call(tokens.refreshToken);
    return tokens;
  }

  /// Publishes a rotated signed prekey.
  Future<void> rotateSignedPreKey(SignedPreKeyUpload upload) async {
    await _send('PUT', '/v1/keys/signed', upload.toJson());
  }

  Future<AuthTokens> register({
    required String username,
    required String password,
    required String deviceName,
    required PublicKeyBundle keys,
  }) async {
    final json = await _send('POST', '/v1/register', authenticated: false, {
      'username': username,
      'password': password,
      'device': {
        'name': deviceName,
        ...keys.toJson(),
      },
    });
    return _tokensFrom(json);
  }

  /// Logs in, registering this installation as a new device when [keys] is
  /// given, or resuming an existing one via [deviceId].
  Future<AuthTokens> login({
    required String username,
    required String password,
    String? deviceName,
    PublicKeyBundle? keys,
    String? deviceId,
  }) async {
    final json = await _send('POST', '/v1/login', authenticated: false, {
      'username': username,
      'password': password,
      if (keys != null)
        'device': {
          'name': deviceName ?? 'unnamed device',
          ...keys.toJson(),
        },
      'device_id': ?deviceId,
    });
    return _tokensFrom(json);
  }

  /// A user's key bundles together with the account they belong to.
  ///
  /// The user id comes from the server rather than being inferred: message
  /// addressing needs it, and a client cannot derive it from a username.
  Future<KeyBundles> fetchKeys(String username, {String? deviceId}) async {
    final path = deviceId == null
        ? '/v1/keys/$username'
        : '/v1/keys/$username?device=$deviceId';
    final json = await _get(path);

    final bundles = (json['devices'] as List<dynamic>).map((raw) {
      final d = raw as Map<String, dynamic>;
      final spk = d['signed_pre_key'] as Map<String, dynamic>;
      final otp = d['one_time_pre_key'] as Map<String, dynamic>?;

      return PreKeyBundle(
        deviceId: d['device_id'] as String,
        registrationId: d['registration_id'] as int,
        identityKey: deserializePublicKey(base64Decode(d['identity_key'] as String)),
        identityKeyEd25519:
            base64Decode(d['identity_key_ed25519'] as String? ?? ''),
        signedPreKeyId: spk['key_id'] as int,
        signedPreKey: deserializePublicKey(base64Decode(spk['public_key'] as String)),
        signedPreKeySignature: base64Decode(spk['signature'] as String),
        oneTimePreKeyId: otp?['key_id'] as int?,
        oneTimePreKey: otp == null
            ? null
            : deserializePublicKey(base64Decode(otp['public_key'] as String)),
      );
    }).toList();

    return KeyBundles(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      bundles: bundles,
    );
  }

  /// Resolves a user id to a username.
  ///
  /// Inbound messages identify their sender by id, but replying needs the
  /// username to fetch key bundles.
  Future<String?> lookupUsername(String userId) async =>
      (await lookupUser(userId))?.username;

  /// A user's public profile, or null when there is no such user.
  Future<UserProfile?> lookupUser(String userId) async {
    try {
      return UserProfile.fromJson(await _get('/v1/users/$userId'));
    } on ApiException {
      return null;
    }
  }

  /// Reports how many one-time prekeys the server still holds for us.
  Future<({int available, bool shouldReplenish})> preKeyCount() async {
    final json = await _get('/v1/me/keys/count');
    return (
      available: json['available'] as int,
      shouldReplenish: json['should_replenish'] as bool,
    );
  }

  /// Uploads more one-time prekeys.
  Future<void> uploadPreKeys(Map<int, Uint8List> keys) async {
    await _post('/v1/keys', {
      'one_time_pre_keys': keys.entries
          .map((e) => {'key_id': e.key, 'public_key': base64Encode(e.value)})
          .toList(),
    });
  }

  /// Creates a chat, or returns the direct chat of that mode that already
  /// exists with [peer].
  ///
  /// A secret group's [title] is never sent: the server would learn it.
  /// It travels end to end instead, in the group's first message.
  Future<RemoteChat> createChat({
    required String type,
    required ChatMode mode,
    String? peer,
    List<String>? members,
    String? title,
  }) async {
    final json = await _post('/v1/chats', {
      'type': type,
      'mode': mode.name,
      'peer': ?peer,
      'members': ?members,
      if (mode == ChatMode.cloud && title != null) 'title': title,
    });
    return RemoteChat.fromJson(json);
  }

  /// Every chat the signed-in user belongs to.
  Future<List<RemoteChat>> listChats() async {
    final json = await _get('/v1/chats');
    return (json['chats'] as List<dynamic>)
        .map((c) => RemoteChat.fromJson(c as Map<String, dynamic>))
        .toList();
  }

  Future<RemoteChat> getChat(String chatId) async =>
      RemoteChat.fromJson(await _get('/v1/chats/$chatId'));

  /// A page of a cloud chat's history. With [after], everything after that
  /// seq in order, events included; otherwise the newest messages before
  /// [before] (or the end), newest first.
  Future<List<RemoteMessage>> chatMessages(
    String chatId, {
    int? before,
    int? after,
    int limit = 50,
  }) async {
    final query = [
      'limit=$limit',
      if (before != null) 'before=$before',
      if (after != null) 'after=$after',
    ].join('&');
    final json = await _get('/v1/chats/$chatId/messages?$query');
    return (json['messages'] as List<dynamic>)
        .map((m) => RemoteMessage.fromJson(m as Map<String, dynamic>))
        .toList();
  }

  Future<RemoteChat> renameChat(String chatId, String title) async =>
      RemoteChat.fromJson(
          await _send('PATCH', '/v1/chats/$chatId', {'title': title}));

  Future<RemoteChat> addMembers(String chatId, List<String> usernames) async =>
      RemoteChat.fromJson(
          await _post('/v1/chats/$chatId/members', {'members': usernames}));

  Future<RemoteChat> removeMember(String chatId, String userId) async =>
      RemoteChat.fromJson(
          await _delete('/v1/chats/$chatId/members/$userId'));

  Future<void> leaveChat(String chatId) =>
      _post('/v1/chats/$chatId/leave', const {});

  /// Hides a cloud chat's history so far from us, on every device.
  Future<void> clearChat(String chatId) =>
      _post('/v1/chats/$chatId/clear', const {});

  /// People whose username starts with [query].
  Future<List<UserProfile>> searchUsers(String query) async {
    final json =
        await _get('/v1/users/search?q=${Uri.encodeQueryComponent(query)}');
    return (json['users'] as List<dynamic>)
        .map((u) => UserProfile.fromJson(u as Map<String, dynamic>))
        .toList();
  }

  Future<UserProfile> me() async => UserProfile.fromJson(await _get('/v1/me'));

  /// Closes the account for good. The password is asked again even though
  /// the session is valid: a stolen token alone must not be enough.
  Future<void> deleteAccount(String password) =>
      _send('DELETE', '/v1/me', {'password': password});

  Future<UserProfile> updateMe({String? displayName, String? bio}) async =>
      UserProfile.fromJson(await _send('PATCH', '/v1/me', {
        'display_name': ?displayName,
        'bio': ?bio,
      }));

  Future<List<DeviceSession>> sessions() async {
    final json = await _get('/v1/sessions');
    return (json['sessions'] as List<dynamic>).map((raw) {
      final s = raw as Map<String, dynamic>;
      return DeviceSession(
        id: s['id'] as String,
        deviceId: s['device_id'] as String,
        userAgent: s['user_agent'] as String? ?? '',
        lastUsedAt: DateTime.parse(s['last_used_at'] as String),
        isCurrent: s['current'] as bool? ?? false,
      );
    }).toList();
  }

  Future<void> revokeSession(String sessionId) =>
      _delete('/v1/sessions/$sessionId');

  AuthTokens _tokensFrom(Map<String, dynamic> json) {
    final tokens = AuthTokens(
      accessToken: json['access_token'] as String,
      refreshToken: json['refresh_token'] as String,
      userId: json['user_id'] as String,
      deviceId: json['device_id'] as String,
      expiresAt: DateTime.parse(json['expires_at'] as String),
    );
    accessToken = tokens.accessToken;
    refreshToken = tokens.refreshToken;
    _accessExpiresAt = tokens.expiresAt;
    return tokens;
  }

  Future<Map<String, dynamic>> _get(String path) =>
      _send('GET', path, null);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send('POST', path, body);

  Future<Map<String, dynamic>> _delete(String path) =>
      _send('DELETE', path, null);

  /// Sends a request. Authenticated requests carry a fresh access token and
  /// are retried once with a refreshed token if the server still says 401 --
  /// it may have revoked the token early, for instance after a password
  /// change on another device.
  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    bool authenticated = true,
  }) async {
    final useRefresh = authenticated && refreshToken != null;
    if (useRefresh) await validAccessToken();
    try {
      return await _sendOnce(method, path, body, authenticated: authenticated);
    } on ApiException catch (e) {
      if (!useRefresh || !e.isUnauthorized) rethrow;
      await refresh();
      return _sendOnce(method, path, body, authenticated: authenticated);
    }
  }

  Future<Map<String, dynamic>> _sendOnce(
    String method,
    String path,
    Map<String, dynamic>? body, {
    required bool authenticated,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final request = await _http.openUrl(method, uri);

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (authenticated && accessToken != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $accessToken');
    }
    if (body != null) {
      request.write(jsonEncode(body));
    }

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();

    if (response.statusCode >= 400) {
      String message = text;
      try {
        message = (jsonDecode(text) as Map<String, dynamic>)['error'] as String;
      } catch (_) {
        // Not JSON; fall back to the raw body.
      }
      throw ApiException(response.statusCode, message);
    }

    if (text.isEmpty) return const {};
    return jsonDecode(text) as Map<String, dynamic>;
  }

  void close() {
    _http.close(force: true);
    _sessionExpired.close();
  }
}
