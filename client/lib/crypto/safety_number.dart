/// Safety numbers and trust-on-first-use.
///
/// The server never proves that a published identity key belongs to the person
/// it claims. A malicious or compromised server can therefore hand Alice its
/// own key in place of Bob's and read everything.
///
/// Two mitigations make that attack detectable rather than silent:
///   * pin a peer's identity key the first time a session is built, and refuse
///     to send when it changes until the user explicitly accepts;
///   * show a safety number both users can compare out of band.
///
/// Without these the end-to-end claim is not defensible, so they are part of
/// the protocol rather than a UI nicety.
library;

import 'dart:typed_data';

import 'primitives.dart';

/// Number of iterations used to derive a fingerprint.
///
/// Signal uses 5200 to make brute-forcing a colliding key pair expensive: an
/// attacker who wants a key whose safety number matches the victim's must
/// repeat the whole chain for each guess.
const int fingerprintIterations = 5200;

/// Version marker mixed into fingerprints so the format can change later.
const int fingerprintVersion = 0;

/// The result of comparing a peer's key against what we pinned earlier.
enum TrustDecision {
  /// No key was pinned; this is the first contact. Pin and proceed.
  firstUse,

  /// The key matches what we pinned.
  matched,

  /// The key differs from what we pinned. Block sending and ask the user.
  changed,
}

/// A pinned peer identity.
class PinnedIdentity {
  const PinnedIdentity({
    required this.userId,
    required this.deviceId,
    required this.identityKey,
    required this.pinnedAt,
    this.acceptedChange = false,
  });

  final String userId;
  final String deviceId;
  final Uint8List identityKey;
  final DateTime pinnedAt;

  /// True when the user explicitly accepted a key change for this peer.
  final bool acceptedChange;
}

/// Compares a freshly fetched identity key against the pinned one.
TrustDecision evaluateTrust({
  required PinnedIdentity? pinned,
  required Uint8List presentedKey,
}) {
  if (pinned == null) return TrustDecision.firstUse;
  return constantTimeEquals(pinned.identityKey, presentedKey)
      ? TrustDecision.matched
      : TrustDecision.changed;
}

/// Computes the 60-digit safety number for a conversation.
///
/// Both users see the same digits regardless of who looks: the two
/// fingerprints are sorted before concatenation, so the result does not depend
/// on which side is "local".
Future<String> safetyNumber({
  required String localUserId,
  required Uint8List localIdentityKey,
  required String remoteUserId,
  required Uint8List remoteIdentityKey,
}) async {
  final local = await _fingerprint(localUserId, localIdentityKey);
  final remote = await _fingerprint(remoteUserId, remoteIdentityKey);

  final ordered = [local, remote]..sort();
  return ordered[0] + ordered[1];
}

/// Formats a safety number as 12 groups of 5 digits, which is how it is shown
/// to users for comparison.
String formatSafetyNumber(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i += 5) {
    if (i > 0) buffer.write(i % 25 == 0 ? '\n' : ' ');
    buffer.write(digits.substring(i, (i + 5).clamp(0, digits.length)));
  }
  return buffer.toString();
}

/// Derives one party's 30-digit fingerprint.
Future<String> _fingerprint(String userId, Uint8List identityKey) async {
  final seed = Uint8List.fromList([
    fingerprintVersion,
    ...identityKey,
    ...userId.codeUnits,
  ]);

  var hash = await sha512(seed);
  // Iterated hashing raises the cost of searching for a colliding key.
  for (var i = 1; i < fingerprintIterations; i++) {
    hash = await sha512(Uint8List.fromList([...hash, ...identityKey]));
  }

  final buffer = StringBuffer();
  for (var i = 0; i < 30; i += 5) {
    buffer.write(_encodeChunk(hash, i ~/ 5));
  }
  return buffer.toString();
}

/// Turns 5 bytes of the digest into 5 decimal digits.
String _encodeChunk(Uint8List hash, int index) {
  final offset = index * 5;
  var value = 0;
  for (var i = 0; i < 5; i++) {
    value = (value << 8) | hash[offset + i];
  }
  return (value % 100000).toString().padLeft(5, '0');
}
