/// X3DH (Extended Triple Diffie-Hellman) key agreement.
///
/// Implements https://signal.org/docs/specifications/x3dh/ over the primitives
/// in `primitives.dart`. X3DH lets Alice start an encrypted session with Bob
/// while Bob is offline, by combining several Diffie-Hellman operations
/// against key material Bob published in advance.
library;

import 'dart:typed_data';

import 'primitives.dart';
import 'signing.dart';

/// Domain separation string for the shared-secret KDF.
///
/// Binding the curve and hash into the KDF info keeps this output distinct
/// from any other protocol that might reuse the same DH values.
const String x3dhInfo = 'Frogster_X3DH_25519_AESGCM_SHA256';

/// A peer's published key bundle, fetched from `GET /v1/keys/{username}`.
class PreKeyBundle {
  const PreKeyBundle({
    required this.deviceId,
    required this.registrationId,
    required this.identityKey,
    required this.identityKeyEd25519,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    this.oneTimePreKeyId,
    this.oneTimePreKey,
  });

  final String deviceId;
  final int registrationId;

  /// Curve25519 DH identity key (raw 32 bytes).
  final Uint8List identityKey;

  /// Ed25519 signing identity key (32 bytes), used to verify [signedPreKey].
  final Uint8List identityKeyEd25519;

  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;

  /// A one-time prekey, when the peer's pool was not exhausted. Absent means
  /// the session starts without DH4, which weakens forward secrecy for the
  /// first message only.
  final int? oneTimePreKeyId;
  final Uint8List? oneTimePreKey;

  bool get hasOneTimePreKey => oneTimePreKey != null;
}

/// Our own long-term identity, held only on this device.
class IdentityKeys {
  const IdentityKeys({required this.dhKeyPair, required this.signingKeyPair});

  /// Curve25519 pair used for Diffie-Hellman.
  final KeyPair dhKeyPair;

  /// Ed25519 pair used for signatures.
  final SigningKeyPair signingKeyPair;
}

/// A signed prekey together with its private half.
class SignedPreKeyPair {
  const SignedPreKeyPair({
    required this.keyId,
    required this.keyPair,
    required this.signature,
  });

  final int keyId;
  final KeyPair keyPair;
  final Uint8List signature;
}

/// Result of running X3DH as the initiator.
class X3dhInitiatorResult {
  const X3dhInitiatorResult({
    required this.sharedSecret,
    required this.ephemeralPublicKey,
    required this.associatedData,
    required this.usedOneTimePreKeyId,
  });

  /// The 32-byte secret seeding the Double Ratchet root key.
  final Uint8List sharedSecret;

  /// Our ephemeral public key, sent in the first message so the responder can
  /// reproduce the same DH values.
  final Uint8List ephemeralPublicKey;

  /// IK_A || IK_B, authenticated with every message in the session. Binding
  /// both identities stops an attacker from replaying a session transcript
  /// against a different pair of users.
  final Uint8List associatedData;

  final int? usedOneTimePreKeyId;
}

/// Result of running X3DH as the responder.
class X3dhResponderResult {
  const X3dhResponderResult({
    required this.sharedSecret,
    required this.associatedData,
  });

  final Uint8List sharedSecret;
  final Uint8List associatedData;
}

/// Thrown when a peer's bundle fails verification.
class X3dhVerificationException implements Exception {
  const X3dhVerificationException(this.message);
  final String message;

  @override
  String toString() => 'X3dhVerificationException: $message';
}

/// Runs X3DH as the initiator (Alice), against Bob's published bundle.
///
/// Steps, per the specification:
/// ```
/// verify Sig(IK_B, SPK_B)          -- abort if invalid
/// generate ephemeral EK_A
/// DH1 = DH(IK_A,  SPK_B)
/// DH2 = DH(EK_A,  IK_B)
/// DH3 = DH(EK_A,  SPK_B)
/// DH4 = DH(EK_A,  OPK_B)           -- omitted when no one-time prekey
/// SK  = HKDF(F || DH1 || DH2 || DH3 || DH4)
/// ```
///
/// DH1 authenticates Alice to Bob (only Alice holds IK_A); DH2 authenticates
/// Bob to Alice; DH3 and DH4 provide forward secrecy. Dropping any one of them
/// silently removes one of those properties, which is why the order and the
/// full set are reproduced literally.
Future<X3dhInitiatorResult> x3dhInitiate({
  required IdentityKeys identity,
  required PreKeyBundle bundle,
}) async {
  // The signature binds the prekey to the peer's identity. Skipping this check
  // would let a malicious server substitute its own prekey and read everything.
  final signatureValid = await verifySignature(
    publicKey: bundle.identityKeyEd25519,
    message: bundle.signedPreKey,
    signature: bundle.signedPreKeySignature,
  );
  if (!signatureValid) {
    throw const X3dhVerificationException(
      'signed prekey signature is invalid; refusing to start a session',
    );
  }

  final ephemeral = await generateKeyPair();

  final dh1 = await diffieHellman(
    privateKey: identity.dhKeyPair.privateKey,
    peerPublicKey: bundle.signedPreKey,
  );
  final dh2 = await diffieHellman(
    privateKey: ephemeral.privateKey,
    peerPublicKey: bundle.identityKey,
  );
  final dh3 = await diffieHellman(
    privateKey: ephemeral.privateKey,
    peerPublicKey: bundle.signedPreKey,
  );
  Uint8List? dh4;
  if (bundle.oneTimePreKey != null) {
    dh4 = await diffieHellman(
      privateKey: ephemeral.privateKey,
      peerPublicKey: bundle.oneTimePreKey!,
    );
  }

  final sharedSecret = await _deriveSharedSecret([dh1, dh2, dh3, dh4]);

  // Intermediate DH outputs are no longer needed; clear them promptly.
  wipe(dh1);
  wipe(dh2);
  wipe(dh3);
  if (dh4 != null) wipe(dh4);

  return X3dhInitiatorResult(
    sharedSecret: sharedSecret,
    ephemeralPublicKey: ephemeral.publicKey,
    associatedData: _associatedData(
      identity.dhKeyPair.publicKey,
      bundle.identityKey,
    ),
    usedOneTimePreKeyId: bundle.oneTimePreKeyId,
  );
}

/// Runs X3DH as the responder (Bob), reproducing the initiator's DH values.
///
/// The roles are mirrored: where Alice used her private key against Bob's
/// public key, Bob uses his private key against Alice's public key. Getting
/// this pairing wrong produces a different secret and shows up as an
/// undecryptable first message.
Future<X3dhResponderResult> x3dhRespond({
  required IdentityKeys identity,
  required KeyPair signedPreKeyPair,
  required Uint8List initiatorIdentityKey,
  required Uint8List initiatorEphemeralKey,
  KeyPair? oneTimePreKeyPair,
}) async {
  // DH1: Alice used (IK_A, SPK_B), so Bob uses (SPK_B, IK_A).
  final dh1 = await diffieHellman(
    privateKey: signedPreKeyPair.privateKey,
    peerPublicKey: initiatorIdentityKey,
  );
  // DH2: Alice used (EK_A, IK_B), so Bob uses (IK_B, EK_A).
  final dh2 = await diffieHellman(
    privateKey: identity.dhKeyPair.privateKey,
    peerPublicKey: initiatorEphemeralKey,
  );
  // DH3: Alice used (EK_A, SPK_B), so Bob uses (SPK_B, EK_A).
  final dh3 = await diffieHellman(
    privateKey: signedPreKeyPair.privateKey,
    peerPublicKey: initiatorEphemeralKey,
  );
  Uint8List? dh4;
  if (oneTimePreKeyPair != null) {
    dh4 = await diffieHellman(
      privateKey: oneTimePreKeyPair.privateKey,
      peerPublicKey: initiatorEphemeralKey,
    );
  }

  final sharedSecret = await _deriveSharedSecret([dh1, dh2, dh3, dh4]);

  wipe(dh1);
  wipe(dh2);
  wipe(dh3);
  if (dh4 != null) wipe(dh4);

  return X3dhResponderResult(
    sharedSecret: sharedSecret,
    associatedData: _associatedData(
      initiatorIdentityKey,
      identity.dhKeyPair.publicKey,
    ),
  );
}

/// KDF over the concatenated DH outputs.
///
/// The 32 leading 0xFF bytes are the specification's domain separator for
/// Curve25519; the all-zero salt is likewise specified.
Future<Uint8List> _deriveSharedSecret(List<Uint8List?> dhOutputs) async {
  final present = dhOutputs.whereType<Uint8List>().toList();
  final f = Uint8List(32)..fillRange(0, 32, 0xFF);

  final ikm = Uint8List(f.length + present.length * curve25519KeyLength);
  ikm.setRange(0, f.length, f);
  var offset = f.length;
  for (final dh in present) {
    ikm.setRange(offset, offset + dh.length, dh);
    offset += dh.length;
  }

  final secret = await hkdf(
    inputKeyMaterial: ikm,
    salt: Uint8List(32),
    info: x3dhInfo.codeUnits,
  );
  wipe(ikm);
  return secret;
}

/// Builds the associated data: IK_A || IK_B, always in initiator-then-responder
/// order so both sides compute the same bytes.
Uint8List _associatedData(Uint8List initiatorIk, Uint8List responderIk) {
  final out = Uint8List(initiatorIk.length + responderIk.length);
  out.setRange(0, initiatorIk.length, initiatorIk);
  out.setRange(initiatorIk.length, out.length, responderIk);
  return out;
}
