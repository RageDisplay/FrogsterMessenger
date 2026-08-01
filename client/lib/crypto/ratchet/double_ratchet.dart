/// The Double Ratchet algorithm.
///
/// Implements https://signal.org/docs/specifications/doubleratchet/ over the
/// primitives in `primitives.dart`.
///
/// Two ratchets combine to give forward secrecy and post-compromise security:
///
///   * the **symmetric ratchet** advances a chain key once per message, so
///     every message gets a unique key that is destroyed after use. An
///     attacker who steals current state cannot read earlier messages.
///   * the **DH ratchet** performs a new Diffie-Hellman whenever the
///     conversation changes direction, mixing fresh entropy into the root key.
///     An attacker who steals state loses access once the next DH step runs.
///
/// This is the highest-risk code in the project: a mistake here does not
/// crash, it silently weakens or removes forward secrecy while tests continue
/// to pass. The invariants that matter are asserted in
/// test/crypto/double_ratchet_test.dart.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../primitives.dart';

/// Domain separation for the root KDF.
const String _rootInfo = 'Frogster_Ratchet_Root';

/// Constants fed to the chain KDF. Distinct values keep the message key and
/// the next chain key independent: deriving both from the same input would let
/// anyone holding a message key compute the rest of the chain.
const int _chainKeyMessageSeed = 0x01;
const int _chainKeyNextSeed = 0x02;

/// Upper bound on message keys retained for out-of-order delivery.
///
/// Without a cap, a peer claiming a huge message number would force unbounded
/// key derivation and storage -- a denial-of-service vector. 1000 matches
/// Signal and comfortably covers real reordering.
const int maxSkip = 1000;

/// How many skipped keys a session retains overall before evicting the oldest.
const int maxSkippedKeysStored = 2000;

/// Header sent in clear alongside each ciphertext.
///
/// The header is not secret, but it is authenticated: it is passed as AEAD
/// associated data, so an attacker cannot move a body onto a different header.
class MessageHeader {
  const MessageHeader({
    required this.ratchetPublicKey,
    required this.previousChainLength,
    required this.messageNumber,
  });

  /// The sender's current DH ratchet public key.
  final Uint8List ratchetPublicKey;

  /// Number of messages in the sender's previous sending chain, so the
  /// receiver knows how many keys to skip when the direction changed.
  final int previousChainLength;

  /// Index of this message within the current sending chain.
  final int messageNumber;

  Map<String, dynamic> toJson() => {
        'dh': base64Encode(ratchetPublicKey),
        'pn': previousChainLength,
        'n': messageNumber,
      };

  static MessageHeader fromJson(Map<String, dynamic> json) => MessageHeader(
        ratchetPublicKey: base64Decode(json['dh'] as String),
        previousChainLength: json['pn'] as int,
        messageNumber: json['n'] as int,
      );

  /// Canonical bytes used as AEAD associated data.
  Uint8List serialize() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));
}

/// A ratchet message: header plus AEAD ciphertext.
class RatchetMessage {
  const RatchetMessage({required this.header, required this.ciphertext});

  final MessageHeader header;
  final AeadCiphertext ciphertext;

  Uint8List serialize() {
    final payload = {
      'h': header.toJson(),
      'c': base64Encode(ciphertext.serialize()),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(payload)));
  }

  static RatchetMessage deserialize(Uint8List raw) {
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return RatchetMessage(
      header: MessageHeader.fromJson(json['h'] as Map<String, dynamic>),
      ciphertext: AeadCiphertext.deserialize(base64Decode(json['c'] as String)),
    );
  }
}

/// Raised when a message cannot be decrypted.
class RatchetException implements Exception {
  const RatchetException(this.message);
  final String message;

  @override
  String toString() => 'RatchetException: $message';
}

/// Identifies a skipped message key by the chain it belongs to.
class _SkippedKeyId {
  const _SkippedKeyId(this.ratchetKey, this.messageNumber);

  final String ratchetKey; // base64 of the sender's ratchet public key
  final int messageNumber;

  @override
  bool operator ==(Object other) =>
      other is _SkippedKeyId &&
      other.ratchetKey == ratchetKey &&
      other.messageNumber == messageNumber;

  @override
  int get hashCode => Object.hash(ratchetKey, messageNumber);
}

/// Double Ratchet session state for one peer device.
///
/// Instances are mutable and must not be shared across isolates: two
/// concurrent [encrypt] calls would derive the same message key twice, reusing
/// an AEAD key and breaking confidentiality.
class RatchetSession {
  RatchetSession._({
    required Uint8List rootKey,
    required this.associatedData,
    KeyPair? sendingRatchetKeyPair,
    Uint8List? receivingRatchetKey,
    Uint8List? sendingChainKey,
    Uint8List? receivingChainKey,
    int sendCount = 0,
    int receiveCount = 0,
    int previousSendCount = 0,
    Map<_SkippedKeyId, Uint8List>? skipped,
  }) : _rootKey = rootKey,
       _sendingRatchetKeyPair = sendingRatchetKeyPair,
       _receivingRatchetKey = receivingRatchetKey,
       _sendingChainKey = sendingChainKey,
       _receivingChainKey = receivingChainKey,
       _sendCount = sendCount,
       _receiveCount = receiveCount,
       _previousSendCount = previousSendCount,
       _skipped = skipped ?? <_SkippedKeyId, Uint8List>{};

  /// IK_A || IK_B from X3DH, authenticated with every message so a transcript
  /// cannot be replayed against a different pair of identities.
  final Uint8List associatedData;

  Uint8List _rootKey;
  KeyPair? _sendingRatchetKeyPair;
  Uint8List? _receivingRatchetKey;
  Uint8List? _sendingChainKey;
  Uint8List? _receivingChainKey;
  int _sendCount;
  int _receiveCount;
  int _previousSendCount;
  final Map<_SkippedKeyId, Uint8List> _skipped;

  /// Initialises the session for the party that sent the first message.
  ///
  /// Alice knows Bob's signed prekey up front, so she can perform the first DH
  /// ratchet step immediately and start sending without waiting for a reply.
  static Future<RatchetSession> initSender({
    required Uint8List sharedSecret,
    required Uint8List receiverSignedPreKey,
    required Uint8List associatedData,
  }) async {
    final sendingKeyPair = await generateKeyPair();
    final dh = await diffieHellman(
      privateKey: sendingKeyPair.privateKey,
      peerPublicKey: receiverSignedPreKey,
    );
    final derived = await _kdfRootKey(sharedSecret, dh);
    wipe(dh);

    return RatchetSession._(
      rootKey: derived.rootKey,
      associatedData: associatedData,
      sendingRatchetKeyPair: sendingKeyPair,
      receivingRatchetKey: receiverSignedPreKey,
      sendingChainKey: derived.chainKey,
    );
  }

  /// Initialises the session for the party that receives the first message.
  ///
  /// Bob starts with no sending chain: it is created on the first DH ratchet
  /// step, which happens when he processes Alice's first message.
  static Future<RatchetSession> initReceiver({
    required Uint8List sharedSecret,
    required KeyPair signedPreKeyPair,
    required Uint8List associatedData,
  }) async {
    return RatchetSession._(
      rootKey: sharedSecret,
      associatedData: associatedData,
      sendingRatchetKeyPair: signedPreKeyPair,
    );
  }

  /// Encrypts a message, advancing the symmetric ratchet by one step.
  Future<RatchetMessage> encrypt(List<int> plaintext) async {
    final chainKey = _sendingChainKey;
    if (chainKey == null) {
      throw const RatchetException(
        'no sending chain; receive a message before sending',
      );
    }

    final step = await _kdfChainKey(chainKey);
    _sendingChainKey = step.nextChainKey;

    final header = MessageHeader(
      ratchetPublicKey: _sendingRatchetKeyPair!.publicKey,
      previousChainLength: _previousSendCount,
      messageNumber: _sendCount,
    );
    _sendCount++;

    // The header and the X3DH associated data are both authenticated, binding
    // the ciphertext to this session and this position in the chain.
    final aad = _aad(header);
    final ciphertext = await aeadEncrypt(
      key: step.messageKey,
      plaintext: plaintext,
      associatedData: aad,
    );

    // The message key is used exactly once and destroyed. This is what makes
    // past messages unrecoverable from current state.
    wipe(step.messageKey);

    return RatchetMessage(header: header, ciphertext: ciphertext);
  }

  /// Decrypts a message, handling out-of-order and skipped messages.
  Future<Uint8List> decrypt(RatchetMessage message) async {
    // A key stashed earlier for a message that arrived late.
    final stashed = _takeSkipped(message.header);
    if (stashed != null) {
      final plaintext = await _decryptWith(stashed, message);
      wipe(stashed);
      return plaintext;
    }

    final isNewChain = _receivingRatchetKey == null ||
        !constantTimeEquals(_receivingRatchetKey!, message.header.ratchetPublicKey);

    if (isNewChain) {
      // The peer moved to a new ratchet key: stash keys for anything still
      // missing from the old chain, then perform a DH ratchet step.
      await _skipMessageKeys(message.header.previousChainLength);
      await _dhRatchet(message.header);
    }

    await _skipMessageKeys(message.header.messageNumber);

    final chainKey = _receivingChainKey;
    if (chainKey == null) {
      throw const RatchetException('no receiving chain for this message');
    }

    final step = await _kdfChainKey(chainKey);
    _receivingChainKey = step.nextChainKey;
    _receiveCount++;

    final plaintext = await _decryptWith(step.messageKey, message);
    wipe(step.messageKey);
    return plaintext;
  }

  Future<Uint8List> _decryptWith(
    Uint8List messageKey,
    RatchetMessage message,
  ) async {
    try {
      return await aeadDecrypt(
        key: messageKey,
        ciphertext: message.ciphertext,
        associatedData: _aad(message.header),
      );
    } catch (e) {
      throw RatchetException('authentication failed: $e');
    }
  }

  /// Derives and stores message keys for messages we have not seen yet, so
  /// they remain decryptable when they arrive later.
  Future<void> _skipMessageKeys(int until) async {
    final chainKey = _receivingChainKey;
    if (chainKey == null) return;

    if (until - _receiveCount > maxSkip) {
      // Refuse to derive an unbounded number of keys on a peer's say-so.
      throw RatchetException(
        'peer claims message $until but we are at $_receiveCount; '
        'refusing to skip more than $maxSkip keys',
      );
    }

    final ratchetKey = base64Encode(_receivingRatchetKey!);
    var key = chainKey;

    while (_receiveCount < until) {
      final step = await _kdfChainKey(key);
      _skipped[_SkippedKeyId(ratchetKey, _receiveCount)] = step.messageKey;
      key = step.nextChainKey;
      _receiveCount++;
      _evictOldestSkippedIfNeeded();
    }
    _receivingChainKey = key;
  }

  /// Removes and returns a previously stashed key, if one matches.
  Uint8List? _takeSkipped(MessageHeader header) {
    final id = _SkippedKeyId(
      base64Encode(header.ratchetPublicKey),
      header.messageNumber,
    );
    return _skipped.remove(id);
  }

  /// Performs a DH ratchet step: two root-key derivations that install a new
  /// receiving chain and a new sending chain.
  Future<void> _dhRatchet(MessageHeader header) async {
    _previousSendCount = _sendCount;
    _sendCount = 0;
    _receiveCount = 0;
    _receivingRatchetKey = Uint8List.fromList(header.ratchetPublicKey);

    // Receiving chain, from our current key against their new key.
    final dhRecv = await diffieHellman(
      privateKey: _sendingRatchetKeyPair!.privateKey,
      peerPublicKey: _receivingRatchetKey!,
    );
    final recvDerived = await _kdfRootKey(_rootKey, dhRecv);
    wipe(dhRecv);
    _rootKey = recvDerived.rootKey;
    _receivingChainKey = recvDerived.chainKey;

    // Sending chain, from a fresh key pair against their new key. Generating a
    // new pair here is what injects forward entropy and gives post-compromise
    // security.
    _sendingRatchetKeyPair = await generateKeyPair();
    final dhSend = await diffieHellman(
      privateKey: _sendingRatchetKeyPair!.privateKey,
      peerPublicKey: _receivingRatchetKey!,
    );
    final sendDerived = await _kdfRootKey(_rootKey, dhSend);
    wipe(dhSend);
    _rootKey = sendDerived.rootKey;
    _sendingChainKey = sendDerived.chainKey;
  }

  void _evictOldestSkippedIfNeeded() {
    while (_skipped.length > maxSkippedKeysStored) {
      final oldest = _skipped.keys.first;
      final key = _skipped.remove(oldest);
      if (key != null) wipe(key);
    }
  }

  Uint8List _aad(MessageHeader header) {
    final headerBytes = header.serialize();
    final out = Uint8List(associatedData.length + headerBytes.length);
    out.setRange(0, associatedData.length, associatedData);
    out.setRange(associatedData.length, out.length, headerBytes);
    return out;
  }

  /// Number of skipped keys currently retained, for tests and diagnostics.
  int get skippedKeyCount => _skipped.length;

  /// Serializes the session so it survives an app restart.
  ///
  /// The result contains live key material and must only ever be written to
  /// encrypted storage.
  Map<String, dynamic> toJson() => {
        'rk': base64Encode(_rootKey),
        'ad': base64Encode(associatedData),
        'sk_priv': _sendingRatchetKeyPair == null
            ? null
            : base64Encode(_sendingRatchetKeyPair!.privateKey),
        'rk_pub':
            _receivingRatchetKey == null ? null : base64Encode(_receivingRatchetKey!),
        'ck_s': _sendingChainKey == null ? null : base64Encode(_sendingChainKey!),
        'ck_r':
            _receivingChainKey == null ? null : base64Encode(_receivingChainKey!),
        'ns': _sendCount,
        'nr': _receiveCount,
        'pn': _previousSendCount,
        'skipped': _skipped.entries
            .map((e) => {
                  'dh': e.key.ratchetKey,
                  'n': e.key.messageNumber,
                  'mk': base64Encode(e.value),
                })
            .toList(),
      };

  /// Restores a session previously written by [toJson].
  static Future<RatchetSession> fromJson(Map<String, dynamic> json) async {
    final skipped = <_SkippedKeyId, Uint8List>{};
    for (final entry in (json['skipped'] as List<dynamic>? ?? const [])) {
      final map = entry as Map<String, dynamic>;
      skipped[_SkippedKeyId(map['dh'] as String, map['n'] as int)] =
          base64Decode(map['mk'] as String);
    }

    final privateKey = json['sk_priv'] as String?;
    return RatchetSession._(
      rootKey: base64Decode(json['rk'] as String),
      associatedData: base64Decode(json['ad'] as String),
      sendingRatchetKeyPair: privateKey == null
          ? null
          : await keyPairFromPrivateKey(base64Decode(privateKey)),
      receivingRatchetKey: json['rk_pub'] == null
          ? null
          : base64Decode(json['rk_pub'] as String),
      sendingChainKey:
          json['ck_s'] == null ? null : base64Decode(json['ck_s'] as String),
      receivingChainKey:
          json['ck_r'] == null ? null : base64Decode(json['ck_r'] as String),
      sendCount: json['ns'] as int,
      receiveCount: json['nr'] as int,
      previousSendCount: json['pn'] as int,
      skipped: skipped,
    );
  }
}

/// Output of the root KDF.
class _RootKdfResult {
  const _RootKdfResult({required this.rootKey, required this.chainKey});
  final Uint8List rootKey;
  final Uint8List chainKey;
}

/// Derives a new root key and chain key from the old root key and a DH output.
Future<_RootKdfResult> _kdfRootKey(Uint8List rootKey, Uint8List dhOutput) async {
  final derived = await hkdf(
    inputKeyMaterial: dhOutput,
    salt: rootKey,
    info: _rootInfo.codeUnits,
    outputLength: 64,
  );
  return _RootKdfResult(
    rootKey: Uint8List.sublistView(derived, 0, 32),
    chainKey: Uint8List.sublistView(derived, 32, 64),
  );
}

/// Output of one symmetric ratchet step.
///
/// Visible for testing: the separation between [messageKey] and
/// [nextChainKey] is the basis of forward secrecy, and an error there does not
/// break message delivery, so it must be asserted directly rather than
/// inferred from a working exchange.
class ChainKdfResult {
  const ChainKdfResult({required this.messageKey, required this.nextChainKey});
  final Uint8List messageKey;
  final Uint8List nextChainKey;
}

/// Advances the chain by one step.
///
/// The message key and the next chain key are separate HMAC outputs under
/// different constants, so learning a message key reveals nothing about the
/// rest of the chain. If both were derived with the same constant, an attacker
/// who recovered one message key could compute every later key in the chain --
/// and messages would still encrypt and decrypt normally, so no functional
/// test would notice. See kdfChainKeyForTesting.
Future<ChainKdfResult> _kdfChainKey(Uint8List chainKey) async {
  final messageKey = await hmacSha256(chainKey, [_chainKeyMessageSeed]);
  final nextChainKey = await hmacSha256(chainKey, [_chainKeyNextSeed]);
  return ChainKdfResult(messageKey: messageKey, nextChainKey: nextChainKey);
}

/// Exposes the chain KDF so tests can verify its one-way property.
@visibleForTesting
Future<ChainKdfResult> kdfChainKeyForTesting(Uint8List chainKey) =>
    _kdfChainKey(chainKey);
