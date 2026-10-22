/// Sender keys for secret groups: making ours, installing other members',
/// and deciding which epochs to trust.
library;

import 'dart:typed_data';

import '../../crypto/ratchet/sender_key.dart';
import '../local/dao/session_dao.dart';

/// No sender key is installed for the member device a group message came
/// from. Its distribution is usually still on the way; the message is kept
/// and retried when it arrives.
class MissingSenderKeyException implements Exception {
  const MissingSenderKeyException(this.chatId, this.epoch, this.senderDeviceId);

  final String chatId;
  final int epoch;
  final String senderDeviceId;

  @override
  String toString() =>
      'MissingSenderKeyException: no key from $senderDeviceId for $chatId@$epoch';
}

class GroupCipher {
  GroupCipher({required SenderKeyDao dao, required String selfDeviceId})
      : _dao = dao,
        _selfDeviceId = selfDeviceId;

  final SenderKeyDao _dao;
  final String _selfDeviceId;

  /// Our sender key for a chat epoch, created the first time it is needed.
  ///
  /// A fresh key per epoch is the whole point of epochs: the previous key is
  /// known to whoever has since left the group.
  Future<SenderKeyState> ownKey(String chatId, int epoch) async {
    final existing = await _dao.loadOwn(chatId: chatId, epoch: epoch);
    if (existing != null) return existing;
    final created = await createSenderKey(
      chatId: chatId,
      epoch: epoch,
      senderDeviceId: _selfDeviceId,
    );
    await _dao.save(created, isOwn: true);
    // Keys from before this epoch are only kept for messages still in
    // flight from the one just before it.
    await _dao.purgeStaleEpochs(chatId: chatId, currentEpoch: epoch - 1);
    return created;
  }

  /// The distribution message for our current key, to seal for each device
  /// that does not have it yet. It carries the chain as it stands now, so a
  /// device added later reads what follows, never what came before.
  Future<SenderKeyDistributionMessage> distribution(String chatId, int epoch) async =>
      buildDistributionMessage(await ownKey(chatId, epoch));

  /// Which of [deviceIds] have not been sent our key for this epoch.
  Future<List<String>> unshared(
    String chatId,
    int epoch,
    Iterable<String> deviceIds,
  ) async {
    final shared = await _dao.sharedWith(chatId: chatId, epoch: epoch);
    return deviceIds.where((d) => d != _selfDeviceId && !shared.contains(d)).toList();
  }

  Future<void> recordShares(String chatId, int epoch, Iterable<String> deviceIds) =>
      _dao.recordShares(chatId: chatId, epoch: epoch, deviceIds: deviceIds);

  /// Encrypts a group message under our key, advancing it.
  Future<Uint8List> encrypt(String chatId, int epoch, Uint8List plaintext) async {
    final state = await ownKey(chatId, epoch);
    final message = await encryptGroupMessage(state: state, plaintext: plaintext);
    await _dao.save(state, isOwn: true);
    return message.serialize();
  }

  /// Installs a member's sender key that arrived through our pairwise
  /// session with [fromDeviceId].
  ///
  /// The key must be for the chat it was addressed to and come from the
  /// device it claims to be: the pairwise session authenticates the device,
  /// and nothing else may stand in for another member's key -- a member who
  /// could install a key under someone else's device id could sign messages
  /// as them.
  Future<void> install(
    SenderKeyDistributionMessage skdm, {
    required String chatId,
    required String fromDeviceId,
  }) async {
    if (skdm.chatId != chatId) {
      throw SenderKeyException('sender key is for ${skdm.chatId}, arrived for $chatId');
    }
    if (skdm.senderDeviceId != fromDeviceId) {
      throw SenderKeyException(
        'sender key claims device ${skdm.senderDeviceId} but came from $fromDeviceId',
      );
    }
    if (fromDeviceId == _selfDeviceId) {
      throw const SenderKeyException('refusing to replace our own sender key');
    }
    await _dao.save(acceptDistributionMessage(skdm), isOwn: false);
  }

  /// Decrypts a group message.
  ///
  /// Accepted epochs are the chat's current one and the one just before it:
  /// a message sent moments before a membership change can arrive after it,
  /// and dropping it would lose it for good. Anything older is refused. A
  /// member removed two changes ago holds nothing usable, and a message
  /// claiming a future epoch is refused until the chat itself is known to
  /// have moved there.
  Future<Uint8List> decrypt({
    required String chatId,
    required int chatEpoch,
    required String senderDeviceId,
    required Uint8List serialized,
  }) async {
    final message = SenderKeyMessage.deserialize(serialized);
    if (message.chatId != chatId) {
      throw SenderKeyException('message is for ${message.chatId}, arrived for $chatId');
    }
    if (message.senderDeviceId != senderDeviceId) {
      throw SenderKeyException(
        'message claims device ${message.senderDeviceId} but came from $senderDeviceId',
      );
    }
    if (message.epoch > chatEpoch || message.epoch < chatEpoch - 1) {
      throw SenderKeyException(
        'message is for epoch ${message.epoch}; the chat is at $chatEpoch',
      );
    }

    final state = await _dao.load(
      chatId: chatId,
      epoch: message.epoch,
      deviceId: senderDeviceId,
    );
    if (state == null) {
      throw MissingSenderKeyException(chatId, message.epoch, senderDeviceId);
    }
    final plaintext = await decryptGroupMessage(
      state: state,
      message: message,
      currentEpoch: message.epoch,
    );
    await _dao.save(state, isOwn: false);
    return plaintext;
  }

  /// The epoch a serialized group message claims, read before decrypting
  /// so the caller can learn whether the chat moved on.
  static int epochOf(Uint8List serialized) =>
      SenderKeyMessage.deserialize(serialized).epoch;

  Future<void> forgetChat(String chatId) => _dao.deleteChat(chatId);
}
