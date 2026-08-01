import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/primitives.dart';

void main() {
  group('X25519', () {
    test('both sides derive the same shared secret', () async {
      final alice = await generateKeyPair();
      final bob = await generateKeyPair();

      final aliceView = await diffieHellman(
        privateKey: alice.privateKey,
        peerPublicKey: bob.publicKey,
      );
      final bobView = await diffieHellman(
        privateKey: bob.privateKey,
        peerPublicKey: alice.publicKey,
      );

      expect(aliceView, equals(bobView));
      expect(aliceView.length, curve25519KeyLength);
    });

    test('different pairs derive different secrets', () async {
      final alice = await generateKeyPair();
      final bob = await generateKeyPair();
      final eve = await generateKeyPair();

      final withBob = await diffieHellman(
        privateKey: alice.privateKey,
        peerPublicKey: bob.publicKey,
      );
      final withEve = await diffieHellman(
        privateKey: alice.privateKey,
        peerPublicKey: eve.publicKey,
      );

      expect(withBob, isNot(equals(withEve)));
    });

    test('key pair restored from private key has the same public key',
        () async {
      final original = await generateKeyPair();
      final restored = await keyPairFromPrivateKey(original.privateKey);

      expect(restored.publicKey, equals(original.publicKey));
    });

    test('all-zero shared secret is rejected', () async {
      final alice = await generateKeyPair();
      // A small-order point: all-zero u-coordinate.
      final smallOrder = Uint8List(curve25519KeyLength);

      expect(
        () => diffieHellman(
          privateKey: alice.privateKey,
          peerPublicKey: smallOrder,
        ),
        throwsA(isA<StateError>()),
        reason: 'a small-order point yields a predictable secret and must fail',
      );
    });
  });

  group('public key serialization', () {
    test('round trips through the DJB prefix', () async {
      final kp = await generateKeyPair();
      final serialized = kp.serializedPublicKey;

      expect(serialized.length, djbPublicKeyLength);
      expect(serialized[0], djbKeyType);
      expect(deserializePublicKey(serialized), equals(kp.publicKey));
    });

    test('rejects wrong length', () {
      expect(
        () => deserializePublicKey(Uint8List(10)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects unknown key type', () {
      final bad = Uint8List(djbPublicKeyLength)..[0] = 0x42;
      expect(
        () => deserializePublicKey(bad),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('HKDF', () {
    test('is deterministic for identical inputs', () async {
      final ikm = Uint8List.fromList(List.filled(32, 7));
      final salt = Uint8List.fromList(List.filled(32, 9));

      final a = await hkdf(inputKeyMaterial: ikm, salt: salt, info: [1, 2, 3]);
      final b = await hkdf(inputKeyMaterial: ikm, salt: salt, info: [1, 2, 3]);

      expect(a, equals(b));
      expect(a.length, symmetricKeyLength);
    });

    test('info separates derived keys', () async {
      final ikm = Uint8List.fromList(List.filled(32, 7));
      final salt = Uint8List.fromList(List.filled(32, 9));

      final root = await hkdf(inputKeyMaterial: ikm, salt: salt, info: [1]);
      final chain = await hkdf(inputKeyMaterial: ikm, salt: salt, info: [2]);

      expect(root, isNot(equals(chain)),
          reason: 'distinct info strings must not collide');
    });

    test('supports longer outputs', () async {
      final out = await hkdf(
        inputKeyMaterial: Uint8List(32),
        salt: Uint8List(32),
        info: const [],
        outputLength: 64,
      );
      expect(out.length, 64);
    });
  });

  group('AES-256-GCM', () {
    test('round trips a message', () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final plaintext = 'attack at dawn'.codeUnits;

      final ct = await aeadEncrypt(
        key: key,
        plaintext: plaintext,
        associatedData: const [1, 2],
      );
      final back = await aeadDecrypt(
        key: key,
        ciphertext: ct,
        associatedData: const [1, 2],
      );

      expect(back, equals(plaintext));
    });

    test('rejects a tampered body', () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final ct = await aeadEncrypt(
        key: key,
        plaintext: 'hello'.codeUnits,
        associatedData: const [],
      );

      final tampered = Uint8List.fromList(ct.body)..[0] ^= 0xFF;

      expect(
        () => aeadDecrypt(
          key: key,
          ciphertext: AeadCiphertext(nonce: ct.nonce, body: tampered, tag: ct.tag),
          associatedData: const [],
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('rejects mismatched associated data', () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final ct = await aeadEncrypt(
        key: key,
        plaintext: 'hello'.codeUnits,
        associatedData: const [1, 2, 3],
      );

      expect(
        () => aeadDecrypt(key: key, ciphertext: ct, associatedData: const [9]),
        throwsA(isA<SecretBoxAuthenticationError>()),
        reason: 'AAD binds the header; swapping it must fail authentication',
      );
    });

    test('rejects the wrong key', () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final other = Uint8List.fromList(List.filled(32, 4));
      final ct = await aeadEncrypt(
        key: key,
        plaintext: 'hello'.codeUnits,
        associatedData: const [],
      );

      expect(
        () => aeadDecrypt(key: other, ciphertext: ct, associatedData: const []),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('serialization round trips', () async {
      final key = Uint8List.fromList(List.filled(32, 5));
      final ct = await aeadEncrypt(
        key: key,
        plaintext: 'serialize me'.codeUnits,
        associatedData: const [],
      );

      final parsed = AeadCiphertext.deserialize(ct.serialize());
      final back = await aeadDecrypt(
        key: key,
        ciphertext: parsed,
        associatedData: const [],
      );

      expect(back, equals('serialize me'.codeUnits));
    });

    test('reuses no nonce across encryptions', () async {
      final key = Uint8List.fromList(List.filled(32, 3));
      final nonces = <String>{};

      for (var i = 0; i < 50; i++) {
        final ct = await aeadEncrypt(
          key: key,
          plaintext: 'x'.codeUnits,
          associatedData: const [],
        );
        nonces.add(ct.nonce.join(','));
      }

      expect(nonces.length, 50,
          reason: 'a repeated GCM nonce under one key breaks confidentiality');
    });
  });

  group('helpers', () {
    test('constantTimeEquals matches ==', () {
      expect(constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(constantTimeEquals([1, 2], [1, 2, 3]), isFalse);
    });

    test('wipe zeroes a buffer', () {
      final buf = Uint8List.fromList([1, 2, 3, 4]);
      wipe(buf);
      expect(buf, equals(Uint8List(4)));
    });
  });
}
