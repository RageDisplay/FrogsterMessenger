/// Persists Double Ratchet sessions, pinned identities and sender keys.
///
/// Ratchet state contains live key material. It lives in the local database
/// rather than the keychain because it is far too large for a keychain entry
/// and changes on every message; the platform's disk encryption is what
/// protects it. Losing this data costs message history, not confidentiality.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../crypto/crypto_engine.dart';
import '../../../crypto/ratchet/sender_key.dart';
import '../../../crypto/safety_number.dart';

class SqfliteSessionStore implements SessionStore {
  const SqfliteSessionStore(this._db);

  final Database _db;

  @override
  Future<Map<String, dynamic>?> loadSession(String peerKey) async {
    final rows = await _db.query(
      'ratchet_sessions',
      where: 'peer_key = ?',
      whereArgs: [peerKey],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['state'] as String) as Map<String, dynamic>;
  }

  @override
  Future<void> saveSession(String peerKey, Map<String, dynamic> state) async {
    await _db.insert(
      'ratchet_sessions',
      {'peer_key': peerKey, 'state': jsonEncode(state)},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteSession(String peerKey) async {
    await _db.delete(
      'ratchet_sessions',
      where: 'peer_key = ?',
      whereArgs: [peerKey],
    );
  }

  @override
  Future<PinnedIdentity?> loadPinnedIdentity(String peerKey) async {
    final rows = await _db.query(
      'pinned_identities',
      where: 'peer_key = ?',
      whereArgs: [peerKey],
    );
    if (rows.isEmpty) return null;

    final r = rows.first;
    return PinnedIdentity(
      userId: r['user_id'] as String,
      deviceId: r['device_id'] as String,
      identityKey: base64Decode(r['identity_key'] as String),
      pinnedAt: DateTime.fromMillisecondsSinceEpoch(r['pinned_at'] as int),
      acceptedChange: (r['accepted_change'] as int) == 1,
    );
  }

  @override
  Future<void> savePinnedIdentity(PinnedIdentity identity) async {
    await _db.insert(
      'pinned_identities',
      {
        'peer_key': '${identity.userId}:${identity.deviceId}',
        'user_id': identity.userId,
        'device_id': identity.deviceId,
        'identity_key': base64Encode(identity.identityKey),
        'pinned_at': identity.pinnedAt.millisecondsSinceEpoch,
        'accepted_change': identity.acceptedChange ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

/// Persists group sender keys, scoped to a chat epoch.
class SenderKeyDao {
  const SenderKeyDao(this._db);

  final Database _db;

  Future<void> save(SenderKeyState state, {required bool isOwn}) async {
    await _db.insert(
      'sender_keys',
      {
        'chat_id': state.chatId,
        'epoch': state.epoch,
        'device_id': state.senderDeviceId,
        'state': jsonEncode(state.toJson()),
        'is_own': isOwn ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<SenderKeyState?> load({
    required String chatId,
    required int epoch,
    required String deviceId,
  }) async {
    final rows = await _db.query(
      'sender_keys',
      where: 'chat_id = ? AND epoch = ? AND device_id = ?',
      whereArgs: [chatId, epoch, deviceId],
    );
    if (rows.isEmpty) return null;
    return SenderKeyState.fromJson(
      jsonDecode(rows.first['state'] as String) as Map<String, dynamic>,
    );
  }

  /// Our own sender key for a chat epoch, if we have published one.
  Future<SenderKeyState?> loadOwn({
    required String chatId,
    required int epoch,
  }) async {
    final rows = await _db.query(
      'sender_keys',
      where: 'chat_id = ? AND epoch = ? AND is_own = 1',
      whereArgs: [chatId, epoch],
    );
    if (rows.isEmpty) return null;
    return SenderKeyState.fromJson(
      jsonDecode(rows.first['state'] as String) as Map<String, dynamic>,
    );
  }

  /// Drops every sender key from before [currentEpoch].
  ///
  /// Called when the chat's epoch advances. Keys from an earlier epoch are
  /// known to anyone who has since been removed from the group, so keeping
  /// them around only creates opportunities to use one by mistake.
  Future<void> purgeStaleEpochs({
    required String chatId,
    required int currentEpoch,
  }) async {
    await _db.delete(
      'sender_keys',
      where: 'chat_id = ? AND epoch < ?',
      whereArgs: [chatId, currentEpoch],
    );
  }
}
