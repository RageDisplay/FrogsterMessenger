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
  });

  final int cipherType;
  final Uint8List body;

  /// Set only on prekey messages.
  final Uint8List? initiatorIdentityKey;
  final Uint8List? initiatorEphemeralKey;
  final int? oneTimePreKeyId;

  bool get isPreKeyMessage => cipherType == cipherTypePreKey;

  Map<String, dynamic> toJson() => {
        'ct': cipherType,
        'body': base64Encode(body),
        if (initiatorIdentityKey != null)
          'ik': base64Encode(initiatorIdentityKey!),
        if (initiatorEphemeralKey != null)
          'ek': base64Encode(initiatorEphemeralKey!),
        if (oneTimePreKeyId != null) 'otp': oneTimePreKeyId,
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
      );
}

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
  });

  final Uint8List identityKey;
  final Uint8List ephemeralKey;
  final int? oneTimePreKeyId;

  Map<String, dynamic> toJson() => {
        'ik': base64Encode(identityKey),
        'ek': base64Encode(ephemeralKey),
        if (oneTimePreKeyId != null) 'otp': oneTimePreKeyId,
      };

  static _PendingHandshake fromJson(Map<String, dynamic> json) =>
      _PendingHandshake(
        identityKey: base64Decode(json['ik'] as String),
        ephemeralKey: base64Decode(json['ek'] as String),
        oneTimePreKeyId: json['otp'] as int?,
      );
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
      final pair = await generateKeyPair();
      final signature = await sign(
        seed: identity.signingKeyPair.seed,
        message: pair.publicKey,
      );
      spk = SignedPreKeyPair(keyId: 1, keyPair: pair, signature: signature);
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
    final out = <int, Uint8List>{};
    // Key ids are derived from a random base so that regenerating a pool does
    // not collide with ids the server still holds.
    final base = _random.nextInt(0xFFFF);

    for (var i = 0; i < count; i++) {
      final keyId = base + i + 1;
      final pair = await generateKeyPair();
      await _keys.saveOneTimePreKey(keyId, pair);
      out[keyId] = pair.serializedPublicKey;
    }
    return out;
  }

  @override
  Future<void> establishOutboundSession(
    PeerAddress peer,
    PreKeyBundle bundle,
  ) async {
    final identity = await _requireIdentity();

    // Trust on first use: pin the peer's identity, and decide what a change
    // means according to the configured policy.
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

    // x3dhInitiate verifies the signed prekey signature and throws if it does
    // not check out.
    final result = await x3dhInitiate(identity: identity, bundle: bundle);

    final session = await RatchetSession.initSender(
      sharedSecret: result.sharedSecret,
      receiverSignedPreKey: bundle.signedPreKey,
      associatedData: result.associatedData,
    );

    _live[peer.key] = session;

    // Held until the peer replies, because every message until then must carry
    // the material they need to complete their half of the handshake.
    _pendingHandshake[peer.key] = _PendingHandshake(
      identityKey: identity.dhKeyPair.publicKey,
      ephemeralKey: result.ephemeralPublicKey,
      oneTimePreKeyId: result.usedOneTimePreKeyId,
    );

    await _persist(peer.key, session);
  }

  @override
  Future<void> establishInboundSession({
    required PeerAddress peer,
    required Uint8List initiatorIdentityKey,
    required Uint8List initiatorEphemeralKey,
    int? oneTimePreKeyId,
  }) async {
    final identity = await _requireIdentity();

    final spk = await _keys.loadSignedPreKey();
    if (spk == null) {
      throw StateError('no signed prekey; identity not initialised');
    }

    // The one-time prekey the initiator consumed, if any. Its absence is
    // legitimate: the server's pool may have been empty.
    KeyPair? oneTime;
    if (oneTimePreKeyId != null) {
      oneTime = await _keys.loadOneTimePreKey(oneTimePreKeyId);
    }

    final result = await x3dhRespond(
      identity: identity,
      signedPreKeyPair: spk.keyPair,
      initiatorIdentityKey: initiatorIdentityKey,
      initiatorEphemeralKey: initiatorEphemeralKey,
      oneTimePreKeyPair: oneTime,
    );

    // Pin the initiator's identity on first contact, as the outbound path does.
    final pinned = await _sessions.loadPinnedIdentity(peer.key);
    if (pinned == null) {
      await _sessions.savePinnedIdentity(PinnedIdentity(
        userId: peer.userId,
        deviceId: peer.deviceId,
        identityKey: initiatorIdentityKey,
        pinnedAt: DateTime.now(),
      ));
    } else if (!constantTimeEquals(pinned.identityKey, initiatorIdentityKey)) {
      await _handleIdentityChange(
        peer: peer,
        pinned: pinned,
        presentedKey: initiatorIdentityKey,
        // The session is being built from this very message, so dropping
        // state here would discard the session we are about to install.
        dropSession: false,
      );
    }

    final session = await RatchetSession.initReceiver(
      sharedSecret: result.sharedSecret,
      signedPreKeyPair: spk.keyPair,
      associatedData: result.associatedData,
    );

    _live[peer.key] = session;

    // Answering a handshake settles the session, so nothing stays pending: we
    // are the responder here, not the initiator.
    _pendingHandshake.remove(peer.key);
    await _persist(peer.key, session);

    // The one-time prekey is single use: destroying the private half is what
    // makes it contribute forward secrecy.
    if (oneTimePreKeyId != null) {
      await _keys.deleteOneTimePreKey(oneTimePreKeyId);
    }
  }

  @override
  Future<bool> hasSession(PeerAddress peer) async {
    if (_live.containsKey(peer.key)) return true;
    return await _sessions.loadSession(peer.key) != null;
  }

  @override
  Future<EncryptedPayload> encrypt(
    PeerAddress peer,
    List<int> plaintext,
  ) async {
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
      );
    }

    return EncryptedPayload(
      cipherType: cipherTypeWhisper,
      body: message.serialize(),
    );
  }

  @override
  Future<Uint8List> decrypt(
    PeerAddress peer,
    EncryptedPayload payload,
  ) async {
    // A prekey message always builds the session it describes, even when one
    // already exists.
    //
    // Both people can open a conversation before either's first message
    // arrives -- each taps "new chat", each runs establishOutboundSession, and
    // now two unrelated sessions exist for the same pair. Skipping the
    // handshake because "a session is already there" would decrypt the peer's
    // prekey message with our own outbound session, whose keys are different,
    // and every message would fail its MAC check with nothing to indicate why.
    //
    // A prekey message is self-contained by design: it carries the identity
    // and ephemeral keys needed to derive the session from scratch, so acting
    // on it is always safe.
    if (payload.isPreKeyMessage) {
      final identityKey = payload.initiatorIdentityKey;
      final ephemeralKey = payload.initiatorEphemeralKey;
      if (identityKey == null || ephemeralKey == null) {
        throw const FormatException(
          'prekey message is missing handshake material',
        );
      }

      // Rebuilding on every prekey message would reset the ratchet mid-
      // conversation, because the initiator keeps attaching the material until
      // they hear back. Only build when we cannot already decrypt.
      final needsSession = !await hasSession(peer) ||
          !await _canDecryptWithExistingSession(peer, payload);

      if (needsSession) {
        await establishInboundSession(
          peer: peer,
          initiatorIdentityKey: identityKey,
          initiatorEphemeralKey: ephemeralKey,
          oneTimePreKeyId: payload.oneTimePreKeyId,
        );
      }
    }

    final session = await _session(peer);
    final message = RatchetMessage.deserialize(payload.body);
    final plaintext = await session.decrypt(message);

    // Hearing from the peer proves they completed the handshake, so the
    // material no longer needs to ride along. Dropped before persisting, or
    // the stored copy would outlive it and keep tagging messages as prekey
    // messages forever.
    _pendingHandshake.remove(peer.key);

    // Persist immediately: the chain has advanced and skipped keys may have
    // changed. Losing that would make later messages undecryptable.
    await _persist(peer.key, session);

    return plaintext;
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
  Future<void> acceptIdentityChange(PeerAddress peer) async {
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
  }

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

  /// Reports whether the session we already hold can decrypt this payload.
  ///
  /// The attempt runs against a throwaway copy of the session state. A real
  /// decrypt advances the ratchet and consumes skipped keys, so trying on the
  /// live session and failing would corrupt it -- the peer's next message
  /// would then fail too, turning a recoverable mismatch into a broken
  /// conversation.
  Future<bool> _canDecryptWithExistingSession(
    PeerAddress peer,
    EncryptedPayload payload,
  ) async {
    final stored = await _sessions.loadSession(peer.key);
    if (stored == null) return false;

    try {
      final probe = await RatchetSession.fromJson(stored);
      await probe.decrypt(RatchetMessage.deserialize(payload.body));
      return true;
    } catch (_) {
      return false;
    }
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
