import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/crypto/x3dh.dart';
import 'package:frogster/data/repositories/key_maintenance.dart';

/// An engine whose signed prekey is old enough to be rotated.
Future<(FrogsterCryptoEngine, InMemoryKeyStorage)> _engineDueForRotation() async {
  final keys = InMemoryKeyStorage();
  final engine = FrogsterCryptoEngine(
    keyStorage: keys,
    sessionStore: InMemorySessionStore(),
  );
  await engine.initializeIdentity(oneTimePreKeyCount: 1);
  final spk = (await keys.loadSignedPreKey())!;
  await keys.saveSignedPreKey(SignedPreKeyPair(
    keyId: spk.keyId,
    keyPair: spk.keyPair,
    signature: spk.signature,
    createdAt: DateTime.now().subtract(const Duration(days: 30)),
  ));
  return (engine, keys);
}

void main() {
  group('signed prekey rotation', () {
    test('a failed upload leaves the current key in place', () async {
      // Committing before the server has the new key would leave the server
      // handing out a key this device no longer holds as current.
      final (engine, keys) = await _engineDueForRotation();
      final before = (await keys.loadSignedPreKey())!.keyId;

      final maintenance = KeyMaintenance(
        crypto: engine,
        preKeyCount: () async => (available: 50, shouldReplenish: false),
        uploadPreKeys: (_) async {},
        uploadSignedPreKey: (_) async => throw Exception('network down'),
      );

      await expectLater(maintenance.rotateSignedPreKey(), throwsException);
      expect((await keys.loadSignedPreKey())!.keyId, before);
      expect(await keys.loadPreviousSignedPreKey(), isNull);
    });

    test('a successful upload commits and keeps the old key', () async {
      final (engine, keys) = await _engineDueForRotation();
      final before = (await keys.loadSignedPreKey())!.keyId;
      SignedPreKeyUpload? uploaded;

      final maintenance = KeyMaintenance(
        crypto: engine,
        preKeyCount: () async => (available: 50, shouldReplenish: false),
        uploadPreKeys: (_) async {},
        uploadSignedPreKey: (u) async => uploaded = u,
      );
      await maintenance.rotateSignedPreKey();

      expect(uploaded, isNotNull);
      expect((await keys.loadSignedPreKey())!.keyId, uploaded!.keyId);
      expect((await keys.loadPreviousSignedPreKey())!.keyId, before);
    });

    test('a fresh key is left alone', () async {
      final keys = InMemoryKeyStorage();
      final engine = FrogsterCryptoEngine(
        keyStorage: keys,
        sessionStore: InMemorySessionStore(),
      );
      await engine.initializeIdentity(oneTimePreKeyCount: 1);
      var uploads = 0;

      await KeyMaintenance(
        crypto: engine,
        preKeyCount: () async => (available: 50, shouldReplenish: false),
        uploadPreKeys: (_) async {},
        uploadSignedPreKey: (_) async => uploads++,
      ).rotateSignedPreKey();

      expect(uploads, 0);
    });
  });

  group('one-time prekey replenishment', () {
    test('uploads a batch only when the server asks for more', () async {
      final (engine, _) = await _engineDueForRotation();
      final batches = <Map<int, Uint8List>>[];

      Future<void> runWith(bool low) => KeyMaintenance(
            crypto: engine,
            preKeyCount: () async => (available: low ? 3 : 80, shouldReplenish: low),
            uploadPreKeys: (k) async => batches.add(k),
            uploadSignedPreKey: (_) async {},
          ).replenishPreKeys();

      await runWith(false);
      expect(batches, isEmpty);

      await runWith(true);
      expect(batches, hasLength(1));
      expect(batches.single, hasLength(preKeyReplenishBatch));
    });
  });
}
