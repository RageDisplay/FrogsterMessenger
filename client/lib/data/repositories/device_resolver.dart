/// Resolves which devices a message must be encrypted for.
///
/// A conversation is between people, but encryption is between devices: every
/// device runs its own Double Ratchet session. Sending to a user therefore
/// means encrypting once per device they own -- plus once per *our* other
/// devices, so our own screens stay in sync.
library;

import '../../crypto/crypto_engine.dart';
import '../../crypto/primitives.dart';
import '../../crypto/x3dh.dart';
import '../remote/api_client.dart';

/// A device that can receive an encrypted message.
class ResolvedDevice {
  const ResolvedDevice({required this.address, required this.username});

  final PeerAddress address;

  /// The account this device belongs to, so its bundle can be re-fetched.
  final String username;
}

class DeviceResolver {
  DeviceResolver({
    required ApiClient api,
    required CryptoEngine crypto,
    required String selfDeviceId,
    required String selfUsername,
  })  : _api = api,
        _crypto = crypto,
        _selfDeviceId = selfDeviceId,
        _selfUsername = selfUsername;

  final ApiClient _api;
  final CryptoEngine _crypto;
  final String _selfDeviceId;
  final String _selfUsername;

  /// Devices resolved so far, keyed by username.
  ///
  /// Cached because fetching a bundle consumes one of the peer's one-time
  /// prekeys server-side: doing it per message would drain their pool and
  /// force every later session to start without one.
  final Map<String, List<ResolvedDevice>> _cache = {};

  /// When each cached entry was fetched.
  final Map<String, DateTime> _cachedAt = {};

  /// How long a device list is trusted before being refetched.
  ///
  /// Without an expiry a cached list is permanent for the life of the process,
  /// so a contact who adds a device -- switching to a new phone, most often --
  /// would never receive anything we send: we would keep encrypting only for
  /// devices we happened to know about first.
  static const Duration cacheTtl = Duration(minutes: 5);

  /// User id to username, learned from key bundles.
  ///
  /// An incoming message names its sender by id, but a chat is labelled with a
  /// username, so the two have to be connected somewhere.
  final Map<String, String> _usernames = {};

  /// Every device that should receive a direct message to [username],
  /// including our own other devices.
  Future<List<ResolvedDevice>> devicesForDirectMessage(String username) async {
    final peers = await devicesFor(username);

    // Our own other devices, so a message sent from a phone also appears on a
    // desktop. The sending device is excluded: it already has the plaintext.
    final own = username == _selfUsername
        ? const <ResolvedDevice>[]
        : await devicesFor(_selfUsername);

    return [
      ...peers.where((d) => d.address.deviceId != _selfDeviceId),
      ...own.where((d) => d.address.deviceId != _selfDeviceId),
    ];
  }

  /// Resolves a user's devices, opening a session with each.
  Future<List<ResolvedDevice>> devicesFor(String username) async {
    final cached = _cache[username];
    if (cached != null && !_isStale(username)) {
      await _healMissingSessions(username, cached);
      return cached;
    }

    final fetched = await _api.fetchKeys(username);
    final resolved = <ResolvedDevice>[];

    for (final bundle in fetched.bundles) {
      final address = PeerAddress(
        userId: fetched.userId,
        deviceId: bundle.deviceId,
      );
      resolved.add(ResolvedDevice(address: address, username: username));

      if (bundle.deviceId == _selfDeviceId) continue;

      // A session alone is not proof the key still matches: a peer who
      // reinstalled or moved to a new phone publishes a new identity key under
      // the same device id. establishOutboundSession compares against the
      // pinned key and, under the default policy, rebuilds the session and
      // reports the change; in strict mode it throws instead. Skipping the
      // call whenever a session exists would hide both.
      if (await _crypto.hasSession(address) &&
          !await _identityChangedFor(address, bundle)) {
        continue;
      }

      await _crypto.establishOutboundSession(address, bundle);
    }

    _cache[username] = resolved;
    _cachedAt[username] = DateTime.now();
    _usernames[fetched.userId] = username;
    return resolved;
  }

  bool _isStale(String username) {
    final at = _cachedAt[username];
    return at == null || DateTime.now().difference(at) > cacheTtl;
  }

  /// True when the bundle presents a different identity key than the one
  /// pinned for this device.
  Future<bool> _identityChangedFor(
    PeerAddress address,
    PreKeyBundle bundle,
  ) async {
    final pinned = await _crypto.pinnedIdentityFor(address);
    if (pinned == null) return false;
    return !constantTimeEquals(pinned.identityKey, bundle.identityKey);
  }

  /// The username behind a user id, if we have fetched their keys.
  String? usernameFor(String userId) => _usernames[userId];

  /// Asks the server for a username we have not seen before.
  ///
  /// Needed when a message arrives from someone whose keys were never fetched:
  /// without the username the chat cannot be labelled, and a reply cannot look
  /// up their key bundle.
  Future<String?> lookupUsername(String userId) async {
    final known = _usernames[userId];
    if (known != null) return known;

    final username = await _api.lookupUsername(userId);
    if (username != null) _usernames[userId] = username;
    return username;
  }

  /// Re-establishes sessions that have gone missing, for example after a key
  /// change was accepted and the old session was dropped.
  Future<void> _healMissingSessions(
    String username,
    List<ResolvedDevice> devices,
  ) async {
    final missing = <ResolvedDevice>[];
    for (final device in devices) {
      if (device.address.deviceId == _selfDeviceId) continue;
      if (!await _crypto.hasSession(device.address)) missing.add(device);
    }
    if (missing.isEmpty) return;

    final fetched = await _api.fetchKeys(username);
    for (final device in missing) {
      final bundle = fetched.bundles
          .where((b) => b.deviceId == device.address.deviceId)
          .firstOrNull;
      if (bundle == null) continue;
      await _crypto.establishOutboundSession(device.address, bundle);
    }
  }

  /// Drops the cache for a user, forcing a fresh bundle fetch.
  ///
  /// Called when the server reports a key change, so the next send sees the
  /// new device set instead of a stale one.
  void invalidate(String username) => _cache.remove(username);

  void invalidateAll() => _cache.clear();
}
