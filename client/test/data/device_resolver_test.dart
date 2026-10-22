/// Tests for device-set resolution.
///
/// The scenario these cover is the one that silently broke a conversation: a
/// contact wipes their app and signs back in, so their account gains a second
/// device. Every message sent afterwards must reach the new device, or the
/// server logs "device not addressed by sender, skipping" and delivers
/// nothing -- with no error shown to either person.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/crypto/x3dh.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/data/remote/server_config.dart';
import 'package:frogster/data/repositories/device_resolver.dart';

/// An ApiClient whose key directory can be rewritten mid-test.
class _FakeApi extends ApiClient {
  _FakeApi()
      : super(server: ServerConfig(baseUri: Uri.parse('http://test.invalid')));

  final Map<String, KeyBundles> directory = {};
  int fetchCount = 0;

  @override
  Future<KeyBundles> fetchKeys(String username, {String? deviceId}) async {
    fetchCount++;
    final entry = directory[username];
    if (entry == null) {
      throw const ApiException(404, 'user not found');
    }
    return entry;
  }
}

/// Builds a real engine and publishes its bundle, standing in for one device.
Future<({FrogsterCryptoEngine engine, PreKeyBundle bundle})> _device(
  String deviceId,
) async {
  final engine = FrogsterCryptoEngine(
    keyStorage: InMemoryKeyStorage(),
    sessionStore: InMemorySessionStore(),
  );
  final published = await engine.initializeIdentity(oneTimePreKeyCount: 5);
  final otp = published.oneTimePreKeys.entries.first;

  return (
    engine: engine,
    bundle: PreKeyBundle(
      deviceId: deviceId,
      registrationId: published.registrationId,
      identityKey: deserializePublicKey(published.identityKey),
      identityKeyEd25519: published.identityKeyEd25519,
      signedPreKeyId: published.signedPreKeyId,
      signedPreKey: deserializePublicKey(published.signedPreKey),
      signedPreKeySignature: published.signedPreKeySignature,
      oneTimePreKeyId: otp.key,
      oneTimePreKey: deserializePublicKey(otp.value),
    ),
  );
}

void main() {
  late _FakeApi api;
  late FrogsterCryptoEngine mine;
  late DeviceResolver resolver;

  setUp(() async {
    api = _FakeApi();
    mine = FrogsterCryptoEngine(
      keyStorage: InMemoryKeyStorage(),
      sessionStore: InMemorySessionStore(),
    );
    await mine.initializeIdentity(oneTimePreKeyCount: 5);

    resolver = DeviceResolver(
      api: api,
      crypto: mine,
      selfDeviceId: 'my-device',
      selfUsername: 'alice',
    );
  });

  Future<void> publish(String username, List<PreKeyBundle> bundles) async {
    api.directory[username] = KeyBundles(
      userId: 'user-$username',
      username: username,
      bundles: bundles,
    );
  }

  test('resolves every published device', () async {
    final first = await _device('bob-1');
    await publish('bob', [first.bundle]);

    final devices = await resolver.devicesFor('bob');

    expect(devices, hasLength(1));
    expect(devices.single.address.deviceId, 'bob-1');
  });

  test('a cached list is reused without refetching', () async {
    final first = await _device('bob-1');
    await publish('bob', [first.bundle]);

    await resolver.devicesFor('bob');
    await resolver.devicesFor('bob');

    // Refetching per message would drain the peer's one-time prekey pool.
    expect(api.fetchCount, 1);
  });

  test('invalidate picks up a device added after the first resolve', () async {
    final first = await _device('bob-1');
    await publish('bob', [first.bundle]);
    await resolver.devicesFor('bob');

    // Bob wipes the app and signs back in: same account, second device.
    final second = await _device('bob-2');
    await publish('bob', [first.bundle, second.bundle]);

    // Without this the stale single-device list survives and every later
    // message misses bob-2 entirely.
    resolver.invalidate('bob');

    final devices = await resolver.devicesFor('bob');
    expect(
      devices.map((d) => d.address.deviceId),
      containsAll(<String>['bob-1', 'bob-2']),
      reason: 'a message must reach the device the peer actually uses',
    );
  });

  test('a stale cache expires on its own', () async {
    final first = await _device('bob-1');
    await publish('bob', [first.bundle]);
    await resolver.devicesFor('bob');

    final second = await _device('bob-2');
    await publish('bob', [first.bundle, second.bundle]);

    // The push notification is the fast path, but it only reaches a client
    // that is online. A client that was offline when the peer re-registered
    // has to recover on its own, or the conversation stays broken until a
    // restart.
    expect(
      DeviceResolver.cacheTtl.inMinutes,
      lessThanOrEqualTo(5),
      reason: 'an offline client recovers only when the cache expires',
    );
  });

  test('usernameFor maps a user id back to its name', () async {
    final first = await _device('bob-1');
    await publish('bob', [first.bundle]);
    await resolver.devicesFor('bob');

    // This is what lets a key-change notification, which names only a user id,
    // invalidate the right cache entry.
    expect(resolver.usernameFor('user-bob'), 'bob');
  });
}
