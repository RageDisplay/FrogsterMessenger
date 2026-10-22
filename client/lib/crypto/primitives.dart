/// Cryptographic primitives used by the Frogster protocol layer.
///
/// Nothing here invents a primitive. X25519, HKDF-SHA256, AES-256-GCM and
/// HMAC-SHA256 come from the `cryptography` package (Apache-2.0); this file
/// only wraps them in the shapes the X3DH and Double Ratchet layers need, so
/// that the protocol code reads like the specification rather than like
/// library plumbing.
///
/// See docs/adr/0001-crypto-library-choice.md for why the protocol layer is
/// written here instead of taken from an existing Signal library.
library;

import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Length of a Curve25519 scalar/point in bytes.
const int curve25519KeyLength = 32;

/// Length of a serialized public key including the DJB type prefix.
///
/// Signal prefixes serialized Curve25519 public keys with 0x05. Frogster
/// keeps that convention so key bundles are wire-compatible in shape and so
/// the server's 33-byte length check has a stable meaning.
const int djbPublicKeyLength = 33;

/// The DJB key type prefix.
const int djbKeyType = 0x05;

/// Length of a root/chain/message key.
const int symmetricKeyLength = 32;

/// Length of an AES-GCM nonce.
const int aeadNonceLength = 12;

/// Length of an AES-GCM authentication tag.
const int aeadTagLength = 16;

final X25519 _x25519 = X25519();
final AesGcm _aesGcm = AesGcm.with256bits();
final Hkdf _hkdfSha256 = Hkdf(hmac: Hmac.sha256(), outputLength: symmetricKeyLength);
final Hmac _hmacSha256 = Hmac.sha256();
final Sha256 _sha256 = Sha256();
final Sha512 _sha512 = Sha512();

/// A Curve25519 key pair held only on this device.
///
/// The private half never leaves the process except through
/// [SecureKeyStorage], which persists it in the platform keychain.
class KeyPair {
  KeyPair({required this.privateKey, required this.publicKey})
      : assert(privateKey.length == curve25519KeyLength),
        assert(publicKey.length == curve25519KeyLength);

  /// Raw 32-byte Curve25519 scalar.
  final Uint8List privateKey;

  /// Raw 32-byte Curve25519 point (no type prefix).
  final Uint8List publicKey;

  /// The public key serialized with the DJB type prefix (33 bytes).
  Uint8List get serializedPublicKey {
    final out = Uint8List(djbPublicKeyLength);
    out[0] = djbKeyType;
    out.setRange(1, djbPublicKeyLength, publicKey);
    return out;
  }
}

/// Strips the DJB type prefix from a serialized public key.
///
/// Throws [FormatException] when the input is not a well-formed 33-byte
/// prefixed key, so malformed peer material fails loudly at the boundary
/// rather than producing a silently wrong shared secret.
Uint8List deserializePublicKey(List<int> serialized) {
  if (serialized.length == curve25519KeyLength) {
    // Already raw; accept for internal callers.
    return Uint8List.fromList(serialized);
  }
  if (serialized.length != djbPublicKeyLength) {
    throw FormatException(
      'public key must be $djbPublicKeyLength bytes, got ${serialized.length}',
    );
  }
  if (serialized[0] != djbKeyType) {
    throw FormatException(
      'unknown key type 0x${serialized[0].toRadixString(16)}',
    );
  }
  return Uint8List.fromList(serialized.sublist(1));
}

/// Generates a fresh Curve25519 key pair.
Future<KeyPair> generateKeyPair() async {
  final kp = await _x25519.newKeyPair();
  final priv = await kp.extractPrivateKeyBytes();
  final pub = await kp.extractPublicKey();
  return KeyPair(
    privateKey: Uint8List.fromList(priv),
    publicKey: Uint8List.fromList(pub.bytes),
  );
}

/// Rebuilds a key pair from a stored private scalar.
Future<KeyPair> keyPairFromPrivateKey(Uint8List privateKey) async {
  if (privateKey.length != curve25519KeyLength) {
    throw ArgumentError('private key must be $curve25519KeyLength bytes');
  }
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  final pub = await kp.extractPublicKey();
  return KeyPair(
    privateKey: privateKey,
    publicKey: Uint8List.fromList(pub.bytes),
  );
}

/// Computes the X25519 shared secret between our private key and a peer's
/// public key.
///
/// An all-zero output means the peer supplied a small-order point, which would
/// make the "shared" secret predictable to an attacker. That is rejected
/// rather than used.
Future<Uint8List> diffieHellman({
  required Uint8List privateKey,
  required Uint8List peerPublicKey,
}) async {
  final kp = await _x25519.newKeyPairFromSeed(privateKey);
  final peer = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);

  final shared = await _x25519.sharedSecretKey(
    keyPair: kp,
    remotePublicKey: peer,
  );
  final bytes = Uint8List.fromList(await shared.extractBytes());

  if (_isAllZero(bytes)) {
    throw StateError(
      'X25519 produced an all-zero shared secret; peer sent a small-order point',
    );
  }
  return bytes;
}

/// HKDF-SHA256 extract-and-expand.
Future<Uint8List> hkdf({
  required Uint8List inputKeyMaterial,
  required Uint8List salt,
  required List<int> info,
  int outputLength = symmetricKeyLength,
}) async {
  final hkdf = outputLength == symmetricKeyLength
      ? _hkdfSha256
      : Hkdf(hmac: Hmac.sha256(), outputLength: outputLength);

  final derived = await hkdf.deriveKey(
    secretKey: SecretKey(inputKeyMaterial),
    nonce: salt,
    info: info,
  );
  return Uint8List.fromList(await derived.extractBytes());
}

/// HMAC-SHA256 over [data] with [key].
Future<Uint8List> hmacSha256(Uint8List key, List<int> data) async {
  final mac = await _hmacSha256.calculateMac(data, secretKey: SecretKey(key));
  return Uint8List.fromList(mac.bytes);
}

/// SHA-256 digest.
Future<Uint8List> sha256(List<int> data) async {
  final hash = await _sha256.hash(data);
  return Uint8List.fromList(hash.bytes);
}

/// SHA-512 digest.
Future<Uint8List> sha512(List<int> data) async {
  final hash = await _sha512.hash(data);
  return Uint8List.fromList(hash.bytes);
}

/// Ciphertext produced by [aeadEncrypt]: nonce, body and tag together.
class AeadCiphertext {
  const AeadCiphertext({
    required this.nonce,
    required this.body,
    required this.tag,
  });

  final Uint8List nonce;
  final Uint8List body;
  final Uint8List tag;

  /// Serializes as nonce || body || tag.
  Uint8List serialize() {
    final out = Uint8List(nonce.length + body.length + tag.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + body.length, body);
    out.setRange(nonce.length + body.length, out.length, tag);
    return out;
  }

  /// Parses the nonce || body || tag layout.
  static AeadCiphertext deserialize(Uint8List raw) {
    if (raw.length < aeadNonceLength + aeadTagLength) {
      throw FormatException('ciphertext too short: ${raw.length} bytes');
    }
    return AeadCiphertext(
      nonce: Uint8List.sublistView(raw, 0, aeadNonceLength),
      body: Uint8List.sublistView(raw, aeadNonceLength, raw.length - aeadTagLength),
      tag: Uint8List.sublistView(raw, raw.length - aeadTagLength),
    );
  }
}

/// AES-256-GCM encryption.
///
/// [associatedData] is authenticated but not encrypted. The ratchet binds
/// message headers there, so an attacker cannot swap a header onto a body from
/// a different message.
Future<AeadCiphertext> aeadEncrypt({
  required Uint8List key,
  required List<int> plaintext,
  required List<int> associatedData,
  Uint8List? nonce,
}) async {
  if (key.length != symmetricKeyLength) {
    throw ArgumentError('AEAD key must be $symmetricKeyLength bytes');
  }
  final box = await _aesGcm.encrypt(
    plaintext,
    secretKey: SecretKey(key),
    nonce: nonce ?? _aesGcm.newNonce(),
    aad: associatedData,
  );
  return AeadCiphertext(
    nonce: Uint8List.fromList(box.nonce),
    body: Uint8List.fromList(box.cipherText),
    tag: Uint8List.fromList(box.mac.bytes),
  );
}

/// AES-256-GCM decryption.
///
/// Throws [SecretBoxAuthenticationError] when the tag does not verify, which
/// callers must treat as a forged or corrupted message and never as an
/// empty plaintext.
Future<Uint8List> aeadDecrypt({
  required Uint8List key,
  required AeadCiphertext ciphertext,
  required List<int> associatedData,
}) async {
  if (key.length != symmetricKeyLength) {
    throw ArgumentError('AEAD key must be $symmetricKeyLength bytes');
  }
  final box = SecretBox(
    ciphertext.body,
    nonce: ciphertext.nonce,
    mac: Mac(ciphertext.tag),
  );
  final plain = await _aesGcm.decrypt(
    box,
    secretKey: SecretKey(key),
    aad: associatedData,
  );
  return Uint8List.fromList(plain);
}

/// Compares two byte strings in constant time.
///
/// Ordinary `==` short-circuits on the first differing byte, which leaks how
/// much of a MAC an attacker guessed correctly and enables forgery by timing.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Overwrites a buffer holding key material.
///
/// Dart cannot guarantee the bytes are gone (the GC may already have copied
/// them), but zeroing shrinks the window in which a heap dump or swapped page
/// exposes a key.
void wipe(Uint8List buffer) {
  buffer.fillRange(0, buffer.length, 0);
}

bool _isAllZero(List<int> bytes) {
  var acc = 0;
  for (final b in bytes) {
    acc |= b;
  }
  return acc == 0;
}
