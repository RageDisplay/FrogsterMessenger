/// Group messaging via sender keys.
///
/// Encrypting a group message separately for every recipient device costs
/// O(N) public-key operations per message. Sender keys reduce that to one
/// symmetric encryption: each sender holds a chain, distributes it once to
/// every member over the existing pairwise sessions, and thereafter broadcasts
/// a single ciphertext that the server fans out unchanged.
///
/// The security consequence is that group membership changes must rotate keys.
/// A member who leaves keeps their copy of every sender key they received, so
/// without rotation they could decrypt group traffic forever. That rotation is
/// the single most dangerous thing to get wrong here, and it is enforced by
/// scoping every sender key to a chat epoch.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../primitives.dart';
import '../signing.dart';

/// Constants separating the message key from the next chain key.
///
/// As in the pairwise ratchet, these must differ: identical values would let
/// one leaked message key unlock the rest of the chain.
const int _senderChainMessageSeed = 0x01;
const int _senderChainNextSeed = 0x02;

/// Upper bound on keys derived to catch up with an out-of-order message.
const int senderKeyMaxSkip = 1000;

/// How many skipped message keys one sender key retains before evicting the
/// oldest. Bounds memory and storage no matter how many messages go missing.
const int senderKeyMaxSkippedStored = 2000;

/// A sender's key state for one (chat, epoch).
class SenderKeyState {
  SenderKeyState({
    required this.chatId,
    required this.epoch,
    required this.senderDeviceId,
    required this.signingPublicKey,
    required Uint8List chainKey,
    required this.iteration,
    this.signingSeed,
    Map<int, Uint8List>? skipped,
  })  : _chainKey = chainKey,
        _skipped = skipped ?? <int, Uint8List>{};

  final String chatId;
  final int epoch;
  final String senderDeviceId;

  /// Verifies messages from this sender within the group.
  ///
  /// Without a per-sender signature any member could forge messages from any
  /// other member, since they all share the same symmetric key.
  final Uint8List signingPublicKey;

  /// Present only for our own sender key: the half used to sign.
  final Uint8List? signingSeed;

  Uint8List _chainKey;
  int iteration;

  /// Message keys for iterations that were skipped over, so messages that
  /// arrive out of order still decrypt. Each is removed when used.
  final Map<int, Uint8List> _skipped;

  Uint8List get chainKey => _chainKey;

  /// Number of skipped keys retained, for tests and diagnostics.
  int get skippedKeyCount => _skipped.length;

  Map<String, dynamic> toJson() => {
        'chat_id': chatId,
        'epoch': epoch,
        'device_id': senderDeviceId,
        'sign_pub': base64Encode(signingPublicKey),
        if (signingSeed != null) 'sign_seed': base64Encode(signingSeed!),
        'chain_key': base64Encode(_chainKey),
        'iteration': iteration,
        if (_skipped.isNotEmpty)
          'skipped': {
            for (final e in _skipped.entries) '${e.key}': base64Encode(e.value),
          },
      };

  static SenderKeyState fromJson(Map<String, dynamic> json) => SenderKeyState(
        chatId: json['chat_id'] as String,
        epoch: json['epoch'] as int,
        senderDeviceId: json['device_id'] as String,
        signingPublicKey: base64Decode(json['sign_pub'] as String),
        signingSeed: json['sign_seed'] == null
            ? null
            : base64Decode(json['sign_seed'] as String),
        chainKey: base64Decode(json['chain_key'] as String),
        iteration: json['iteration'] as int,
        skipped: {
          for (final e in ((json['skipped'] as Map<String, dynamic>?) ??
                  const <String, dynamic>{})
              .entries)
            int.parse(e.key): base64Decode(e.value as String),
        },
      );
}

/// The message that distributes a sender key to one member device.
///
/// This travels inside the pairwise Double Ratchet session, so the server sees
/// only opaque bytes and never learns the group key.
class SenderKeyDistributionMessage {
  const SenderKeyDistributionMessage({
    required this.chatId,
    required this.epoch,
    required this.senderDeviceId,
    required this.chainKey,
    required this.iteration,
    required this.signingPublicKey,
  });

  final String chatId;
  final int epoch;
  final String senderDeviceId;
  final Uint8List chainKey;
  final int iteration;
  final Uint8List signingPublicKey;

  Uint8List serialize() => Uint8List.fromList(utf8.encode(jsonEncode({
        'chat_id': chatId,
        'epoch': epoch,
        'device_id': senderDeviceId,
        'chain_key': base64Encode(chainKey),
        'iteration': iteration,
        'sign_pub': base64Encode(signingPublicKey),
      })));

  static SenderKeyDistributionMessage deserialize(Uint8List raw) {
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return SenderKeyDistributionMessage(
      chatId: json['chat_id'] as String,
      epoch: json['epoch'] as int,
      senderDeviceId: json['device_id'] as String,
      chainKey: base64Decode(json['chain_key'] as String),
      iteration: json['iteration'] as int,
      signingPublicKey: base64Decode(json['sign_pub'] as String),
    );
  }
}

/// A group message: ciphertext plus the sender's signature.
class SenderKeyMessage {
  const SenderKeyMessage({
    required this.chatId,
    required this.epoch,
    required this.senderDeviceId,
    required this.iteration,
    required this.ciphertext,
    required this.signature,
  });

  final String chatId;
  final int epoch;
  final String senderDeviceId;
  final int iteration;
  final AeadCiphertext ciphertext;
  final Uint8List signature;

  /// The bytes covered by [signature] and authenticated as AEAD associated
  /// data, binding the message to its chat, epoch, sender and position.
  static Uint8List signedContent({
    required String chatId,
    required int epoch,
    required String senderDeviceId,
    required int iteration,
  }) =>
      Uint8List.fromList(utf8.encode(jsonEncode({
        'chat_id': chatId,
        'epoch': epoch,
        'device_id': senderDeviceId,
        'iteration': iteration,
      })));

  Uint8List get signedBytes => signedContent(
        chatId: chatId,
        epoch: epoch,
        senderDeviceId: senderDeviceId,
        iteration: iteration,
      );

  /// What the sender's signature covers: the metadata *and* the ciphertext.
  ///
  /// Signing the metadata alone would not bind the signature to the content.
  /// Every member holds the sender's chain key, so any member who sees a
  /// signed message could swap in a ciphertext of their own under the same
  /// signature -- and with the server's help deliver it as the sender's.
  static Uint8List signaturePayload(
    Uint8List metadata,
    AeadCiphertext ciphertext,
  ) {
    final ct = ciphertext.serialize();
    final out = Uint8List(metadata.length + ct.length);
    out.setRange(0, metadata.length, metadata);
    out.setRange(metadata.length, out.length, ct);
    return out;
  }

  Uint8List serialize() => Uint8List.fromList(utf8.encode(jsonEncode({
        'chat_id': chatId,
        'epoch': epoch,
        'device_id': senderDeviceId,
        'iteration': iteration,
        'ct': base64Encode(ciphertext.serialize()),
        'sig': base64Encode(signature),
      })));

  static SenderKeyMessage deserialize(Uint8List raw) {
    final json = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    return SenderKeyMessage(
      chatId: json['chat_id'] as String,
      epoch: json['epoch'] as int,
      senderDeviceId: json['device_id'] as String,
      iteration: json['iteration'] as int,
      ciphertext: AeadCiphertext.deserialize(base64Decode(json['ct'] as String)),
      signature: base64Decode(json['sig'] as String),
    );
  }
}

/// Raised when a group message cannot be processed.
class SenderKeyException implements Exception {
  const SenderKeyException(this.message);
  final String message;

  @override
  String toString() => 'SenderKeyException: $message';
}

/// Creates a fresh sender key for a chat epoch.
///
/// Called when first sending to a group, and again after every membership
/// change, because the previous key is known to whoever has since left.
Future<SenderKeyState> createSenderKey({
  required String chatId,
  required int epoch,
  required String senderDeviceId,
}) async {
  final signing = await generateSigningKeyPair();
  final chainKey = await hkdf(
    inputKeyMaterial: (await generateKeyPair()).privateKey,
    salt: Uint8List(32),
    info: 'Frogster_SenderKey_$chatId'.codeUnits,
  );

  return SenderKeyState(
    chatId: chatId,
    epoch: epoch,
    senderDeviceId: senderDeviceId,
    signingPublicKey: signing.publicKey,
    signingSeed: signing.seed,
    chainKey: chainKey,
    iteration: 0,
  );
}

/// Builds the distribution message for a sender key.
SenderKeyDistributionMessage buildDistributionMessage(SenderKeyState state) =>
    SenderKeyDistributionMessage(
      chatId: state.chatId,
      epoch: state.epoch,
      senderDeviceId: state.senderDeviceId,
      chainKey: state.chainKey,
      iteration: state.iteration,
      signingPublicKey: state.signingPublicKey,
    );

/// Installs a sender key received from another member.
SenderKeyState acceptDistributionMessage(SenderKeyDistributionMessage skdm) =>
    SenderKeyState(
      chatId: skdm.chatId,
      epoch: skdm.epoch,
      senderDeviceId: skdm.senderDeviceId,
      signingPublicKey: skdm.signingPublicKey,
      chainKey: skdm.chainKey,
      iteration: skdm.iteration,
    );

/// Encrypts a group message, advancing the sender's chain.
Future<SenderKeyMessage> encryptGroupMessage({
  required SenderKeyState state,
  required List<int> plaintext,
}) async {
  final seed = state.signingSeed;
  if (seed == null) {
    throw const SenderKeyException(
      'cannot send with a peer sender key; it has no signing seed',
    );
  }

  final step = await _advanceChain(state.chainKey);
  final iteration = state.iteration;

  state._chainKey = step.nextChainKey;
  state.iteration = iteration + 1;

  final aad = SenderKeyMessage.signedContent(
    chatId: state.chatId,
    epoch: state.epoch,
    senderDeviceId: state.senderDeviceId,
    iteration: iteration,
  );

  final ciphertext = await aeadEncrypt(
    key: step.messageKey,
    plaintext: plaintext,
    associatedData: aad,
  );
  wipe(step.messageKey);

  // Signed so other members cannot forge messages from this sender: they all
  // hold the same symmetric key, so AEAD alone proves only group membership.
  final signature = await sign(
    seed: seed,
    message: SenderKeyMessage.signaturePayload(aad, ciphertext),
  );

  return SenderKeyMessage(
    chatId: state.chatId,
    epoch: state.epoch,
    senderDeviceId: state.senderDeviceId,
    iteration: iteration,
    ciphertext: ciphertext,
    signature: signature,
  );
}

/// Decrypts a group message, skipping ahead if messages were missed.
///
/// Transactional: [state] changes only when the message authenticates, so a
/// corrupted or replayed frame cannot consume the key of a genuine one.
Future<Uint8List> decryptGroupMessage({
  required SenderKeyState state,
  required SenderKeyMessage message,
  required int currentEpoch,
}) async {
  // Refusing stale epochs is what makes removal effective: a member who left
  // holds only keys from an earlier epoch.
  if (message.epoch != currentEpoch) {
    throw SenderKeyException(
      'message is from epoch ${message.epoch} but the chat is at '
      '$currentEpoch; the sender key was rotated',
    );
  }
  if (message.epoch != state.epoch) {
    throw SenderKeyException(
      'sender key is for epoch ${state.epoch}, message is for ${message.epoch}',
    );
  }

  // Bounds are checked before the signature. Both orders reject the message,
  // but signature verification is the more expensive operation, and a
  // legitimate group member -- who can produce valid signatures -- could
  // otherwise force unbounded key derivation simply by claiming a huge
  // iteration. Cheap checks first.
  final late = message.iteration < state.iteration;
  if (late && !state._skipped.containsKey(message.iteration)) {
    // The chain only moves forward, and a skipped key is removed when used,
    // so this is either a replay or a message older than anything retained.
    throw SenderKeyException(
      'message iteration ${message.iteration} is behind the chain at '
      '${state.iteration}',
    );
  }
  if (message.iteration - state.iteration > senderKeyMaxSkip) {
    throw SenderKeyException(
      'message iteration ${message.iteration} is more than $senderKeyMaxSkip '
      'ahead of ${state.iteration}; refusing to derive that many keys',
    );
  }

  final signatureValid = await verifySignature(
    publicKey: state.signingPublicKey,
    message: SenderKeyMessage.signaturePayload(
      message.signedBytes,
      message.ciphertext,
    ),
    signature: message.signature,
  );
  if (!signatureValid) {
    throw const SenderKeyException(
      'signature does not verify; another member may be impersonating '
      'this sender',
    );
  }

  if (late) {
    final key = state._skipped[message.iteration]!;
    final plaintext = await _open(key, message);
    state._skipped.remove(message.iteration);
    wipe(key);
    return plaintext;
  }

  // Derive into locals; nothing is written to the state until the message
  // has authenticated.
  var chainKey = state.chainKey;
  final newlySkipped = <int, Uint8List>{};
  for (var i = state.iteration; i < message.iteration; i++) {
    final step = await _advanceChain(chainKey);
    newlySkipped[i] = step.messageKey;
    chainKey = step.nextChainKey;
  }
  final step = await _advanceChain(chainKey);

  final Uint8List plaintext;
  try {
    plaintext = await _open(step.messageKey, message);
  } catch (_) {
    newlySkipped.values.forEach(wipe);
    rethrow;
  } finally {
    wipe(step.messageKey);
  }

  state._chainKey = step.nextChainKey;
  state.iteration = message.iteration + 1;
  state._skipped.addAll(newlySkipped);
  while (state._skipped.length > senderKeyMaxSkippedStored) {
    final oldest = state._skipped.keys.first;
    wipe(state._skipped.remove(oldest)!);
  }
  return plaintext;
}

Future<Uint8List> _open(Uint8List messageKey, SenderKeyMessage message) async {
  try {
    return await aeadDecrypt(
      key: messageKey,
      ciphertext: message.ciphertext,
      associatedData: message.signedBytes,
    );
  } catch (e) {
    throw SenderKeyException('authentication failed: $e');
  }
}

/// One step of the sender chain.
///
/// Visible for testing: the separation between [messageKey] and
/// [nextChainKey] is what gives forward secrecy within a group, and collapsing
/// it does not break message delivery, so it must be asserted directly.
class SenderChainStep {
  const SenderChainStep({
    required this.messageKey,
    required this.nextChainKey,
  });
  final Uint8List messageKey;
  final Uint8List nextChainKey;
}

Future<SenderChainStep> _advanceChain(Uint8List chainKey) async {
  final messageKey = await hmacSha256(chainKey, [_senderChainMessageSeed]);
  final nextChainKey = await hmacSha256(chainKey, [_senderChainNextSeed]);
  return SenderChainStep(messageKey: messageKey, nextChainKey: nextChainKey);
}

/// Exposes the sender chain KDF so tests can verify its one-way property.
@visibleForTesting
Future<SenderChainStep> advanceSenderChainForTesting(Uint8List chainKey) =>
    _advanceChain(chainKey);
