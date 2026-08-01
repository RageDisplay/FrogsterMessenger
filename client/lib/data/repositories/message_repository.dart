/// Coordinates encryption, transport and local storage for messages.
///
/// This is where plaintext meets ciphertext. Above this layer the app deals in
/// [Message] objects with readable bodies; below it, only opaque bytes leave
/// the device.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/crypto_engine.dart';
import '../local/dao/message_dao.dart';
import '../models/models.dart';
import '../remote/ws_client.dart';
import 'device_resolver.dart';

/// Emitted when a peer's identity key changes and the user must decide.
class IdentityChangeAlert {
  const IdentityChangeAlert({required this.peer, required this.chatId});

  final PeerAddress peer;
  final String chatId;
}

class MessageRepository {
  MessageRepository({
    required CryptoEngine crypto,
    required WsClient ws,
    required MessageDao dao,
    required DeviceResolver resolver,
    required Account account,
  })  : _crypto = crypto,
        _ws = ws,
        _dao = dao,
        _resolver = resolver,
        _account = account {
    _subscription = _ws.envelopes.listen(_onEnvelope);
  }

  final CryptoEngine _crypto;
  final WsClient _ws;
  final MessageDao _dao;
  final DeviceResolver _resolver;
  final Account _account;

  late final StreamSubscription<Envelope> _subscription;

  final _messages = StreamController<Message>.broadcast();
  final _chatUpdates = StreamController<String>.broadcast();
  final _identityAlerts = StreamController<IdentityChangeAlert>.broadcast();

  /// Messages that arrived or changed state, for the open chat to render.
  Stream<Message> get incoming => _messages.stream;

  /// Chat ids whose preview or unread count changed.
  Stream<String> get chatUpdates => _chatUpdates.stream;

  /// Peers whose identity key changed; the UI must block sending until the
  /// user accepts.
  Stream<IdentityChangeAlert> get identityAlerts => _identityAlerts.stream;

  /// Sends a message to a direct chat.
  ///
  /// The message is stored and shown immediately with [MessageStatus.pending],
  /// before the network is touched. Waiting for a round trip would make the UI
  /// feel broken on a slow link, and the local copy is the source of truth
  /// for history either way.
  Future<Message> sendDirect({
    required String chatId,
    required String peerUsername,
    required String body,
    String? replyToId,
    AttachmentPayload? attachment,
  }) async {
    final message = Message(
      id: _newId(),
      chatId: chatId,
      senderId: _account.userId,
      senderDeviceId: _account.deviceId,
      body: body,
      sentAt: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.pending,
      replyToId: replyToId,
      attachment: attachment,
    );

    await _dao.upsertMessage(message);
    await _dao.touchChat(chatId, _preview(body, attachment), message.sentAt);
    _messages.add(message);
    _chatUpdates.add(chatId);

    try {
      final payload = MessagePayload(
        body: body,
        replyToId: replyToId,
        attachment: attachment,
        sentAt: message.sentAt,
      );
      await _fanOut(
        chatId: chatId,
        peerUsername: peerUsername,
        payload: payload,
        messageId: message.id,
        timestamp: message.sentAt,
      );
      return message;
    } on IdentityChangedException {
      // Do not fall back to sending: that is exactly the case where a
      // malicious server would be substituting its own key.
      await _dao.updateStatus(message.id, MessageStatus.failed);
      _messages.add(message.copyWith(status: MessageStatus.failed));
      rethrow;
    } catch (_) {
      await _dao.updateStatus(message.id, MessageStatus.failed);
      _messages.add(message.copyWith(status: MessageStatus.failed));
      rethrow;
    }
  }

  /// Encrypts a payload separately for every recipient device and sends one
  /// envelope carrying all of them.
  ///
  /// One ciphertext per device is not an optimisation detail: each device has
  /// its own ratchet, so a shared ciphertext would be undecryptable for every
  /// device but one. The peer's other devices and our own both appear here,
  /// which is what keeps a multi-device account in sync.
  Future<void> _fanOut({
    required String chatId,
    required String peerUsername,
    required MessagePayload payload,
    required String messageId,
    required DateTime timestamp,
  }) async {
    final devices = await _resolver.devicesForDirectMessage(peerUsername);
    if (devices.isEmpty) {
      throw StateError('no devices to deliver to for $peerUsername');
    }

    final plaintext = payload.encode();
    final entries = <DevicePayloadWire>[];

    for (final device in devices) {
      try {
        final encrypted = await _crypto.encrypt(device.address, plaintext);
        entries.add(DevicePayloadWire(
          userId: device.address.userId,
          deviceId: device.address.deviceId,
          cipherType: encrypted.cipherType,
          ciphertext: base64Encode(_wireBody(encrypted)),
        ));
      } on IdentityChangedException {
        _identityAlerts.add(
          IdentityChangeAlert(peer: device.address, chatId: chatId),
        );
        rethrow;
      }
    }

    _ws.send(Envelope(
      type: EnvelopeType.message,
      id: messageId,
      chatId: chatId,
      payloads: entries,
      timestamp: timestamp.millisecondsSinceEpoch,
    ));
  }

  /// Sends an emoji reaction.
  ///
  /// Reactions travel inside the encrypted payload, so the server cannot learn
  /// who reacted to what.
  Future<void> sendReaction({
    required String chatId,
    required String peerUsername,
    required String targetId,
    required String emoji,
    bool remove = false,
  }) async {
    await _dao.applyReaction(
      targetId: targetId,
      emoji: emoji,
      userId: _account.userId,
      remove: remove,
    );

    // Shown locally first, then sent: a reaction that fails to deliver is a
    // far smaller loss than a UI that stalls on every tap.
    final updated = await _dao.messageById(targetId);
    if (updated != null) _messages.add(updated);

    await _fanOut(
      chatId: chatId,
      peerUsername: peerUsername,
      payload: MessagePayload(
        reaction: ReactionPayload(
          targetId: targetId,
          emoji: emoji,
          remove: remove,
        ),
      ),
      messageId: _newId(),
      timestamp: DateTime.now(),
    );
  }

  Future<List<Message>> history(String chatId) => _dao.messagesForChat(chatId);

  Future<void> markRead(String chatId) => _dao.clearUnread(chatId);

  /// Handles an inbound frame.
  Future<void> _onEnvelope(Envelope envelope) async {
    switch (envelope.type) {
      case EnvelopeType.message:
        await _onIncomingMessage(envelope);
      case EnvelopeType.ack:
        await _onAck(envelope);
      case EnvelopeType.keyChange:
        _onKeyChange(envelope);
    }
  }

  Future<void> _onIncomingMessage(Envelope envelope) async {
    final chatId = envelope.chatId;
    final senderId = envelope.senderUserId;
    final senderDeviceId = envelope.senderDeviceId;
    final ciphertext = envelope.ciphertext;

    if (chatId == null ||
        senderId == null ||
        senderDeviceId == null ||
        ciphertext == null) {
      return;
    }

    // A frame from this very device would be our own echo; there is nothing
    // to decrypt because we never encrypt to ourselves.
    if (senderDeviceId == _account.deviceId) return;

    // A message from another of *our* devices is one we sent elsewhere. It
    // must render on the right-hand side, not as if a stranger wrote it.
    final isOwnOtherDevice = senderId == _account.userId;

    final peer = PeerAddress(userId: senderId, deviceId: senderDeviceId);

    try {
      final payload = EncryptedPayload.fromJson(
        jsonDecode(utf8.decode(base64Decode(ciphertext)))
            as Map<String, dynamic>,
      );
      final plaintext = await _crypto.decrypt(peer, payload);
      final decoded = MessagePayload.decode(plaintext);

      if (decoded.isReaction) {
        final reaction = decoded.reaction!;
        await _dao.applyReaction(
          targetId: reaction.targetId,
          emoji: reaction.emoji,
          userId: senderId,
          remove: reaction.remove,
        );
        final target = await _dao.messageById(reaction.targetId);
        if (target != null) _messages.add(target);
        return;
      }

      final message = Message(
        id: envelope.id ?? _newId(),
        chatId: chatId,
        senderId: senderId,
        senderDeviceId: senderDeviceId,
        body: decoded.body,
        sentAt: decoded.sentAt ??
            DateTime.fromMillisecondsSinceEpoch(
              envelope.timestamp ?? DateTime.now().millisecondsSinceEpoch,
            ),
        isOutgoing: isOwnOtherDevice,
        seq: envelope.seq,
        status: MessageStatus.delivered,
        replyToId: decoded.replyToId,
        attachment: decoded.attachment,
      );

      await _dao.upsertMessage(message);
      // A message we sent from another device is already "read": counting it
      // as unread would show a badge for our own typing.
      await _dao.touchChat(
        chatId,
        _preview(decoded.body, decoded.attachment),
        message.sentAt,
        incrementUnread: !isOwnOtherDevice,
      );

      _messages.add(message);
      _chatUpdates.add(chatId);
    } catch (_) {
      // An undecryptable message is dropped rather than shown as corrupt
      // text. It usually means a session desync, which resolves when the peer
      // starts a new session.
    }
  }

  Future<void> _onAck(Envelope envelope) async {
    final id = envelope.id;
    if (id == null) return;

    await _dao.updateStatus(id, MessageStatus.sent, seq: envelope.seq);
    final updated = await _dao.messageById(id);
    if (updated != null) _messages.add(updated);
  }

  void _onKeyChange(Envelope envelope) {
    final userId = envelope.senderUserId;
    final deviceId = envelope.senderDeviceId;
    if (userId == null || deviceId == null) return;

    _identityAlerts.add(IdentityChangeAlert(
      peer: PeerAddress(userId: userId, deviceId: deviceId),
      chatId: envelope.chatId ?? '',
    ));
  }

  /// Serializes the payload for the wire.
  Uint8List _wireBody(EncryptedPayload payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));

  /// The chat-list preview line.
  ///
  /// An attachment with no caption would otherwise show an empty row, so it
  /// falls back to the file name or a generic label.
  String _preview(String body, AttachmentPayload? attachment) {
    if (body.isNotEmpty) return body;
    if (attachment == null) return '';
    return attachment.fileName ?? (attachment.isImage ? 'Photo' : 'File');
  }

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_account.deviceId.substring(0, 8)}';

  Future<void> dispose() async {
    await _subscription.cancel();
    await _messages.close();
    await _chatUpdates.close();
    await _identityAlerts.close();
  }
}
