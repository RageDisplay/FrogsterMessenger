/// The client's cryptographic facade.
///
/// Everything above this layer -- repositories, blocs, UI -- deals only in
/// plaintext and opaque ciphertext. No protocol type (ratchet state, chain
/// keys, prekeys) escapes this file's implementation, so the whole crypto
/// core can be replaced without touching application code.
///
/// That seam matters here specifically: the Double Ratchet is implemented in
/// this project rather than taken from a library (see ADR 0001), so if the
/// licensing situation changes and a permissive audited implementation
/// appears, swapping to it should mean writing one new class.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'primitives.dart';
import 'ratchet/double_ratchet.dart';
import 'safety_number.dart';
import 'secure_key_storage.dart';
import 'signing.dart';
import 'x3dh.dart';

/// Addresses one device of one user.
class PeerAddress {
  const PeerAddress({required this.userId, required this.deviceId});

  final String userId;
  final String deviceId;

  String get key => '$userId:$deviceId';

  @override
  bool operator ==(Object other) =>
      other is PeerAddress &&
      other.userId == userId &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(userId, deviceId);

  @override
  String toString() => key;
}

/// Public key material this device publishes on registration.
class PublicKeyBundle {
  const PublicKeyBundle({
    required this.registrationId,
    required this.identityKey,
    required this.identityKeyEd25519,
    required this.signedPreKeyId,
    required this.signedPreKey,
    required this.signedPreKeySignature,
    required this.oneTimePreKeys,
  });

  final int registrationId;

  /// Curve25519 DH key, DJB-prefixed for the wire.
  final Uint8List identityKey;

  /// Ed25519 signing key.
  final Uint8List identityKeyEd25519;

  final int signedPreKeyId;
  final Uint8List signedPreKey;
  final Uint8List signedPreKeySignature;

  /// Key id to serialized public key.
  final Map<int, Uint8List> oneTimePreKeys;

  Map<String, dynamic> toJson() => {
        'registration_id': registrationId,
        'identity_key': base64Encode(identityKey),
        'identity_key_ed25519': base64Encode(identityKeyEd25519),
        'signed_pre_key': {
          'key_id': signedPreKeyId,
          'public_key': base64Encode(signedPreKey),
          'signature': base64Encode(signedPreKeySignature),
        },
        'one_time_pre_keys': oneTimePreKeys.entries
            .map((e) => {
                  'key_id': e.key,
                  'public_key': base64Encode(e.value),
                })
            .toList(),
      };
}

/// Cipher types, mirroring the server's `cipher_type` column.
const int cipherTypePreKey = 1;
const int cipherTypeWhisper = 2;
const int cipherTypeSenderKey = 3;

/// An encrypted message ready for the wire.
///
/// A [cipherTypePreKey] message is self-contained: it carries the initiator's
/// identity and ephemeral public keys plus the id of the one-time prekey it
/// consumed, so the recipient can complete X3DH without any prior state. That
/// is what lets Alice message Bob while Bob is offline.
class EncryptedPayload {
  const EncryptedPayload({
    required this.cipherType,
    required this.body,
    this.initiatorIdentityKey,
    this.initiatorEphemeralKey,
    this.oneTimePreKeyId,
    this.signedPreKeyId,
  });

  final int cipherType;
  final Uint8List body;

  /// Set only on prekey messages.
  final Uint8List? initiatorIdentityKey;
  final Uint8List? initiatorEphemeralKey;
  final int? oneTimePreKeyId;

  /// Which of the responder's signed prekeys the handshake used. Absent in
  /// messages from clients that predate signed prekey rotation, which always
  /// used the current one.
  final int? signedPreKeyId;

  bool get isPreKeyMessage => cipherType == cipherTypePreKey;

  Map<String, dynamic> toJson() => {
        'ct': cipherType,
        'body': base64Encode(body),
        if (initiatorIdentityKey != null)
          'ik': base64Encode(initiatorIdentityKey!),
        if (initiatorEphemeralKey != null)
          'ek': base64Encode(initiatorEphemeralKey!),
        if (oneTimePreKeyId != null) 'otp': oneTimePreKeyId,
        if (signedPreKeyId != null) 'spk': signedPreKeyId,
      };

  static EncryptedPayload fromJson(Map<String, dynamic> json) =>
      EncryptedPayload(
        cipherType: json['ct'] as int,
        body: base64Decode(json['body'] as String),
        initiatorIdentityKey: json['ik'] == null
            ? null
            : base64Decode(json['ik'] as String),
        initiatorEphemeralKey: json['ek'] == null
            ? null
            : base64Decode(json['ek'] as String),
        oneTimePreKeyId: json['otp'] as int?,
        signedPreKeyId: json['spk'] as int?,
      );
}

/// A new signed prekey's public half, ready to upload.
class SignedPreKeyUpload {
  const SignedPreKeyUpload({
    required this.keyId,
    required this.publicKey,
    required this.signature,
    required this.pending,
  });

  final int keyId;

  /// DJB-prefixed public key.
  final Uint8List publicKey;
  final Uint8List signature;

  /// The full pair, committed with [CryptoEngine.commitSignedPreKeyRotation]
  /// once the server has accepted the upload.
  final SignedPreKeyPair pending;

  Map<String, dynamic> toJson() => {
        'key_id': keyId,
        'public_key': base64Encode(publicKey),
        'signature': base64Encode(signature),
      };
}

/// How long a signed prekey is published before it is replaced.
///
/// The private half of a signed prekey can decrypt the first messages of
/// every session built on it, so it bounds how far back a device compromise
/// reaches. Signal rotates on a similar schedule.
const Duration signedPreKeyMaxAge = Duration(days: 7);

/// Raised when a peer's identity key differs from the pinned one and the
/// engine is running in [TrustPolicy.strict].
///
/// Sending is blocked until the user accepts the change. Auto-accepting would
/// make a malicious server's key substitution invisible, which is the whole
/// attack trust-on-first-use exists to surface.
class IdentityChangedException implements Exception {
  const IdentityChangedException(this.peer);
  final PeerAddress peer;

  @override
  String toString() =>
      'IdentityChangedException: identity key for $peer changed; '
      'user must verify the new safety number before sending';
}

/// How the engine reacts to a peer's identity key changing.
///
/// The change itself is unavoidable and usually benign: replacing a phone
/// means new keys, because a private key that could move between devices would
/// not be device-bound in the first place.
enum TrustPolicy {
  /// Re-establish the session automatically and report the change, the way
  /// WhatsApp and Signal do.
  ///
  /// Sending keeps working, so a contact who switches phones does not silently
  /// become unreachable. The trade-off is real and deliberate: a malicious
  /// server substituting a key is surfaced as a notice rather than a wall, so
  /// a user who ignores the notice can be MITM'd. Blocking instead would make
  /// every device upgrade look identical to an attack, which trains people to
  /// dismiss the warning that matters.
  notifyAndReestablish,

  /// Refuse to encrypt until the user verifies the new safety number.
  ///
  /// Safe against key substitution, at the cost of both sides needing a manual
  /// step whenever either replaces a device.
  strict,
}

/// A peer's identity key changed and the session was rebuilt automatically.
///
/// Reported rather than thrown: under [TrustPolicy.notifyAndReestablish] the
/// message still goes out, so this is a notice for the UI, not a failure.
class IdentityChangeNotice {
  const IdentityChangeNotice({
    required this.peer,
    required this.previousKey,
    required this.newKey,
  });

  final PeerAddress peer;
  final Uint8List previousKey;
  final Uint8List newKey;
}

/// The cryptographic operations the application layer needs.
abstract class CryptoEngine {
  /// Creates this device's identity on first launch, or loads the existing
  /// one. Returns the public material to upload.
  Future<PublicKeyBundle> initializeIdentity({int oneTimePreKeyCount = 100});

  /// Generates additional one-time prekeys when the server's pool runs low.
  Future<Map<int, Uint8List>> generateOneTimePreKeys(int count);

  /// Returns a replacement signed prekey when the current one is older than
  /// [maxAge], or null when no rotation is due.
  ///
  /// Two-phase on purpose: nothing changes locally until
  /// [commitSignedPreKeyRotation] runs after a successful upload, so a failed
  /// upload never leaves the server publishing a key this device has dropped.
  Future<SignedPreKeyUpload?> prepareSignedPreKeyRotation({
    Duration maxAge = signedPreKeyMaxAge,
  });

  /// Installs a rotated signed prekey, keeping the previous one so prekey
  /// messages built against it still decrypt.
  Future<void> commitSignedPreKeyRotation(SignedPreKeyUpload upload);

  /// Establishes a session with a peer from their published bundle.
  ///
  /// Used by whoever speaks first. The peer completes the handshake with
  /// [establishInboundSession] when the initial message arrives.
  Future<void> establishOutboundSession(PeerAddress peer, PreKeyBundle bundle);

  /// Completes the handshake as the responder, using the material carried in
  /// the initiator's first message.
  ///
  /// The initiator and responder run mirrored halves of X3DH: swapping them
  /// yields different shared secrets and an undecryptable first message.
  Future<void> establishInboundSession({
    required PeerAddress peer,
    required Uint8List initiatorIdentityKey,
    required Uint8List initiatorEphemeralKey,
    int? oneTimePreKeyId,
    int? signedPreKeyId,
  });

  /// True when a session with this peer already exists.
  Future<bool> hasSession(PeerAddress peer);

  /// Encrypts a message for a peer device.
  Future<EncryptedPayload> encrypt(PeerAddress peer, List<int> plaintext);

  /// Decrypts a message from a peer device.
  Future<Uint8List> decrypt(PeerAddress peer, EncryptedPayload payload);

  /// The safety number to display for out-of-band verification.
  Future<String> safetyNumberFor(PeerAddress peer, String localUserId);

  /// Records that the user accepted a changed identity key.
  Future<void> acceptIdentityChange(PeerAddress peer);

  /// The identity currently pinned for a peer device, if any.
  ///
  /// Lets callers detect a key change before committing to a handshake.
  Future<PinnedIdentity?> pinnedIdentityFor(PeerAddress peer);

  /// Identity key changes that were accepted automatically.
  ///
  /// Only emits under [TrustPolicy.notifyAndReestablish]; strict mode throws
  /// [IdentityChangedException] instead.
  Stream<IdentityChangeNotice> get identityChanges;
}

/// Handshake material an initiator must attach to its early messages.
class _PendingHandshake {
  const _PendingHandshake({
    required this.identityKey,
    required this.ephemeralKey,
    required this.oneTimePreKeyId,
    required this.signedPreKeyId,
  });

  final Uint8List identityKey;
  final Uint8List ephemeralKey;
  final int? oneTimePreKeyId;
  final int? signedPreKeyId;

  Map<String, dynamic> toJson() => {
        'ik': base64Encode(identityKey),
        'ek': base64Encode(ephemeralKey),
        if (oneTimePreKeyId != null) 'otp': oneTimePreKeyId,
        if (signedPreKeyId != null) 'spk': signedPreKeyId,
      };

  static _PendingHandshake fromJson(Map<String, dynamic> json) =>
      _PendingHandshake(
        identityKey: base64Decode(json['ik'] as String),
        ephemeralKey: base64Decode(json['ek'] as String),
        oneTimePreKeyId: json['otp'] as int?,
        signedPreKeyId: json['spk'] as int?,
      );
}

/// A responder session built from a prekey message but not yet installed.
class _InboundCandidate {
  const _InboundCandidate({
    required this.session,
    required this.initiatorIdentityKey,
    required this.oneTimePreKeyId,
  });

  final RatchetSession session;
  final Uint8List initiatorIdentityKey;
  final int? oneTimePreKeyId;
}

/// Where ratchet sessions and pinned identities are persisted.
///
/// Session state contains live key material and must be stored encrypted.
abstract class SessionStore {
  Future<Map<String, dynamic>?> loadSession(String peerKey);
  Future<void> saveSession(String peerKey, Map<String, dynamic> state);
  Future<void> deleteSession(String peerKey);

  Future<PinnedIdentity?> loadPinnedIdentity(String peerKey);
  Future<void> savePinnedIdentity(PinnedIdentity identity);
}

/// The Frogster crypto engine: X3DH for session setup, Double Ratchet for
/// message encryption.
class FrogsterCryptoEngine implements CryptoEngine {
  FrogsterCryptoEngine({
    required KeyStorage keyStorage,
    required SessionStore sessionStore,
    TrustPolicy trustPolicy = TrustPolicy.notifyAndReestablish,
    Random? random,
  })  : _keys = keyStorage,
        _sessions = sessionStore,
        _trustPolicy = trustPolicy,
        _random = random ?? Random.secure();

  final KeyStorage _keys;
  final SessionStore _sessions;
  final TrustPolicy _trustPolicy;
  final Random _random;

  final _identityChanges = StreamController<IdentityChangeNotice>.broadcast();

  @override
  Stream<IdentityChangeNotice> get identityChanges => _identityChanges.stream;

  /// Sessions held in memory for the lifetime of the process.
  ///
  /// A session must not be loaded twice concurrently: two live copies would
  /// each advance the chain independently and derive the same message key
  /// twice, reusing an AEAD key.
  final Map<String, RatchetSession> _live = {};

  /// Handshake material awaiting its first outbound message.
  ///
  /// Every message is tagged as a prekey message until the peer replies,
  /// because until then we cannot know whether our first message reached them.
  /// Sending the material repeatedly is harmless -- the responder ignores it
  /// once a session exists -- and dropping it too early would strand a peer
  /// whose copy of the first message was lost.
  final Map<String, _PendingHandshake> _pendingHandshake = {};

  IdentityKeys? _identity;

  /// Tail of the operation queue for each peer.
  ///
  /// Every operation that reads and writes a peer's session runs through
  /// [_serialized]. The ratchet awaits between reading a chain key and storing
  /// its successor, so two overlapping calls on one session -- two frames
  /// arriving together, or a send racing a receive -- would derive the same
  /// message key twice or lose an advance, and the conversation would fail
  /// with MAC errors from then on.
  final Map<String, Future<void>> _queues = {};

  Future<T> _serialized<T>(String peerKey, Future<T> Function() body) {
    final previous = _queues[peerKey] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[peerKey] = done.future;
    return previous.then((_) => body()).whenComplete(() {
      done.complete();
      if (identical(_queues[peerKey], done.future)) _queues.remove(peerKey);
    });
  }

  @override
  Future<PublicKeyBundle> initializeIdentity({
    int oneTimePreKeyCount = 100,
  }) async {
    var identity = await _keys.loadIdentity();
    identity ??= await _keys.createIdentity();
    _identity = identity;

    var registrationId = await _keys.loadRegistrationId();
    if (registrationId == null) {
      // 14 bits, matching Signal's range, so the value fits alongside other
      // per-device metadata without collisions being likely.
      registrationId = _random.nextInt(16380) + 1;
      await _keys.saveRegistrationId(registrationId);
    }

    var spk = await _keys.loadSignedPreKey();
    if (spk == null) {
      spk = await _newSignedPreKey(identity, keyId: 1);
      await _keys.saveSignedPreKey(spk);
    }

    final oneTime = await generateOneTimePreKeys(oneTimePreKeyCount);

    return PublicKeyBundle(
      registrationId: registrationId,
      identityKey: identity.dhKeyPair.serializedPublicKey,
      identityKeyEd25519: identity.signingKeyPair.publicKey,
      signedPreKeyId: spk.keyId,
      signedPreKey: _serialize(spk.keyPair.publicKey),
      signedPreKeySignature: spk.signature,
      oneTimePreKeys: oneTime,
    );
  }

  @override
  Future<Map<int, Uint8List>> generateOneTimePreKeys(int count) async {
    // Ids come from a persisted counter. The first value is random so that a
    // reinstall, which loses the counter, is unlikely to land on ids the
    // server still holds for this device.
    var next = await _keys.loadNextOneTimePreKeyId() ??
        _random.nextInt(_maxPreKeyId ~/ 2) + 1;
    if (next + count > _maxPreKeyId) next = 1;

    final out = <int, Uint8List>{};
    for (var i = 0; i < count; i++) {
      final keyId = next + i;
      final pair = await generateKeyPair();
      await _keys.saveOneTimePreKey(keyId, pair);
      out[keyId] = pair.serializedPublicKey;
    }
    await _keys.saveNextOneTimePreKeyId(next + count);
    return out;
  }

  /// Key ids travel as uint32 on the server.
  static const int _maxPreKeyId = 0x7FFFFFFF;

  @override
  Future<SignedPreKeyUpload?> prepareSignedPreKeyRotation({
    Duration maxAge = signedPreKeyMaxAge,
  }) async {
    final identity = await _requireIdentity();
    final current = await _keys.loadSignedPreKey();
    if (current != null) {
      final createdAt = current.createdAt;
      if (createdAt != null && DateTime.now().difference(createdAt) < maxAge) {
        return null;
      }
    }

    final nextId = current == null || current.keyId >= _maxPreKeyId
        ? 1
        : current.keyId + 1;
    final pending = await _newSignedPreKey(identity, keyId: nextId);
    return SignedPreKeyUpload(
      keyId: pending.keyId,
      publicKey: _serialize(pending.keyPair.publicKey),
      signature: pending.signature,
      pending: pending,
    );
  }

  @override
  Future<void> commitSignedPreKeyRotation(SignedPreKeyUpload upload) async {
    final current = await _keys.loadSignedPreKey();
    // Only one previous key is kept: anything older has had a full rotation
    // period to be used, and holding it longer weakens forward secrecy.
    await _keys.savePreviousSignedPreKey(current);
    await _keys.saveSignedPreKey(upload.pending);
  }

  Future<SignedPreKeyPair> _newSignedPreKey(
    IdentityKeys identity, {
    required int keyId,
  }) async {
    final pair = await generateKeyPair();
    final signature = await sign(
      seed: identity.signingKeyPair.seed,
      message: pair.publicKey,
    );
    return SignedPreKeyPair(
      keyId: keyId,
      keyPair: pair,
      signature: signature,
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> establishOutboundSession(
    PeerAddress peer,
    PreKeyBundle bundle,
  ) =>
      _serialized(peer.key, () async {
        final identity = await _requireIdentity();

        // Verify the bundle before trusting anything in it: x3dhInitiate
        // checks the signed prekey signature and throws on a bad one, and a
        // rejected bundle must not get its identity key pinned or replace a
        // working session.
        final result = await x3dhInitiate(identity: identity, bundle: bundle);

        // Trust on first use: pin the peer's identity, and decide what a
        // change means according to the configured policy.
        final pinned = await _sessions.loadPinnedIdentity(peer.key);
        final decision =
            evaluateTrust(pinned: pinned, presentedKey: bundle.identityKey);

        switch (decision) {
          case TrustDecision.changed:
            await _handleIdentityChange(
              peer: peer,
              pinned: pinned!,
              presentedKey: bundle.identityKey,
            );
          case TrustDecision.firstUse:
            await _sessions.savePinnedIdentity(PinnedIdentity(
              userId: peer.userId,
              deviceId: peer.deviceId,
              identityKey: bundle.identityKey,
              pinnedAt: DateTime.now(),
            ));
          case TrustDecision.matched:
            break;
        }

        final session = await RatchetSession.initSender(
          sharedSecret: result.sharedSecret,
          receiverSignedPreKey: bundle.signedPreKey,
          associatedData: result.associatedData,
        );

        _live[peer.key] = session;

        // Held until the peer replies, because every message until then must
        // carry the material they need to complete their half of the
        // handshake.
        _pendingHandshake[peer.key] = _PendingHandshake(
          identityKey: identity.dhKeyPair.publicKey,
          ephemeralKey: result.ephemeralPublicKey,
          oneTimePreKeyId: result.usedOneTimePreKeyId,
          signedPreKeyId: bundle.signedPreKeyId,
        );

        await _persist(peer.key, session);
      });

  @override
  Future<void> establishInboundSession({
    required PeerAddress peer,
    required Uint8List initiatorIdentityKey,
    required Uint8List initiatorEphemeralKey,
    int? oneTimePreKeyId,
    int? signedPreKeyId,
  }) =>
      _serialized(peer.key, () async {
        final candidate = await _buildInboundSession(
          initiatorIdentityKey: initiatorIdentityKey,
          initiatorEphemeralKey: initiatorEphemeralKey,
          oneTimePreKeyId: oneTimePreKeyId,
          signedPreKeyId: signedPreKeyId,
        );
        await _commitInboundSession(peer, candidate);
      });

  /// Runs the responder half of X3DH without changing any stored state.
  ///
  /// Nothing in a prekey message is authenticated until its ratchet message
  /// decrypts under the session derived from it. Pinning the claimed
  /// identity, replacing the existing session or burning a one-time prekey
  /// before that point would let anyone who can inject a frame -- the server
  /// included -- fake an identity change or break a working conversation.
  Future<_InboundCandidate> _buildInboundSession({
    required Uint8List initiatorIdentityKey,
    required Uint8List initiatorEphemeralKey,
    required int? oneTimePreKeyId,
    required int? signedPreKeyId,
  }) async {
    final identity = await _requireIdentity();

    final spk = await _signedPreKeyFor(signedPreKeyId);

    // The one-time prekey the initiator consumed, if any. Its absence from
    // the message is legitimate: the server's pool may have been empty. Its
    // absence from storage is not -- the key was already used, so the derived
    // secret could never match.
    KeyPair? oneTime;
    if (oneTimePreKeyId != null) {
      oneTime = await _keys.loadOneTimePreKey(oneTimePreKeyId);
      if (oneTime == null) {
        throw RatchetException(
          'one-time prekey $oneTimePreKeyId is unknown or already used',
        );
      }
    }

    final result = await x3dhRespond(
      identity: identity,
      signedPreKeyPair: spk.keyPair,
      initiatorIdentityKey: initiatorIdentityKey,
      initiatorEphemeralKey: initiatorEphemeralKey,
      oneTimePreKeyPair: oneTime,
    );

    final session = await RatchetSession.initReceiver(
      sharedSecret: result.sharedSecret,
      signedPreKeyPair: spk.keyPair,
      associatedData: result.associatedData,
    );
    return _InboundCandidate(
      session: session,
      initiatorIdentityKey: initiatorIdentityKey,
      oneTimePreKeyId: oneTimePreKeyId,
    );
  }

  Future<SignedPreKeyPair> _signedPreKeyFor(int? keyId) async {
    final current = await _keys.loadSignedPreKey();
    if (current == null) {
      throw StateError('no signed prekey; identity not initialised');
    }
    if (keyId == null || keyId == current.keyId) return current;

    final previous = await _keys.loadPreviousSignedPreKey();
    if (previous != null && previous.keyId == keyId) return previous;
    throw RatchetException('signed prekey $keyId is no longer available');
  }

  /// Pins the initiator, installs the session and destroys the one-time
  /// prekey. Runs only once the candidate has proven itself.
  Future<void> _commitInboundSession(
    PeerAddress peer,
    _InboundCandidate candidate,
  ) async {
    final pinned = await _sessions.loadPinnedIdentity(peer.key);
    if (pinned == null) {
      await _sessions.savePinnedIdentity(PinnedIdentity(
        userId: peer.userId,
        deviceId: peer.deviceId,
        identityKey: candidate.initiatorIdentityKey,
        pinnedAt: DateTime.now(),
      ));
    } else if (!constantTimeEquals(
      pinned.identityKey,
      candidate.initiatorIdentityKey,
    )) {
      await _handleIdentityChange(
        peer: peer,
        pinned: pinned,
        presentedKey: candidate.initiatorIdentityKey,
        // The candidate replaces the session below; dropping state here
        // would only race with that.
        dropSession: false,
      );
    }

    _live[peer.key] = candidate.session;

    // Answering a handshake settles the session, so nothing stays pending: we
    // are the responder here, not the initiator.
    _pendingHandshake.remove(peer.key);
    await _persist(peer.key, candidate.session);

    // The one-time prekey is single use: destroying the private half is what
    // makes it contribute forward secrecy.
    final otp = candidate.oneTimePreKeyId;
    if (otp != null) await _keys.deleteOneTimePreKey(otp);
  }

  @override
  Future<bool> hasSession(PeerAddress peer) => _hasSession(peer);

  Future<bool> _hasSession(PeerAddress peer) async {
    if (_live.containsKey(peer.key)) return true;
    return await _sessions.loadSession(peer.key) != null;
  }

  @override
  Future<EncryptedPayload> encrypt(
    PeerAddress peer,
    List<int> plaintext,
  ) =>
      _serialized(peer.key, () async {
        final session = await _session(peer);
        final message = await session.encrypt(plaintext);
        await _persist(peer.key, session);

        final pending = _pendingHandshake[peer.key];
        if (pending != null) {
          return EncryptedPayload(
            cipherType: cipherTypePreKey,
            body: message.serialize(),
            initiatorIdentityKey: pending.identityKey,
            initiatorEphemeralKey: pending.ephemeralKey,
            oneTimePreKeyId: pending.oneTimePreKeyId,
            signedPreKeyId: pending.signedPreKeyId,
          );
        }

        return EncryptedPayload(
          cipherType: cipherTypeWhisper,
          body: message.serialize(),
        );
      });

  @override
  Future<Uint8List> decrypt(
    PeerAddress peer,
    EncryptedPayload payload,
  ) =>
      _serialized(peer.key, () => _decrypt(peer, payload));

  Future<Uint8List> _decrypt(PeerAddress peer, EncryptedPayload payload) async {
    final message = RatchetMessage.deserialize(payload.body);

    if (payload.isPreKeyMessage) {
      final identityKey = payload.initiatorIdentityKey;
      final ephemeralKey = payload.initiatorEphemeralKey;
      if (identityKey == null || ephemeralKey == null) {
        throw const FormatException(
          'prekey message is missing handshake material',
        );
      }

      // The initiator keeps attaching handshake material until it hears back,
      // so most prekey messages belong to the session we already have.
      // RatchetSession.decrypt is transactional, so trying it costs nothing
      // when it fails.
      if (await _hasSession(peer)) {
        final existing = await _session(peer);
        try {
          final plaintext = await existing.decrypt(message);
          await _afterDecrypt(peer, existing);
          return plaintext;
        } on RatchetException {
          // A genuinely new handshake: both people may have opened the chat
          // before either's first message arrived, or the peer reinstalled.
          // Decrypting it with our own session would fail every time, so the
          // message builds the session it describes instead.
        }
      }

      final candidate = await _buildInboundSession(
        initiatorIdentityKey: identityKey,
        initiatorEphemeralKey: ephemeralKey,
        oneTimePreKeyId: payload.oneTimePreKeyId,
        signedPreKeyId: payload.signedPreKeyId,
      );
      final plaintext = await candidate.session.decrypt(message);
      await _commitInboundSession(peer, candidate);
      return plaintext;
    }

    final session = await _session(peer);
    final plaintext = await session.decrypt(message);
    await _afterDecrypt(peer, session);
    return plaintext;
  }

  Future<void> _afterDecrypt(PeerAddress peer, RatchetSession session) async {
    // Hearing from the peer proves they completed the handshake, so the
    // material no longer needs to ride along. Dropped before persisting, or
    // the stored copy would outlive it and keep tagging messages as prekey
    // messages forever.
    _pendingHandshake.remove(peer.key);

    // Persist immediately: the chain has advanced and skipped keys may have
    // changed. Losing that would make later messages undecryptable.
    await _persist(peer.key, session);
  }

  @override
  Future<String> safetyNumberFor(PeerAddress peer, String localUserId) async {
    final identity = await _requireIdentity();
    final pinned = await _sessions.loadPinnedIdentity(peer.key);
    if (pinned == null) {
      throw StateError('no pinned identity for $peer');
    }

    return safetyNumber(
      localUserId: localUserId,
      localIdentityKey: identity.dhKeyPair.publicKey,
      remoteUserId: peer.userId,
      remoteIdentityKey: pinned.identityKey,
    );
  }

  @override
  Future<PinnedIdentity?> pinnedIdentityFor(PeerAddress peer) =>
      _sessions.loadPinnedIdentity(peer.key);

  @override
  Future<void> acceptIdentityChange(PeerAddress peer) =>
      _serialized(peer.key, () async {
        final pinned = await _sessions.loadPinnedIdentity(peer.key);
        if (pinned == null) return;

        await _sessions.savePinnedIdentity(PinnedIdentity(
          userId: pinned.userId,
          deviceId: pinned.deviceId,
          identityKey: pinned.identityKey,
          pinnedAt: pinned.pinnedAt,
          acceptedChange: true,
        ));

        // The old session is bound to the previous identity, so it cannot be
        // reused: drop it and let a fresh handshake run.
        _live.remove(peer.key);
        await _sessions.deleteSession(peer.key);
      });

  /// Applies the trust policy to a peer whose identity key no longer matches
  /// what we pinned.
  ///
  /// Under [TrustPolicy.notifyAndReestablish] the new key is pinned, the stale
  /// session is dropped so a fresh handshake runs, and the change is announced
  /// on [identityChanges]. Under [TrustPolicy.strict] nothing is written and
  /// the caller is expected to surface [IdentityChangedException] -- except
  /// when the user already accepted this peer's change, which is a standing
  /// decision that both policies honour.
  ///
  /// [dropSession] is false on the inbound path, where the caller is in the
  /// middle of building the replacement session from the message at hand.
  Future<void> _handleIdentityChange({
    required PeerAddress peer,
    required PinnedIdentity pinned,
    required Uint8List presentedKey,
    bool dropSession = true,
  }) async {
    final accepted = pinned.acceptedChange ||
        _trustPolicy == TrustPolicy.notifyAndReestablish;
    if (!accepted) throw IdentityChangedException(peer);

    await _sessions.savePinnedIdentity(PinnedIdentity(
      userId: peer.userId,
      deviceId: peer.deviceId,
      identityKey: presentedKey,
      pinnedAt: DateTime.now(),
      // Consumed: leaving it set would make the *next* change silent even in
      // strict mode, turning a one-off approval into permanent blanket trust.
      acceptedChange: false,
    ));

    if (dropSession) {
      // The old session's root key derives from the old identity, so no amount
      // of ratcheting recovers it.
      _live.remove(peer.key);
      _pendingHandshake.remove(peer.key);
      await _sessions.deleteSession(peer.key);
    }

    _identityChanges.add(IdentityChangeNotice(
      peer: peer,
      previousKey: pinned.identityKey,
      newKey: presentedKey,
    ));
  }

  /// Loads a session, keeping exactly one live instance per peer.
  Future<RatchetSession> _session(PeerAddress peer) async {
    final cached = _live[peer.key];
    if (cached != null) return cached;

    final stored = await _sessions.loadSession(peer.key);
    if (stored == null) {
      throw StateError('no session with $peer; establish one first');
    }

    final session = await RatchetSession.fromJson(stored);
    _live[peer.key] = session;

    // Restore the handshake material alongside the session. Without this an
    // app restart between establishing a session and hearing back from the
    // peer downgrades every later message to an ordinary ratchet message. The
    // peer has no session and no way to build one, so the conversation dies in
    // that direction only -- while their own messages still arrive, because
    // theirs still carry a handshake.
    final handshake = stored['pending_handshake'];
    if (handshake is Map<String, dynamic>) {
      _pendingHandshake[peer.key] = _PendingHandshake.fromJson(handshake);
    }

    return session;
  }

  /// Writes a session out, carrying any unacknowledged handshake with it.
  Future<void> _persist(String peerKey, RatchetSession session) async {
    final state = session.toJson();

    final pending = _pendingHandshake[peerKey];
    if (pending != null) {
      state['pending_handshake'] = pending.toJson();
    }

    await _sessions.saveSession(peerKey, state);
  }

  Future<IdentityKeys> _requireIdentity() async {
    final cached = _identity;
    if (cached != null) return cached;

    final loaded = await _keys.loadIdentity();
    if (loaded == null) {
      throw StateError('device identity not initialised');
    }
    _identity = loaded;
    return loaded;
  }

  Uint8List _serialize(Uint8List rawPublicKey) {
    final out = Uint8List(djbPublicKeyLength);
    out[0] = djbKeyType;
    out.setRange(1, djbPublicKeyLength, rawPublicKey);
    return out;
  }
}
