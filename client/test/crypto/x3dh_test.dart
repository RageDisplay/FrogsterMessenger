import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/signing.dart';
import 'package:frogster/crypto/x3dh.dart';

/// Builds a complete device identity plus its published prekeys.
Future<_Device> _newDevice({bool withOneTimePreKey = true}) async {
  final dh = await generateKeyPair();
  final signing = await generateSigningKeyPair();
  final spk = await generateKeyPair();
  final signature = await sign(seed: signing.seed, message: spk.publicKey);

  KeyPair? otp;
  if (withOneTimePreKey) {
    otp = await generateKeyPair();
  }

  return _Device(
    identity: IdentityKeys(dhKeyPair: dh, signingKeyPair: signing),
    signedPreKey: spk,
    signedPreKeySignature: signature,
    oneTimePreKey: otp,
  );
}

class _Device {
  _Device({
    required this.identity,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKey,
  });

  final IdentityKeys identity;
  final KeyPair signedPreKey;
  final Uint8List signedPreKeySignature;
  final KeyPair? oneTimePreKey;

  PreKeyBundle get bundle => PreKeyBundle(
        deviceId: 'device-1',
        registrationId: 1234,
        identityKey: identity.dhKeyPair.publicKey,
        identityKeyEd25519: identity.signingKeyPair.publicKey,
        signedPreKeyId: 1,
        signedPreKey: signedPreKey.publicKey,
        signedPreKeySignature: signedPreKeySignature,
        oneTimePreKeyId: oneTimePreKey == null ? null : 7,
        oneTimePreKey: oneTimePreKey?.publicKey,
      );
}

void main() {
  group('X3DH agreement', () {
    test('initiator and responder derive the same secret', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final aliceResult = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );

      final bobResult = await x3dhRespond(
        identity: bob.identity,
        signedPreKeyPair: bob.signedPreKey,
        initiatorIdentityKey: alice.identity.dhKeyPair.publicKey,
        initiatorEphemeralKey: aliceResult.ephemeralPublicKey,
        oneTimePreKeyPair: bob.oneTimePreKey,
      );

      expect(bobResult.sharedSecret, equals(aliceResult.sharedSecret),
          reason: 'both sides must derive an identical shared secret');
      expect(aliceResult.sharedSecret.length, symmetricKeyLength);
    });

    test('works without a one-time prekey (drained pool)', () async {
      final alice = await _newDevice();
      final bob = await _newDevice(withOneTimePreKey: false);

      final aliceResult = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );
      final bobResult = await x3dhRespond(
        identity: bob.identity,
        signedPreKeyPair: bob.signedPreKey,
        initiatorIdentityKey: alice.identity.dhKeyPair.publicKey,
        initiatorEphemeralKey: aliceResult.ephemeralPublicKey,
      );

      expect(bobResult.sharedSecret, equals(aliceResult.sharedSecret));
      expect(aliceResult.usedOneTimePreKeyId, isNull);
    });

    test('omitting DH4 changes the secret', () async {
      // Guards against a responder that forgets to include the one-time
      // prekey: it must not silently agree with an initiator that used it.
      final alice = await _newDevice();
      final bob = await _newDevice();

      final aliceResult = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );
      final bobWithoutOtp = await x3dhRespond(
        identity: bob.identity,
        signedPreKeyPair: bob.signedPreKey,
        initiatorIdentityKey: alice.identity.dhKeyPair.publicKey,
        initiatorEphemeralKey: aliceResult.ephemeralPublicKey,
        // deliberately omitted
      );

      expect(bobWithoutOtp.sharedSecret, isNot(equals(aliceResult.sharedSecret)),
          reason: 'DH4 must contribute to the shared secret');
    });

    test('associated data binds both identities in a fixed order', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final aliceResult = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );
      final bobResult = await x3dhRespond(
        identity: bob.identity,
        signedPreKeyPair: bob.signedPreKey,
        initiatorIdentityKey: alice.identity.dhKeyPair.publicKey,
        initiatorEphemeralKey: aliceResult.ephemeralPublicKey,
        oneTimePreKeyPair: bob.oneTimePreKey,
      );

      expect(bobResult.associatedData, equals(aliceResult.associatedData));
      expect(
        aliceResult.associatedData.sublist(0, curve25519KeyLength),
        equals(alice.identity.dhKeyPair.publicKey),
        reason: 'initiator identity comes first',
      );
      expect(
        aliceResult.associatedData.sublist(curve25519KeyLength),
        equals(bob.identity.dhKeyPair.publicKey),
      );
    });

    test('each session uses a fresh ephemeral key', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final first = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );
      final second = await x3dhInitiate(
        identity: alice.identity,
        bundle: bob.bundle,
      );

      expect(first.ephemeralPublicKey, isNot(equals(second.ephemeralPublicKey)));
      expect(first.sharedSecret, isNot(equals(second.sharedSecret)),
          reason: 'a reused ephemeral key would destroy forward secrecy');
    });
  });

  group('X3DH signature verification', () {
    test('rejects a forged signed prekey', () async {
      // The core defence against a malicious server: it hands Alice its own
      // prekey, hoping she starts a session it can read.
      final alice = await _newDevice();
      final bob = await _newDevice();
      final attacker = await _newDevice();

      final forged = PreKeyBundle(
        deviceId: bob.bundle.deviceId,
        registrationId: bob.bundle.registrationId,
        identityKey: bob.identity.dhKeyPair.publicKey,
        identityKeyEd25519: bob.identity.signingKeyPair.publicKey,
        signedPreKeyId: 1,
        // Attacker's prekey, signed by the attacker rather than by Bob.
        signedPreKey: attacker.signedPreKey.publicKey,
        signedPreKeySignature: attacker.signedPreKeySignature,
      );

      expect(
        () => x3dhInitiate(identity: alice.identity, bundle: forged),
        throwsA(isA<X3dhVerificationException>()),
      );
    });

    test('rejects a tampered signature', () async {
      final alice = await _newDevice();
      final bob = await _newDevice();

      final tampered = Uint8List.fromList(bob.signedPreKeySignature)
        ..[0] ^= 0xFF;

      final bad = PreKeyBundle(
        deviceId: 'd',
        registrationId: 1,
        identityKey: bob.identity.dhKeyPair.publicKey,
        identityKeyEd25519: bob.identity.signingKeyPair.publicKey,
        signedPreKeyId: 1,
        signedPreKey: bob.signedPreKey.publicKey,
        signedPreKeySignature: tampered,
      );

      expect(
        () => x3dhInitiate(identity: alice.identity, bundle: bad),
        throwsA(isA<X3dhVerificationException>()),
      );
    });

    test('rejects a swapped prekey under a valid signature', () async {
      // Signature is genuine but covers a different key: the classic
      // "valid signature, wrong message" substitution.
      final alice = await _newDevice();
      final bob = await _newDevice();
      final other = await generateKeyPair();

      final bad = PreKeyBundle(
        deviceId: 'd',
        registrationId: 1,
        identityKey: bob.identity.dhKeyPair.publicKey,
        identityKeyEd25519: bob.identity.signingKeyPair.publicKey,
        signedPreKeyId: 1,
        signedPreKey: other.publicKey,
        signedPreKeySignature: bob.signedPreKeySignature,
      );

      expect(
        () => x3dhInitiate(identity: alice.identity, bundle: bad),
        throwsA(isA<X3dhVerificationException>()),
      );
    });
  });

  group('Ed25519 signing', () {
    test('signs and verifies', () async {
      final kp = await generateSigningKeyPair();
      final message = 'prekey bytes'.codeUnits;
      final sig = await sign(seed: kp.seed, message: message);

      expect(sig.length, ed25519SignatureLength);
      expect(
        await verifySignature(
            publicKey: kp.publicKey, message: message, signature: sig),
        isTrue,
      );
    });

    test('rejects another key\'s signature', () async {
      final a = await generateSigningKeyPair();
      final b = await generateSigningKeyPair();
      final message = 'prekey bytes'.codeUnits;
      final sig = await sign(seed: a.seed, message: message);

      expect(
        await verifySignature(
            publicKey: b.publicKey, message: message, signature: sig),
        isFalse,
      );
    });

    test('returns false for malformed input instead of throwing', () async {
      final kp = await generateSigningKeyPair();
      expect(
        await verifySignature(
          publicKey: kp.publicKey,
          message: const [1],
          signature: Uint8List(10),
        ),
        isFalse,
        reason: 'a truncated signature must not crash the client',
      );
    });

    test('key pair restored from seed matches', () async {
      final original = await generateSigningKeyPair();
      final restored = await signingKeyPairFromSeed(original.seed);
      expect(restored.publicKey, equals(original.publicKey));
    });
  });
}
