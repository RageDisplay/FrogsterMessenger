/// An in-memory stand-in for the Frogster server, for driving several real
/// client stacks -- engine, database, repository -- against each other.
///
/// It routes frames the way the real server does (cloud fan-out with
/// history, per-device payloads for secret direct chats, one shared
/// ciphertext and epochs for secret groups, sender-key distribution) and
/// records every frame it receives, so tests can check what the server got
/// to see.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/state_sealer.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/crypto/x3dh.dart';
import 'package:frogster/data/local/dao/message_dao.dart';
import 'package:frogster/data/local/dao/session_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/data/remote/server_config.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/data/repositories/device_resolver.dart';
import 'package:frogster/data/repositories/group_cipher.dart';
import 'package:frogster/data/repositories/message_repository.dart';

final _config = ServerConfig(baseUri: Uri.parse('http://test.invalid'));

class FakeUser {
  FakeUser(this.id, this.username);

  final String id;
  final String username;
  final List<FakeDevice> devices = [];
}

class FakeChat {
  FakeChat(this.id, this.type, this.mode);

  final String id;
  final String type;
  final ChatMode mode;
  int epoch = 0;
  String title = '';
  final Map<String, String> roles = {}; // user id -> role
  final Map<String, int> readSeq = {};
  int lastSeq = 0;
  final List<RemoteMessage> rows = [];

  bool get isGroup => type == 'group';
}

class FakeServer {
  final Map<String, FakeUser> users = {};
  final Map<String, FakeChat> chats = {};
  final Map<String, FakeDevice> devices = {};

  /// Every frame clients sent, as JSON text.
  final List<String> received = [];

  /// Devices the server leaks secret-group messages to whether or not
  /// their user is a member: a malicious server.
  final Set<String> leakTo = {};

  var _ids = 0;
  var _skdm = 0;
  DateTime _lastActivity = DateTime.now();

  String _id(String prefix) => '$prefix-${++_ids}';

  Future<FakeDevice> addDevice(String username, {String? dir}) async {
    final user = users.putIfAbsent(username, () => FakeUser(_id('user'), username));
    final device = await FakeDevice.create(this, user, _id('device'), dir ?? _tempDir());
    user.devices.add(device);
    devices[device.id] = device;
    return device;
  }

  static String _tempDir() => Directory.systemTemp.createTempSync('frogster_test').path;

  FakeChat createChat({
    required String type,
    required ChatMode mode,
    required FakeUser creator,
    required List<FakeUser> members,
    String title = '',
  }) {
    final chat = FakeChat(_id('chat'), type, mode)..title = mode == ChatMode.cloud ? title : '';
    chat.roles[creator.id] = 'admin';
    for (final m in members) {
      chat.roles.putIfAbsent(m.id, () => 'member');
    }
    chats[chat.id] = chat;
    return chat;
  }

  /// Removes a member and moves the group to a new epoch, telling everyone,
  /// the removed member included.
  void removeMember(FakeChat chat, FakeUser user, {bool notify = true}) {
    final told = [...chat.roles.keys];
    chat.roles.remove(user.id);
    chat.epoch++;
    if (!notify) return;
    for (final id in told) {
      for (final d in users.values.firstWhere((u) => u.id == id).devices) {
        d.deliver({'type': 'chat_updated', 'chat_id': chat.id, 'epoch': chat.epoch});
      }
    }
  }

  void addMember(FakeChat chat, FakeUser user) {
    chat.roles[user.id] = 'member';
    chat.epoch++;
    for (final id in chat.roles.keys) {
      for (final d in userById(id).devices) {
        d.deliver({'type': 'chat_updated', 'chat_id': chat.id, 'epoch': chat.epoch});
      }
    }
  }

  FakeUser userById(String id) => users.values.firstWhere((u) => u.id == id);

  Iterable<FakeDevice> memberDevices(FakeChat chat) =>
      chat.roles.keys.expand((id) => userById(id).devices);

  RemoteChat remoteChat(FakeChat chat, String viewer) {
    final peers = chat.readSeq.entries.where((e) => e.key != viewer).map((e) => e.value);
    final own = chat.readSeq[viewer] ?? 0;
    return RemoteChat(
      id: chat.id,
      type: chat.type,
      mode: chat.mode,
      epoch: chat.epoch,
      title: chat.title,
      role: chat.roles[viewer] ?? 'member',
      lastSeq: chat.lastSeq,
      lastReadSeq: own,
      peerReadSeq: peers.isEmpty ? 0 : peers.reduce((a, b) => a > b ? a : b),
      unread: chat.rows
          .where((r) => r.kind.isEmpty && r.seq > own && r.senderId != viewer)
          .length,
      members: [
        for (final e in chat.roles.entries)
          ChatMember(userId: e.key, username: userById(e.key).username, role: e.value),
      ],
    );
  }

  /// A frame from a client.
  void receive(FakeDevice from, Map<String, dynamic> frame) {
    _lastActivity = DateTime.now();
    received.add(jsonEncode(frame));
    final chat = chats[frame['chat_id']];
    final sender = {'user_id': from.user.id, 'device_id': from.id};
    final id = frame['id'] as String?;

    switch (frame['type']) {
      case 'msg':
        if (chat == null || !chat.roles.containsKey(from.user.id)) {
          from.deliver({'type': 'error', 'id': id, 'error': 'rejected'});
          return;
        }
        final ct = frame['ct_type'] as int?;
        if (chat.mode == ChatMode.cloud) {
          if (ct != 0) return from.deliver({'type': 'error', 'id': id, 'error': 'rejected'});
        } else if (chat.isGroup) {
          if (ct != 3) return from.deliver({'type': 'error', 'id': id, 'error': 'rejected'});
          if (frame['epoch'] != chat.epoch) {
            return from.deliver({'type': 'error', 'id': id, 'chat_id': chat.id, 'error': 'stale epoch'});
          }
        }
        final seq = ++chat.lastSeq;
        final ts = DateTime.now().millisecondsSinceEpoch;
        if (chat.mode == ChatMode.cloud) _storeCloud(chat, frame, from, seq, ts);

        final out = {
          'type': 'msg',
          'id': id,
          'chat_id': chat.id,
          'sender': sender,
          'seq': seq,
          'ts': ts,
          if (frame['kind'] != null) 'kind': frame['kind'],
          if (frame['target_id'] != null) 'target_id': frame['target_id'],
          if (frame['emoji'] != null) 'emoji': frame['emoji'],
        };
        final payloads = frame['payloads'] as List<dynamic>?;
        if (payloads != null) {
          for (final p in payloads.cast<Map<String, dynamic>>()) {
            devices[p['device_id']]?.deliver({
              ...out,
              'ct_type': p['ct_type'],
              'ciphertext': p['ciphertext'],
            });
          }
        } else {
          final targets = {...memberDevices(chat), ...leakTo.map((d) => devices[d]!)};
          for (final d in targets) {
            if (d.id == from.id) continue;
            d.deliver({...out, 'ct_type': ct, 'ciphertext': frame['ciphertext']});
          }
        }
        from.deliver({'type': 'ack', 'id': id, 'chat_id': chat.id, 'seq': seq, 'ts': ts});

      case 'skdm':
        if (chat == null) return;
        if (frame['epoch'] != chat.epoch) {
          return from.deliver({'type': 'error', 'id': id, 'chat_id': chat.id, 'error': 'stale epoch'});
        }
        final members = memberDevices(chat).map((d) => d.id).toSet();
        for (final p in (frame['payloads'] as List<dynamic>).cast<Map<String, dynamic>>()) {
          if (!members.contains(p['device_id'])) continue;
          devices[p['device_id']]!.deliver({
            'type': 'skdm',
            'id': 'skdm-${++_skdm}',
            'chat_id': chat.id,
            'sender': sender,
            'ciphertext': p['ciphertext'],
            'epoch': chat.epoch,
          });
        }
        from.deliver({'type': 'ack', 'id': id, 'chat_id': chat.id});

      case 'read':
        if (chat == null) return;
        chat.readSeq[from.user.id] = frame['seq'] as int;
        for (final d in memberDevices(chat)) {
          if (d.id == from.id) continue;
          d.deliver({'type': 'read', 'chat_id': chat.id, 'sender': sender, 'seq': frame['seq']});
        }
    }
  }

  void _storeCloud(FakeChat chat, Map<String, dynamic> frame, FakeDevice from, int seq, int ts) {
    final kind = frame['kind'] as String? ?? '';
    final payload = base64Decode(frame['ciphertext'] as String);
    final row = RemoteMessage(
      id: frame['id'] as String,
      seq: seq,
      senderId: from.user.id,
      senderDeviceId: from.id,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ts),
      kind: kind,
      targetId: frame['target_id'] as String?,
      payload: payload,
    );
    chat.rows.add(row);
    // History shows messages as they stand now.
    final target = chat.rows.indexWhere((r) => r.id == frame['target_id'] && r.kind.isEmpty);
    if (target < 0) return;
    final old = chat.rows[target];
    if (kind == 'edit' && old.senderId == from.user.id) {
      chat.rows[target] = RemoteMessage(
        id: old.id,
        seq: old.seq,
        senderId: old.senderId,
        senderDeviceId: old.senderDeviceId,
        timestamp: old.timestamp,
        payload: payload,
        editedAt: DateTime.fromMillisecondsSinceEpoch(ts),
      );
    } else if (kind == 'delete') {
      chat.rows[target] = RemoteMessage(
        id: old.id,
        seq: old.seq,
        senderId: old.senderId,
        senderDeviceId: old.senderDeviceId,
        timestamp: old.timestamp,
        deleted: true,
      );
    }
  }

  /// Waits until no frame has moved for a while: every device has done
  /// what the last frames asked of it.
  Future<void> settle() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final idle = DateTime.now().difference(_lastActivity);
      final busy = devices.values.any((d) => d.ws.inFlight > 0);
      if (!busy && idle > const Duration(milliseconds: 700)) return;
    }
    throw StateError('the fake network never settled');
  }

  void touch() => _lastActivity = DateTime.now();
}

/// One installation: its own keys, database and repository.
class FakeDevice {
  FakeDevice._(this.server, this.user, this.id);

  final FakeServer server;
  final FakeUser user;
  final String id;

  late final FrogsterCryptoEngine engine;
  late final PublicKeyBundle published;
  final List<int> _unusedPreKeys = [];
  late final AppDatabase database;
  late final MessageDao dao;
  late final OutboxDao outbox;
  late final FakeWs ws;
  late final FakeApi api;
  late final MessageRepository repository;

  Account get account => Account(userId: user.id, username: user.username, deviceId: id);

  static Future<FakeDevice> create(FakeServer server, FakeUser user, String id, String dir) async {
    final d = FakeDevice._(server, user, id);
    final keys = InMemoryKeyStorage();
    d.engine = FrogsterCryptoEngine(keyStorage: keys, sessionStore: InMemorySessionStore());
    d.published = await d.engine.initializeIdentity(oneTimePreKeyCount: 40);
    d._unusedPreKeys.addAll(d.published.oneTimePreKeys.keys);
    d.database = await AppDatabase.open(path: '$dir/$id.db');
    d.dao = MessageDao(d.database.db);
    d.outbox = OutboxDao(d.database.db);
    d.ws = FakeWs(d);
    d.api = FakeApi(d);
    final sealer = StateSealer(await keys.localStateKey());
    d.repository = MessageRepository(
      crypto: d.engine,
      ws: d.ws,
      dao: d.dao,
      outbox: d.outbox,
      groups: GroupCipher(dao: SenderKeyDao(d.database.db, sealer: sealer), selfDeviceId: id),
      resolver: DeviceResolver(
        api: d.api,
        crypto: d.engine,
        selfDeviceId: id,
        selfUsername: user.username,
      ),
      api: d.api,
      account: d.account,
    );
    return d;
  }

  /// The bundle someone fetching our keys receives, each with a one-time
  /// prekey of its own, as the server hands them out.
  PreKeyBundle takeBundle() {
    final otp = _unusedPreKeys.removeAt(0);
    return PreKeyBundle(
      deviceId: id,
      registrationId: published.registrationId,
      identityKey: deserializePublicKey(published.identityKey),
      identityKeyEd25519: published.identityKeyEd25519,
      signedPreKeyId: published.signedPreKeyId,
      signedPreKey: deserializePublicKey(published.signedPreKey),
      signedPreKeySignature: published.signedPreKeySignature,
      oneTimePreKeyId: otp,
      oneTimePreKey: deserializePublicKey(published.oneTimePreKeys[otp]!),
    );
  }

  /// A frame from the server.
  void deliver(Map<String, dynamic> frame) {
    server.touch();
    if (!ws.connected) return; // offline: the real server would queue it
    ws.push(frame);
  }

  Future<List<Message>> messages(String chatId) => dao.messagesForChat(chatId, limit: 500);

  Future<void> dispose() async {
    await repository.dispose();
    await database.close();
  }
}

class FakeWs extends WsClient {
  FakeWs(this.device) : super(server: _config, accessToken: () async => 'token');

  final FakeDevice device;
  final _frames = StreamController<Envelope>.broadcast();
  final _states = StreamController<SocketState>.broadcast();
  var connected = false;

  /// Frames delivered but maybe not yet handled; keeps [FakeServer.settle]
  /// honest about work still in progress.
  int get inFlight => 0;

  void push(Map<String, dynamic> frame) => _frames.add(Envelope.fromJson(frame));

  @override
  Stream<Envelope> get envelopes => _frames.stream;

  @override
  Stream<SocketState> get connectionState => _states.stream;

  @override
  SocketState get state => connected ? SocketState.connected : SocketState.disconnected;

  @override
  Future<void> connect() async {
    device.server.touch();
    connected = true;
    _states.add(SocketState.connected);
  }

  void goOffline() {
    connected = false;
    _states.add(SocketState.disconnected);
  }

  @override
  void send(Envelope envelope) => trySendJson(envelope.toJson());

  @override
  bool trySend(Envelope envelope) => trySendJson(envelope.toJson());

  @override
  bool trySendJson(Map<String, dynamic> frame) {
    if (!connected) return false;
    // A round trip through JSON, as on the wire.
    final copy = jsonDecode(jsonEncode(frame)) as Map<String, dynamic>;
    scheduleMicrotask(() => device.server.receive(device, copy));
    return true;
  }

  @override
  Future<void> close() async => goOffline();

  @override
  Future<void> dispose() async {
    await _frames.close();
    await _states.close();
  }
}

class FakeApi extends ApiClient {
  FakeApi(this.device) : super(server: _config);

  final FakeDevice device;
  FakeServer get _server => device.server..touch();
  String get _me => device.user.id;

  @override
  Future<KeyBundles> fetchKeys(String username, {String? deviceId}) async {
    final user = _server.users[username];
    if (user == null) throw const ApiException(404, 'user not found');
    return KeyBundles(
      userId: user.id,
      username: username,
      bundles: [for (final d in user.devices) d.takeBundle()],
    );
  }

  @override
  Future<UserProfile?> lookupUser(String userId) async {
    final user = _server.userById(userId);
    return UserProfile(userId: user.id, username: user.username);
  }

  @override
  Future<String?> lookupUsername(String userId) async => (await lookupUser(userId))?.username;

  @override
  Future<List<RemoteChat>> listChats() async => [
        for (final c in _server.chats.values)
          if (c.roles.containsKey(_me)) _server.remoteChat(c, _me),
      ];

  @override
  Future<RemoteChat> getChat(String chatId) async {
    final chat = _server.chats[chatId];
    if (chat == null || !chat.roles.containsKey(_me)) {
      throw const ApiException(404, 'chat not found');
    }
    return _server.remoteChat(chat, _me);
  }

  @override
  Future<List<RemoteMessage>> chatMessages(
    String chatId, {
    int? before,
    int? after,
    int limit = 50,
  }) async {
    final chat = _server.chats[chatId]!;
    if (after != null) {
      return chat.rows.where((r) => r.seq > after).take(limit).toList();
    }
    final rows = chat.rows
        .where((r) => r.kind.isEmpty && (before == null || r.seq < before))
        .toList()
        .reversed
        .take(limit)
        .toList();
    return rows;
  }
}

/// Decoded bodies, for comparing against plaintext.
List<String> bodies(List<Message> messages) => [for (final m in messages) m.body];

/// Whether [text] appears anywhere in what the server received, the
/// contents of every ciphertext field included once base64-decoded.
bool serverSaw(FakeServer server, String text) {
  bool search(Object? node) {
    if (node is String) {
      if (node.contains(text)) return true;
      try {
        return utf8.decode(base64Decode(node), allowMalformed: true).contains(text);
      } catch (_) {
        return false;
      }
    }
    if (node is Map) return node.values.any(search);
    if (node is List) return node.any(search);
    return false;
  }

  return server.received.any((f) => search(jsonDecode(f)));
}
