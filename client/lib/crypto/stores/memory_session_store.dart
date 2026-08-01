/// An in-memory [SessionStore] for tests.
///
/// Sessions are lost on restart, so this must never be used on a device:
/// the production store persists to encrypted sqflite (Stage 6).
library;

import 'dart:typed_data';

import '../crypto_engine.dart';
import '../safety_number.dart';

class InMemorySessionStore implements SessionStore {
  final Map<String, Map<String, dynamic>> _sessions = {};
  final Map<String, PinnedIdentity> _identities = {};

  @override
  Future<Map<String, dynamic>?> loadSession(String peerKey) async =>
      _sessions[peerKey];

  @override
  Future<void> saveSession(String peerKey, Map<String, dynamic> state) async {
    _sessions[peerKey] = state;
  }

  @override
  Future<void> deleteSession(String peerKey) async {
    _sessions.remove(peerKey);
  }

  @override
  Future<PinnedIdentity?> loadPinnedIdentity(String peerKey) async =>
      _identities[peerKey];

  @override
  Future<void> savePinnedIdentity(PinnedIdentity identity) async {
    _identities['${identity.userId}:${identity.deviceId}'] = identity;
  }

  /// Replaces a pinned key, simulating a peer reinstalling the app or a
  /// malicious server substituting its own key.
  void forcePinnedKey(String peerKey, Uint8List key) {
    final existing = _identities[peerKey];
    if (existing == null) return;
    _identities[peerKey] = PinnedIdentity(
      userId: existing.userId,
      deviceId: existing.deviceId,
      identityKey: key,
      pinnedAt: existing.pinnedAt,
      acceptedChange: existing.acceptedChange,
    );
  }
}
