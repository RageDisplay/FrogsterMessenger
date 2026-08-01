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

class ApiClient {
  ApiClient({required this.baseUrl, HttpClient? httpClient})
      : _http = httpClient ?? HttpClient();

  final String baseUrl;
  final HttpClient _http;

  /// Bearer token attached to authenticated requests. Set after login and
  /// cleared on sign-out.
  String? accessToken;

  Future<AuthTokens> register({
    required String username,
    required String password,
    required String deviceName,
    required PublicKeyBundle keys,
  }) async {
    final json = await _post('/v1/register', {
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
    final json = await _post('/v1/login', {
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
  Future<String?> lookupUsername(String userId) async {
    try {
      final json = await _get('/v1/users/$userId');
      return json['username'] as String?;
    } on ApiException {
      return null;
    }
  }

  /// Reports how many one-time prekeys the server still holds for us.
  Future<({int available, bool shouldReplenish})> preKeyCount() async {
    final json = await _get('/v1/keys/count');
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

  /// Creates a direct chat, or returns the existing one.
  Future<Chat> createDirectChat(String peerUsername) async {
    final json = await _post('/v1/chats', {
      'type': 'direct',
      'peer': peerUsername,
    });
    return Chat(
      id: json['id'] as String,
      type: json['type'] as String,
      epoch: json['epoch'] as int,
      peerUsername: peerUsername,
    );
  }

  /// Creates a group chat. [encryptedTitle] is ciphertext: the server must not
  /// learn what a group is called.
  Future<Chat> createGroupChat({
    required List<String> members,
    required Uint8List encryptedTitle,
    required String localTitle,
  }) async {
    final json = await _post('/v1/chats', {
      'type': 'group',
      'members': members,
      'title': base64Encode(encryptedTitle),
    });
    return Chat(
      id: json['id'] as String,
      type: json['type'] as String,
      epoch: json['epoch'] as int,
      title: localTitle,
    );
  }

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
    return tokens;
  }

  Future<Map<String, dynamic>> _get(String path) =>
      _send('GET', path, null);

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send('POST', path, body);

  Future<Map<String, dynamic>> _delete(String path) =>
      _send('DELETE', path, null);

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body,
  ) async {
    final uri = Uri.parse('$baseUrl$path');
    final request = await _http.openUrl(method, uri);

    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (accessToken != null) {
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

  void close() => _http.close(force: true);
}
