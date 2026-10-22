/// Ed25519 signatures over prekeys and sender keys.
///
/// A device holds two identity key pairs: Curve25519 for Diffie-Hellman
/// (X3DH cannot use an Edwards signing key) and Ed25519 for signatures
/// (Curve25519 cannot sign). Signal instead derives signatures from the DH key
/// via XEdDSA, which needs Edwards-curve arithmetic that no maintained
/// permissive Dart package exposes -- see docs/adr/0002.
///
/// Both algorithms here come from `cryptography` (Apache-2.0). No curve
/// arithmetic is implemented in this project.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Length of an Ed25519 public key.
const int ed25519PublicKeyLength = 32;

/// Length of an Ed25519 signature.
const int ed25519SignatureLength = 64;

final Ed25519 _ed25519 = Ed25519();

/// An Ed25519 signing key pair.
class SigningKeyPair {
  SigningKeyPair({required this.seed, required this.publicKey})
      : assert(seed.length == 32),
        assert(publicKey.length == ed25519PublicKeyLength);

  /// The 32-byte seed. Ed25519 private keys are derived from it, so this is
  /// what gets persisted in secure storage.
  final Uint8List seed;

  /// The 32-byte public key, published in key bundles.
  final Uint8List publicKey;
}

/// Generates a fresh Ed25519 signing key pair.
Future<SigningKeyPair> generateSigningKeyPair() async {
  final kp = await _ed25519.newKeyPair();
  return _fromKeyPair(kp);
}

/// Rebuilds a signing key pair from its stored seed.
Future<SigningKeyPair> signingKeyPairFromSeed(Uint8List seed) async {
  if (seed.length != 32) {
    throw ArgumentError('Ed25519 seed must be 32 bytes, got ${seed.length}');
  }
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  return _fromKeyPair(kp);
}

Future<SigningKeyPair> _fromKeyPair(SimpleKeyPair kp) async {
  final seed = await kp.extractPrivateKeyBytes();
  final pub = await kp.extractPublicKey();
  return SigningKeyPair(
    seed: Uint8List.fromList(seed),
    publicKey: Uint8List.fromList(pub.bytes),
  );
}

/// Signs [message] with the device's Ed25519 identity key.
Future<Uint8List> sign({
  required Uint8List seed,
  required List<int> message,
}) async {
  final kp = await _ed25519.newKeyPairFromSeed(seed);
  final signature = await _ed25519.sign(message, keyPair: kp);
  return Uint8List.fromList(signature.bytes);
}

/// Verifies an Ed25519 signature.
///
/// Returns false rather than throwing for any malformed input, so a peer
/// cannot crash a client by sending a truncated signature. Callers must treat
/// false as "reject this key bundle".
Future<bool> verifySignature({
  required Uint8List publicKey,
  required List<int> message,
  required Uint8List signature,
}) async {
  if (publicKey.length != ed25519PublicKeyLength ||
      signature.length != ed25519SignatureLength) {
    return false;
  }
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}
