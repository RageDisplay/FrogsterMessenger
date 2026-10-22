/// Persists Double Ratchet sessions, pinned identities and sender keys.
///
/// Ratchet state contains live key material. It lives in the local database
/// rather than the keychain because it is far too large for a keychain entry
/// and changes on every message. Each value is sealed with a key that stays in
/// the keychain ([StateSealer]), so the database file on its own -- a backup,
/// a copied disk -- yields no keys. Losing this data costs message history,
/// not confidentiality.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../crypto/crypto_engine.dart';
import '../../../crypto/ratchet/sender_key.dart';
import '../../../crypto/safety_number.dart';
import '../../../crypto/state_sealer.dart';

class SqfliteSessionStore implements SessionStore {
  const SqfliteSessionStore(this._db, {StateSealer? sealer}) : _sealer = sealer;

  final Database _db;

  /// Seals stored state. Absent only in tests that exercise the storage
  /// itself; the app always provides one.
  final StateSealer? _sealer;

  @override
  Future<Map<String, dynamic>?> loadSession(String peerKey) async {
    final rows = await _db.query(
      'ratchet_sessions',
      where: 'peer_key = ?',
      whereArgs: [peerKey],
    );
    if (rows.isEmpty) return null;
    final stored = rows.first['state'] as String;
    final json = await _sealer?.open('ratchet:$peerKey', stored) ?? stored;
    return jsonDecode(json) as Map<String, dynamic>;
  }

  @override
  Future<void> saveSession(String peerKey, Map<String, dynamic> state) async {
    final json = jsonEncode(state);
    await _db.insert(
      'ratchet_sessions',
      {
        'peer_key': peerKey,
        'state': await _sealer?.seal('ratchet:$peerKey', json) ?? json,
      },
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
  const SenderKeyDao(this._db, {StateSealer? sealer}) : _sealer = sealer;

  final Database _db;
  final StateSealer? _sealer;

  static String _label(String chatId, int epoch, String deviceId) =>
      'sender_key:$chatId:$epoch:$deviceId';

  Future<void> save(SenderKeyState state, {required bool isOwn}) async {
    final json = jsonEncode(state.toJson());
    final label = _label(state.chatId, state.epoch, state.senderDeviceId);
    await _db.insert(
      'sender_keys',
      {
        'chat_id': state.chatId,
        'epoch': state.epoch,
        'device_id': state.senderDeviceId,
        'state': await _sealer?.seal(label, json) ?? json,
        'is_own': isOwn ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<SenderKeyState> _decode(Map<String, Object?> row) async {
    final stored = row['state'] as String;
    final label = _label(
      row['chat_id'] as String,
      row['epoch'] as int,
      row['device_id'] as String,
    );
    final json = await _sealer?.open(label, stored) ?? stored;
    return SenderKeyState.fromJson(jsonDecode(json) as Map<String, dynamic>);
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
    return _decode(rows.first);
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
    return _decode(rows.first);
  }

  /// Devices that already hold our sender key for this epoch.
  Future<Set<String>> sharedWith({
    required String chatId,
    required int epoch,
  }) async {
    final rows = await _db.query(
      'sender_key_shares',
      columns: ['device_id'],
      where: 'chat_id = ? AND epoch = ?',
      whereArgs: [chatId, epoch],
    );
    return {for (final r in rows) r['device_id'] as String};
  }

  /// Records that our sender key for this epoch went to [deviceIds].
  Future<void> recordShares({
    required String chatId,
    required int epoch,
    required Iterable<String> deviceIds,
  }) async {
    final batch = _db.batch();
    for (final id in deviceIds) {
      batch.insert(
        'sender_key_shares',
        {'chat_id': chatId, 'epoch': epoch, 'device_id': id},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Forgets every sender key of a chat, for a group this device left.
  Future<void> deleteChat(String chatId) async {
    await _db.delete('sender_keys', where: 'chat_id = ?', whereArgs: [chatId]);
    await _db.delete('sender_key_shares',
        where: 'chat_id = ?', whereArgs: [chatId]);
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
    await _db.delete(
      'sender_key_shares',
      where: 'chat_id = ? AND epoch < ?',
      whereArgs: [chatId, currentEpoch],
    );
  }
}
