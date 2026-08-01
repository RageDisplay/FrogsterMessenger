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

/// A message that arrived but could not be decrypted.
///
/// Surfaced rather than swallowed: an undecryptable message is invisible to
/// the user, and without a signal there is nothing to distinguish it from a
/// message that was never sent.
class DecryptFailure {
  const DecryptFailure({
    required this.peer,
    required this.chatId,
    required this.error,
    this.stackTrace,
  });

  final PeerAddress peer;
  final String chatId;
  final Object error;
  final StackTrace? stackTrace;
}

/// Emitted when a peer's identity key changes.
///
/// Under the default trust policy this is a notice: the session was rebuilt
/// automatically and the message went out, so [blocksSending] is false and the
/// UI should inform rather than obstruct. In strict mode the send failed and
/// the user has to verify the new safety number first.
class IdentityChangeAlert {
  const IdentityChangeAlert({
    required this.peer,
    required this.chatId,
    this.blocksSending = false,
  });

  final PeerAddress peer;
  final String chatId;
  final bool blocksSending;
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

    // Key changes the engine handled on its own still have to reach the user:
    // an automatic re-handshake is exactly what a key-substitution attack also
    // looks like, so it is reported even though nothing failed.
    _identityChangeSub = _crypto.identityChanges.listen((notice) {
      _identityAlerts.add(IdentityChangeAlert(
        peer: notice.peer,
        chatId: _lastChatForPeer[notice.peer.key] ?? '',
      ));
    });
  }

  final CryptoEngine _crypto;
  final WsClient _ws;
  final MessageDao _dao;
  final DeviceResolver _resolver;
  final Account _account;

  late final StreamSubscription<Envelope> _subscription;
  late final StreamSubscription<IdentityChangeNotice> _identityChangeSub;

  /// The chat each peer device was last seen in, so a key change reported by
  /// the engine can be attributed to a conversation. The engine deals in
  /// devices and knows nothing about chats.
  final Map<String, String> _lastChatForPeer = {};

  final _messages = StreamController<Message>.broadcast();
  final _chatUpdates = StreamController<String>.broadcast();
  final _identityAlerts = StreamController<IdentityChangeAlert>.broadcast();
  final _decryptFailures = StreamController<DecryptFailure>.broadcast();

  /// Messages that arrived or changed state, for the open chat to render.
  Stream<Message> get incoming => _messages.stream;

  /// Chat ids whose preview or unread count changed.
  Stream<String> get chatUpdates => _chatUpdates.stream;

  /// Peers whose identity key changed; the UI must block sending until the
  /// user accepts.
  Stream<IdentityChangeAlert> get identityAlerts => _identityAlerts.stream;

  /// Messages that arrived but could not be decrypted, so the UI can say so
  /// instead of showing an empty conversation.
  Stream<DecryptFailure> get decryptFailures => _decryptFailures.stream;

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
      _lastChatForPeer[device.address.key] = chatId;
      try {
        final encrypted = await _crypto.encrypt(device.address, plaintext);
        entries.add(DevicePayloadWire(
          userId: device.address.userId,
          deviceId: device.address.deviceId,
          cipherType: encrypted.cipherType,
          ciphertext: base64Encode(_wireBody(encrypted)),
        ));
      } on IdentityChangedException {
        // Only reachable in strict mode; the default policy rebuilds the
        // session instead and reports it on the engine's stream.
        _identityAlerts.add(IdentityChangeAlert(
          peer: device.address,
          chatId: chatId,
          blocksSending: true,
        ));
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
      case EnvelopeType.deviceAdded:
        _onDeviceAdded(envelope);
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

    // Drop a message we already hold, before touching the ratchet.
    //
    // A redelivery is not decryptable a second time: the message key was
    // destroyed when it first arrived, so attempting it raises a MAC failure
    // that looks identical to tampering. Checking the id first keeps a
    // duplicate harmless instead of letting it poison the session.
    final envelopeId = envelope.id;
    if (envelopeId != null && await _dao.messageById(envelopeId) != null) {
      return;
    }

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

      // The recipient may never have seen this chat: the sender created it on
      // their own device, and nothing tells us about it until a message
      // arrives. Without a chats() row the insert below fails its foreign key
      // and the message disappears -- which is exactly how "I write from the
      // phone and the PC shows nothing" happens.
      await _ensureChatExists(chatId, senderId, isOwnOtherDevice);

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
    } catch (error, stack) {
      // An undecryptable message is dropped rather than shown as corrupt
      // text. It usually means a session desync, which resolves when the peer
      // starts a new session.
      //
      // It is reported, though: silently swallowing this turns "my messages
      // never arrive" into a problem with no evidence anywhere, which is
      // exactly how it stayed hidden during the first round of manual
      // testing. Identifiers and the error only -- never the payload.
      _decryptFailures.add(DecryptFailure(
        peer: peer,
        chatId: chatId,
        error: error,
        stackTrace: stack,
      ));
      // ignore: avoid_print
      print('[frogster] decrypt failed from $senderId/$senderDeviceId '
          'in chat $chatId: $error');
    }
  }

  Future<void> _onAck(Envelope envelope) async {
    final id = envelope.id;
    if (id == null) return;

    await _dao.updateStatus(id, MessageStatus.sent, seq: envelope.seq);
    final updated = await _dao.messageById(id);
    if (updated != null) _messages.add(updated);
  }

  /// A contact registered a new device, or replaced an existing one.
  ///
  /// Dropping the cached device list is the load-bearing part. Without it we
  /// keep encrypting for the devices we resolved earlier, so a peer who wiped
  /// and signed back in never receives anything: the server reports
  /// "device not addressed by sender, skipping" and the message is simply
  /// never delivered, with no error on either side.
  void _onKeyChange(Envelope envelope) {
    final userId = envelope.senderUserId;
    final deviceId = envelope.senderDeviceId;
    if (userId == null || deviceId == null) return;

    final username = _resolver.usernameFor(userId);
    if (username != null) {
      _resolver.invalidate(username);
    } else {
      // The sender is not someone we have resolved by name yet, so we cannot
      // target the invalidation. Clearing everything is cheap next to silently
      // failing to deliver.
      _resolver.invalidateAll();
    }

    _identityAlerts.add(IdentityChangeAlert(
      peer: PeerAddress(userId: userId, deviceId: deviceId),
      chatId: envelope.chatId ?? '',
    ));
  }

  /// One of our *own* devices was added: a second desktop, a replaced phone.
  ///
  /// Our other devices have to be included in fan-out for messages to appear
  /// on all of them, so the self entry has to be refetched too.
  void _onDeviceAdded(Envelope envelope) {
    _resolver.invalidate(_account.username);
  }

  /// Serializes the payload for the wire.
  Uint8List _wireBody(EncryptedPayload payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));

  /// Creates the chat row if this device has not seen it before.
  ///
  /// A direct chat is named after the other participant. For a message from
  /// our own other device we cannot tell who that is from the envelope alone,
  /// so the name is filled in later, when the chat list refreshes from the
  /// server.
  Future<void> _ensureChatExists(
    String chatId,
    String senderId,
    bool isOwnOtherDevice,
  ) async {
    final existing = await _dao.chatById(chatId);
    if (existing != null) return;

    // The username may not be known yet: it is learned from a key bundle, and
    // the very first inbound message can arrive before we ever fetched one.
    // Resolve it now rather than leaving the chat nameless -- a chat with no
    // peer name falls back to showing its own id, and worse, sending into it
    // looks up keys for a user called "<uuid>", which cannot succeed.
    var peerUsername =
        isOwnOtherDevice ? null : _resolver.usernameFor(senderId);

    if (peerUsername == null && !isOwnOtherDevice) {
      peerUsername = await _resolver.lookupUsername(senderId);
    }

    await _dao.upsertChat(Chat(
      id: chatId,
      type: 'direct',
      epoch: 0,
      peerUsername: peerUsername,
    ));
  }

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
    await _identityChangeSub.cancel();
    await _messages.close();
    await _chatUpdates.close();
    await _identityAlerts.close();
    await _decryptFailures.close();
  }
}
