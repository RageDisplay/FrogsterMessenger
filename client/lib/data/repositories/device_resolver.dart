/// Resolves which devices a message must be encrypted for.
///
/// A conversation is between people, but encryption is between devices: every
/// device runs its own Double Ratchet session. Sending to a user therefore
/// means encrypting once per device they own -- plus once per *our* other
/// devices, so our own screens stay in sync.
library;

import '../../crypto/crypto_engine.dart';
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
    if (cached != null) {
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
      if (await _crypto.hasSession(address)) continue;

      // Throws IdentityChangedException when the peer's key changed. That
      // propagates rather than being swallowed: silently trusting a new key is
      // exactly the attack pinning exists to catch.
      await _crypto.establishOutboundSession(address, bundle);
    }

    _cache[username] = resolved;
    return resolved;
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
