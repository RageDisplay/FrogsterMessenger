/// Coordinates encryption, transport and local storage for messages.
///
/// This is where plaintext meets ciphertext. Above this layer the app deals in
/// [Message] objects with readable bodies; below it, only what each chat's
/// mode allows leaves the device:
///
/// * a **cloud** chat sends its payload to the server, which keeps it sealed
///   at rest and serves it as history to every device;
/// * a **secret direct** chat encrypts the payload once per recipient device
///   with the pairwise Double Ratchet;
/// * a **secret group** encrypts it once under this device's sender key,
///   distributed to every member device over the pairwise sessions.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../crypto/crypto_engine.dart';
import '../../crypto/ratchet/sender_key.dart';
import '../local/dao/message_dao.dart';
import '../models/models.dart';
import '../remote/api_client.dart';
import '../remote/ws_client.dart';
import 'device_resolver.dart';
import 'group_cipher.dart';

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

/// Other members read up to [seq] in a chat.
class ReadUpdate {
  const ReadUpdate(this.chatId, this.seq);

  final String chatId;
  final int seq;
}

/// Someone is typing in a chat.
class TypingNotice {
  const TypingNotice(this.chatId, this.userId);

  final String chatId;
  final String userId;
}

/// Uploads one file, reporting progress from 0 to 1, and returns the
/// reference to send.
typedef FileUpload = Future<AttachmentPayload> Function(void Function(double fraction) onProgress);

/// A file being sent has gone [fraction] of the way up.
class UploadProgress {
  const UploadProgress(this.messageId, this.fraction);

  final String messageId;
  final double fraction;
}

/// Placeholders the chat list shows for messages without text, rendered in
/// the user's language by the UI.
class PreviewTokens {
  static const photo = '\u0000photo';
  static const file = '\u0000file';
  static const voice = '\u0000voice';
}

class MessageRepository {
  MessageRepository({
    required CryptoEngine crypto,
    required WsClient ws,
    required MessageDao dao,
    required OutboxDao outbox,
    required GroupCipher groups,
    required DeviceResolver resolver,
    required ApiClient api,
    required Account account,
  }) : _crypto = crypto,
       _ws = ws,
       _dao = dao,
       _outbox = outbox,
       _groups = groups,
       _resolver = resolver,
       _api = api,
       _account = account {
    // Frames are handled strictly one at a time, in arrival order. An async
    // listener alone would start the next frame at the first await: an
    // offline flush delivering a burst would then interleave the dedup check
    // and the database writes of several messages, and ordering-sensitive
    // frames (a sender key and the message after it, a message and its ack)
    // would race.
    _subscription = _ws.envelopes
        .asyncMap(
          (envelope) => _onEnvelope(envelope).catchError(
            // ignore: avoid_print
            (Object e) => print('[frogster] dropping frame: $e'),
          ),
        )
        .listen((_) {});

    // A fresh connection replays what never got an answer, then catches up
    // on what happened while away.
    // A new repository has no uploads running; any left pending were cut
    // off when the app last closed.
    unawaited(_dao.failInterruptedUploads());

    _connectionSub = _ws.connectionState.listen((state) {
      if (state == SocketState.connected) unawaited(_onConnected());
    });

    // Key changes the engine handled on its own still have to reach the user:
    // an automatic re-handshake is exactly what a key-substitution attack also
    // looks like, so it is reported even though nothing failed.
    _identityChangeSub = _crypto.identityChanges.listen((notice) {
      _identityAlerts.add(
        IdentityChangeAlert(
          peer: notice.peer,
          chatId: _lastChatForPeer[notice.peer.key] ?? '',
        ),
      );
    });
  }

  final CryptoEngine _crypto;
  final WsClient _ws;
  final MessageDao _dao;
  final OutboxDao _outbox;
  final GroupCipher _groups;
  final DeviceResolver _resolver;
  final ApiClient _api;
  final Account _account;

  late final StreamSubscription<void> _subscription;
  late final StreamSubscription<SocketState> _connectionSub;
  late final StreamSubscription<IdentityChangeNotice> _identityChangeSub;

  /// The chat each peer device was last seen in, so a key change reported by
  /// the engine can be attributed to a conversation. The engine deals in
  /// devices and knows nothing about chats.
  final Map<String, String> _lastChatForPeer = {};

  final _messages = StreamController<Message>.broadcast();
  final _removed = StreamController<Message>.broadcast();
  final _chatUpdates = StreamController<String>.broadcast();
  final _reads = StreamController<ReadUpdate>.broadcast();
  final _typing = StreamController<TypingNotice>.broadcast();
  final _arrivals = StreamController<Message>.broadcast();
  final _identityAlerts = StreamController<IdentityChangeAlert>.broadcast();
  final _decryptFailures = StreamController<DecryptFailure>.broadcast();

  /// Messages that arrived or changed state, for the open chat to render.
  Stream<Message> get incoming => _messages.stream;

  /// Messages deleted for everyone.
  Stream<Message> get removed => _removed.stream;

  /// Chat ids whose preview, unread count or metadata changed.
  Stream<String> get chatUpdates => _chatUpdates.stream;

  /// Other members read further.
  Stream<ReadUpdate> get reads => _reads.stream;

  /// Messages from others that just arrived, as they arrive: what
  /// notifications are made of. History fetched in a sync is not here.
  Stream<Message> get arrivals => _arrivals.stream;

  /// Someone started or kept typing. Each notice holds for a few seconds.
  Stream<TypingNotice> get typing => _typing.stream;

  /// Peers whose identity key changed.
  Stream<IdentityChangeAlert> get identityAlerts => _identityAlerts.stream;

  /// Messages that arrived but could not be decrypted, so the UI can say so
  /// instead of showing an empty conversation.
  Stream<DecryptFailure> get decryptFailures => _decryptFailures.stream;

  // ---------------------------------------------------------------- sending

  /// Sends a message.
  ///
  /// The message is stored and shown immediately with [MessageStatus.pending],
  /// before the network is touched. Waiting for a round trip would make the UI
  /// feel broken on a slow link, and the local copy is the source of truth
  /// for history either way.
  Future<Message> send({
    required String chatId,
    required String body,
    String? replyToId,
    AttachmentPayload? attachment,
    String? forwardedFrom,
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
      forwardedFrom: forwardedFrom,
    );

    await _dao.upsertMessage(message);
    await _dao.setDraft(chatId, '');
    await _dao.touchChat(chatId, previewOf(body, attachment), message.sentAt);
    _messages.add(message);
    _chatUpdates.add(chatId);

    await _sendOrFail(message, _payloadFor(message));
    return message;
  }

  /// Sends a file with an optional caption.
  ///
  /// The message shows up at once with [AttachmentPayload.uploading] as its
  /// attachment, and [uploadProgress] reports how far the file has gone. It
  /// goes out only after the upload: the message must never point
  /// recipients at a blob that does not exist yet.
  ///
  /// Returns once the message is stored; the upload carries on behind it.
  Future<Message> sendFile({
    required String chatId,
    required String body,
    required AttachmentPayload Function(String messageId) placeholder,
    required FileUpload upload,
    String? replyToId,
  }) async {
    final id = _newId();
    final message = Message(
      id: id,
      chatId: chatId,
      senderId: _account.userId,
      senderDeviceId: _account.deviceId,
      body: body,
      sentAt: DateTime.now(),
      isOutgoing: true,
      status: MessageStatus.pending,
      replyToId: replyToId,
      attachment: placeholder(id),
    );

    await _dao.upsertMessage(message);
    await _dao.setDraft(chatId, '');
    await _dao.touchChat(chatId, previewOf(body, message.attachment), message.sentAt);
    _messages.add(message);
    _chatUpdates.add(chatId);

    _uploads[id] = upload;
    _queueUpload(message);
    return message;
  }

  /// Files go up one at a time, in the order they were sent, so an album
  /// arrives in order and one large file does not starve the others of
  /// bandwidth.
  Future<void> _uploadQueue = Future.value();

  void _queueUpload(Message message) {
    _uploadQueue = _uploadQueue.then((_) => _uploadAndSend(message)).catchError((_) {});
  }

  /// Completes once every file sent so far has gone up or failed.
  Future<void> get uploadsSettled => _uploadQueue;

  Future<void> _uploadAndSend(Message message) async {
    // Deleted while it waited its turn.
    if (await _dao.messageById(message.id) == null) return;
    final upload = _uploads[message.id];
    final placeholder = message.attachment;
    if (upload == null || placeholder == null) {
      await _markFailed(message);
      return;
    }
    AttachmentPayload uploaded;
    try {
      uploaded = await upload((fraction) {
        if (!_uploadProgress.isClosed) {
          _uploadProgress.add(UploadProgress(message.id, fraction));
        }
      });
    } catch (_) {
      // Kept, so a retry can try the upload again without picking the file
      // a second time.
      await _markFailed(message);
      return;
    }
    _uploads.remove(message.id);
    // Deleted while it was uploading: nobody is waiting for it.
    if (await _dao.messageById(message.id) == null) return;

    final ready = message.copyWith(attachment: uploaded);
    await _dao.upsertMessage(ready);
    _messages.add(ready);
    await _sendOrFail(ready, _payloadFor(ready));
  }

  Future<void> _markFailed(Message message) async {
    await _dao.updateStatus(message.id, MessageStatus.failed);
    _messages.add(message.copyWith(status: MessageStatus.failed));
  }

  /// Uploads waiting for their file to finish, or to be retried.
  final _uploads = <String, FileUpload>{};

  final _uploadProgress = StreamController<UploadProgress>.broadcast();

  /// How far each file being sent from here has gone up.
  Stream<UploadProgress> get uploadProgress => _uploadProgress.stream;

  /// Sends a message that failed again, under the same id: if the first
  /// attempt did reach the server after all, it recognises the duplicate.
  Future<void> retry(Message message) async {
    final pending = message.copyWith(status: MessageStatus.pending);
    await _dao.updateStatus(message.id, MessageStatus.pending);
    _messages.add(pending);
    if (pending.attachment?.isUploading ?? false) {
      _queueUpload(pending);
      return;
    }
    await _sendOrFail(pending, _payloadFor(pending));
  }

  /// Whether retrying [message] can work: a file whose upload was cut short
  /// by the app closing is gone with it.
  bool canRetry(Message message) =>
      !(message.attachment?.isUploading ?? false) || _uploads.containsKey(message.id);

  /// Changes the text of one of our messages, for everyone.
  Future<void> edit(Message message, String body) async {
    if (!message.isOutgoing || body.trim().isEmpty) return;
    final now = DateTime.now();
    await _dao.editMessage(message.id, body, now);
    await _dao.refreshPreview(message.chatId, _previewOfMessage);
    _messages.add(message.copyWith(body: body, editedAt: now));
    _chatUpdates.add(message.chatId);

    await _dispatch(
      message.chatId,
      MessagePayload(
        kind: PayloadKind.edit,
        targetId: message.id,
        body: body,
        sentAt: now,
      ),
      _newId(),
    );
  }

  /// Deletes a message for everyone: ours, or anyone's when we administer
  /// the group.
  Future<void> delete(Message message) async {
    _uploads.remove(message.id);
    await _dao.deleteMessage(message.id);
    await _dao.refreshPreview(message.chatId, _previewOfMessage);
    _removed.add(message);
    _chatUpdates.add(message.chatId);

    // A message that never reached the server has nobody to delete it for.
    if (message.seq == null) {
      await _outbox.remove(message.id);
      return;
    }
    await _dispatch(
      message.chatId,
      MessagePayload(kind: PayloadKind.delete, targetId: message.id),
      _newId(),
    );
  }

  /// Sends an emoji reaction.
  ///
  /// In a secret chat the reaction travels inside the encrypted payload, so
  /// the server cannot learn who reacted to what.
  Future<void> react({
    required String chatId,
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

    await _dispatch(
      chatId,
      MessagePayload(
        reaction: ReactionPayload(
          targetId: targetId,
          emoji: emoji,
          remove: remove,
        ),
      ),
      _newId(),
    );
  }

  /// Renames a secret group, end to end: the server never learns the name.
  Future<void> renameSecretGroup(String chatId, String title) async {
    await _dao.setTitle(chatId, title);
    _chatUpdates.add(chatId);
    await _dispatch(
      chatId,
      MessagePayload(kind: PayloadKind.meta, title: title),
      _newId(),
    );
  }

  /// Sends a copy of [message] to another chat, naming its original author.
  ///
  /// The attachment travels by reference: the copy carries the same blob id
  /// and key. Forwarding from a secret chat into a cloud one therefore hands
  /// the file's key to the server -- which is what forwarding there means.
  Future<Message> forward(
    Message message,
    String toChatId, {
    required String authorName,
  }) => send(
    chatId: toChatId,
    body: message.body,
    attachment: message.attachment,
    forwardedFrom: message.forwardedFrom ?? authorName,
  );

  MessagePayload _payloadFor(Message message) => MessagePayload(
    body: message.body,
    replyToId: message.replyToId,
    attachment: message.attachment,
    sentAt: message.sentAt,
    forwardedFrom: message.forwardedFrom,
  );

  /// When each chat last told the others we are typing.
  final Map<String, DateTime> _typingSent = {};

  /// Tells the chat we are typing, at most every few seconds however fast
  /// the keys go.
  void typingIn(String chatId) {
    final last = _typingSent[chatId];
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 4)) {
      return;
    }
    _typingSent[chatId] = now;
    _ws.trySend(Envelope(type: EnvelopeType.typing, chatId: chatId));
  }

  // ------------------------------------------------- this device's list

  Future<void> saveDraft(String chatId, String draft) async {
    await _dao.setDraft(chatId, draft);
    _chatUpdates.add(chatId);
  }

  Future<void> setPinned(String chatId, bool value) =>
      _changeList(chatId, () => _dao.setPinned(chatId, value));
  Future<void> setMuted(String chatId, bool value) =>
      _changeList(chatId, () => _dao.setMuted(chatId, value));
  Future<void> setArchived(String chatId, bool value) =>
      _changeList(chatId, () => _dao.setArchived(chatId, value));

  Future<void> _changeList(
    String chatId,
    Future<void> Function() change,
  ) async {
    await change();
    _chatUpdates.add(chatId);
  }

  /// Removes a direct chat from the list and its history from this device.
  ///
  /// A cloud chat's history is also cleared for us on the server, or the
  /// next sync would bring it back; the other side keeps theirs. The chat
  /// returns to the list when a new message arrives.
  Future<void> deleteDirectChat(String chatId) async {
    final chat = await _dao.chatById(chatId);
    if (chat == null) return;
    if (chat.isCloud) {
      await _api.clearChat(chatId);
      await _dao.setSyncedSeq(
        chatId,
        await _remoteLastSeq(chatId) ?? chat.syncedSeq,
      );
    }
    await _dao.clearMessages(chatId);
    await _dao.setHidden(chatId, true);
    _chatUpdates.add(chatId);
  }

  Future<int?> _remoteLastSeq(String chatId) async {
    try {
      return (await _api.getChat(chatId)).lastSeq;
    } on ApiException {
      return null;
    }
  }

  Future<void> _sendOrFail(Message message, MessagePayload payload) async {
    try {
      await _dispatch(message.chatId, payload, message.id);
    } catch (e) {
      await _dao.updateStatus(message.id, MessageStatus.failed);
      _messages.add(message.copyWith(status: MessageStatus.failed));
      rethrow;
    }
  }

  /// Per-chat chain of sends.
  ///
  /// A secret group's sender key advances with every message; two sends
  /// building frames at once would both start from the same chain state and
  /// encrypt under the same message key. Everything that builds a frame for a
  /// chat waits its turn here.
  final Map<String, Future<void>> _chatQueues = {};

  Future<T> _inChatOrder<T>(String chatId, Future<T> Function() body) {
    final previous = _chatQueues[chatId] ?? Future<void>.value();
    final next = previous.then((_) => body());
    _chatQueues[chatId] = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// Payloads of frames in flight, by frame id, so a send the server refused
  /// for a stale group epoch can be encrypted again under the new one.
  final Map<String, ({String chatId, MessagePayload payload})> _inFlight = {};

  /// Builds the frame for a payload, keeps it until the server answers, and
  /// sends it if connected.
  Future<void> _dispatch(String chatId, MessagePayload payload, String id) =>
      _inChatOrder(chatId, () async {
        final chat = await _dao.chatById(chatId);
        if (chat == null) throw StateError('unknown chat $chatId');

        final frame = await _buildFrame(chat, payload, id);
        _inFlight[id] = (chatId: chatId, payload: payload);
        await _outbox.add(id, chatId, frame.toJson());
        _ws.trySend(frame);
      });

  Future<Envelope> _buildFrame(
    Chat chat,
    MessagePayload payload,
    String id,
  ) async {
    if (chat.isCloud) return _cloudFrame(chat, payload, id);
    if (chat.isGroup) return _groupFrame(chat, payload, id);
    return _directFrame(chat, payload, id);
  }

  /// A cloud chat's frame: the payload itself, protected by TLS on the way
  /// and by the storage key on the server. Events say on the envelope what
  /// they do, so the server can apply them to the history it keeps.
  Envelope _cloudFrame(Chat chat, MessagePayload payload, String id) {
    final (kind, emoji) = switch (payload.kind) {
      PayloadKind.edit => ('edit', null),
      PayloadKind.delete => ('delete', null),
      PayloadKind.reaction => (
        payload.reaction!.remove ? 'unreact' : 'react',
        payload.reaction!.emoji,
      ),
      _ => ('', null),
    };
    final target = payload.kind == PayloadKind.reaction
        ? payload.reaction!.targetId
        : payload.targetId;
    return Envelope(
      type: EnvelopeType.message,
      id: id,
      chatId: chat.id,
      cipherType: CipherTypes.cloud,
      ciphertext: base64Encode(payload.encode()),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
      targetId: target,
      emoji: emoji,
    );
  }

  /// A secret direct chat's frame: the payload encrypted separately for
  /// every recipient device.
  ///
  /// One ciphertext per device is not an optimisation detail: each device has
  /// its own ratchet, so a shared ciphertext would be undecryptable for every
  /// device but one. The peer's other devices and our own both appear here,
  /// which is what keeps a multi-device account in sync.
  Future<Envelope> _directFrame(
    Chat chat,
    MessagePayload payload,
    String id,
  ) async {
    final peerUsername = chat.peerUsername;
    if (peerUsername == null) throw StateError('chat ${chat.id} has no peer');

    final devices = await _resolver.devicesForDirectMessage(peerUsername);
    if (devices.isEmpty) {
      throw StateError('no devices to deliver to for $peerUsername');
    }
    return Envelope(
      type: EnvelopeType.message,
      id: id,
      chatId: chat.id,
      payloads: await _sealForDevices(chat.id, devices, payload.encode()),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Encrypts [plaintext] for each device over the pairwise sessions.
  Future<List<DevicePayloadWire>> _sealForDevices(
    String chatId,
    List<ResolvedDevice> devices,
    Uint8List plaintext,
  ) async {
    final entries = <DevicePayloadWire>[];
    for (final device in devices) {
      _lastChatForPeer[device.address.key] = chatId;
      try {
        final encrypted = await _crypto.encrypt(device.address, plaintext);
        entries.add(
          DevicePayloadWire(
            userId: device.address.userId,
            deviceId: device.address.deviceId,
            cipherType: encrypted.cipherType,
            ciphertext: base64Encode(_wireBody(encrypted)),
          ),
        );
      } on IdentityChangedException {
        // Only reachable in strict mode; the default policy rebuilds the
        // session instead and reports it on the engine's stream.
        _identityAlerts.add(
          IdentityChangeAlert(
            peer: device.address,
            chatId: chatId,
            blocksSending: true,
          ),
        );
        rethrow;
      }
    }
    return entries;
  }

  /// A secret group's frame: one ciphertext under our sender key, after
  /// making sure every member device has that key.
  Future<Envelope> _groupFrame(
    Chat chat,
    MessagePayload payload,
    String id,
  ) async {
    await _shareSenderKey(chat);
    final ciphertext = await _groups.encrypt(
      chat.id,
      chat.epoch,
      payload.encode(),
    );
    return Envelope(
      type: EnvelopeType.message,
      id: id,
      chatId: chat.id,
      cipherType: CipherTypes.senderKey,
      ciphertext: base64Encode(ciphertext),
      epoch: chat.epoch,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// When each group epoch's member devices were last checked against the
  /// devices that hold our key.
  final Map<String, DateTime> _sharesCheckedAt = {};

  /// How long a check is trusted. Device changes are also announced by the
  /// server, which clears the cache at once.
  static const _shareCheckTtl = Duration(minutes: 5);

  /// Sends our sender key for the chat's epoch to member devices that do
  /// not have it: everyone, at a new epoch; just the newcomer, when a member
  /// adds a device.
  Future<void> _shareSenderKey(Chat chat) async {
    final key = '${chat.id}@${chat.epoch}';
    final checked = _sharesCheckedAt[key];
    if (checked != null &&
        DateTime.now().difference(checked) < _shareCheckTtl) {
      return;
    }

    final devices = <ResolvedDevice>[];
    for (final member in chat.members) {
      devices.addAll(await _resolver.devicesFor(member.username));
    }
    final byId = {for (final d in devices) d.address.deviceId: d};
    final missing = await _groups.unshared(chat.id, chat.epoch, byId.keys);

    if (missing.isNotEmpty) {
      final skdm = (await _groups.distribution(
        chat.id,
        chat.epoch,
      )).serialize();
      final targets = [for (final id in missing) byId[id]!];
      final frameId = _newId();
      final frame = Envelope(
        type: EnvelopeType.senderKey,
        id: frameId,
        chatId: chat.id,
        epoch: chat.epoch,
        payloads: await _sealForDevices(chat.id, targets, skdm),
      );
      // Queued ahead of the message it unlocks, so a replay keeps the order.
      await _outbox.add(frameId, chat.id, frame.toJson());
      _ws.trySend(frame);
      await _groups.recordShares(chat.id, chat.epoch, missing);
    }
    _sharesCheckedAt[key] = DateTime.now();
  }

  // ------------------------------------------------------------ history

  /// A page of local history, oldest first.
  Future<List<Message>> history(
    String chatId, {
    int? beforeSeq,
    int limit = 50,
  }) => _dao.messagesForChat(chatId, beforeSeq: beforeSeq, limit: limit);

  /// Older messages than [beforeSeq]. A cloud chat's history may reach
  /// further back on the server than on this device -- always, on a new
  /// one -- so when the local copy runs out, the server is asked.
  Future<List<Message>> loadOlder(
    String chatId,
    int beforeSeq, {
    int limit = 50,
  }) async {
    final local = await _dao.messagesForChat(
      chatId,
      beforeSeq: beforeSeq,
      limit: limit,
    );
    if (local.isNotEmpty) return local;

    final chat = await _dao.chatById(chatId);
    if (chat == null || !chat.isCloud || beforeSeq <= 1) return const [];
    final remote = await _api.chatMessages(
      chatId,
      before: beforeSeq,
      limit: limit,
    );
    for (final row in remote) {
      await _storeHistoryRow(chat, row);
    }
    return _dao.messagesForChat(chatId, beforeSeq: beforeSeq, limit: limit);
  }

  /// The furthest read position this device has reported, per chat.
  final Map<String, int> _readSent = {};

  /// Marks everything in a chat as read: here, on our other devices, and
  /// for the other members' read ticks.
  Future<void> markRead(String chatId) async {
    await _dao.clearUnread(chatId);
    _chatUpdates.add(chatId);
    final seq = await _dao.maxSeq(chatId);
    if (seq <= (_readSent[chatId] ?? 0)) return;
    _readSent[chatId] = seq;
    _ws.send(Envelope(type: EnvelopeType.read, chatId: chatId, seq: seq));
  }

  // --------------------------------------------------------------- sync

  Future<void> _onConnected() async {
    for (final entry in await _outbox.pending()) {
      if (!_ws.trySendJson(entry.frame)) return;
    }
    try {
      await sync();
    } catch (e) {
      // ignore: avoid_print
      print('[frogster] sync failed: $e');
    }
  }

  Future<void>? _syncing;

  /// Brings the chat list and cloud histories up to date with the server.
  ///
  /// Runs on every connection: anything that happened while this device was
  /// away -- new chats, renamed groups, messages in cloud chats, how far the
  /// others have read -- is learned here.
  Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    final remote = await _api.listChats();
    final present = <String>{};
    for (final rc in remote) {
      present.add(rc.id);
      final chat = await _saveRemoteChat(rc);
      if (chat.isCloud) await _catchUp(chat, rc.lastSeq);
      _chatUpdates.add(chat.id);
    }
    // Groups this device still lists but the server no longer does: we
    // left, or were removed, while away.
    for (final local in await _dao.chats()) {
      if (local.isGroup && !present.contains(local.id)) {
        await _forgetChat(local.id);
      }
    }
  }

  /// The chat as this device knows it.
  Future<Chat?> chat(String chatId) => _dao.chatById(chatId);

  /// Stores a chat the server just returned -- one we created, renamed or
  /// changed the members of -- and returns it as the app sees it.
  Future<Chat> adoptChat(RemoteChat remote) async {
    final chat = await _saveRemoteChat(remote);
    _chatUpdates.add(chat.id);
    return chat;
  }

  /// Drops a chat this device is no longer part of, with its history and
  /// keys.
  Future<void> forgetChat(String chatId) => _forgetChat(chatId);

  /// Fetches one chat afresh, or forgets it when we are no longer in it.
  Future<Chat?> refreshChat(String chatId) async {
    try {
      final chat = await _saveRemoteChat(await _api.getChat(chatId));
      _chatUpdates.add(chatId);
      return chat;
    } on ApiException catch (e) {
      if (e.statusCode == 404) await _forgetChat(chatId);
      return null;
    }
  }

  Future<Chat> _saveRemoteChat(RemoteChat rc) async {
    final local = await _dao.chatById(rc.id);
    var chat = rc.toChat(_account.userId, local: local);
    final last = rc.last;
    if (last != null && last.payload != null) {
      final payload = _decodePayload(last.payload!);
      if (payload != null) {
        chat = chat.copyWith(
          lastMessagePreview: previewOf(payload.body, payload.attachment),
          lastMessageAt: last.timestamp,
        );
      }
    }
    if (chat.isSecret && chat.isGroup && (local?.epoch ?? 0) != chat.epoch) {
      // A new epoch: whoever needs our new key gets it with the next send.
      _sharesCheckedAt.removeWhere((key, _) => key.startsWith('${chat.id}@'));
    }
    await _dao.upsertChat(chat);
    if (chat.peerReadSeq > 0) {
      await _dao.markOutgoingRead(chat.id, chat.peerReadSeq);
    }
    return chat;
  }

  Future<void> _forgetChat(String chatId) async {
    await _dao.deleteChat(chatId);
    await _groups.forgetChat(chatId);
    _chatUpdates.add(chatId);
  }

  /// How far behind a cloud chat may be before catching up event by event
  /// stops being worth it, and the device starts again from the newest page.
  static const _replayLimit = 1000;

  /// Fetches what a cloud chat gained since this device last saw it.
  Future<void> _catchUp(Chat chat, int lastSeq) async {
    var synced = chat.syncedSeq;
    if (lastSeq <= synced) return;

    if (synced == 0 || lastSeq - synced > _replayLimit) {
      // A new device, or one away for long: the newest page, in its current
      // state. Older pages load as the user scrolls up.
      for (final row in await _api.chatMessages(chat.id, limit: 50)) {
        await _storeHistoryRow(chat, row);
      }
      synced = lastSeq;
    } else {
      while (synced < lastSeq) {
        final rows = await _api.chatMessages(
          chat.id,
          after: synced,
          limit: 200,
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          final payload = row.payload == null
              ? null
              : _decodePayload(row.payload!);
          if (payload != null) {
            await _apply(
              chat,
              payload,
              id: row.id,
              senderId: row.senderId,
              senderDeviceId: row.senderDeviceId,
              seq: row.seq,
              at: row.timestamp,
              countUnread: false,
            );
          }
        }
        synced = rows.last.seq;
      }
    }
    await _dao.setSyncedSeq(chat.id, synced);
  }

  /// Stores a history row as it stands now: edited text, reactions, and
  /// nothing at all for a deleted message.
  Future<void> _storeHistoryRow(Chat chat, RemoteMessage row) async {
    final existing = await _dao.messageById(row.id);
    final message = _messageFromRow(chat, row, editedAt: existing?.editedAt);
    if (message != null) await _dao.upsertMessage(message);
  }

  /// A history row as a message, or null for an event or a deleted one.
  Message? _messageFromRow(Chat chat, RemoteMessage row, {DateTime? editedAt}) {
    if (row.deleted || row.kind.isNotEmpty || row.payload == null) return null;
    final payload = _decodePayload(row.payload!);
    if (payload == null) return null;
    final own = row.senderId == _account.userId;
    return Message(
        id: row.id,
        chatId: chat.id,
        senderId: row.senderId,
        senderDeviceId: row.senderDeviceId,
        body: payload.body,
        sentAt: payload.sentAt ?? row.timestamp,
        isOutgoing: own,
        seq: row.seq,
        status: own && row.seq <= chat.peerReadSeq
            ? MessageStatus.read
            : (own ? MessageStatus.sent : MessageStatus.delivered),
        replyToId: payload.replyToId,
        attachment: payload.attachment,
        reactions: row.reactions,
        editedAt: row.editedAt ?? editedAt,
        forwardedFrom: payload.forwardedFrom,
    );
  }

  /// Searches the whole cloud history on the server, past what this device
  /// has loaded. The results are not stored: an old message on its own
  /// would leave a hole in the local history that paging could not see.
  Future<List<Message>> searchServer(String query) async {
    final hits = await _api.searchMessages(query);
    final out = <Message>[];
    for (final hit in hits) {
      final chat = await _dao.chatById(hit.chatId);
      if (chat == null) continue;
      final message = _messageFromRow(chat, hit.message);
      if (message != null) out.add(message);
    }
    return out;
  }

  // ------------------------------------------------------------ receiving

  /// Handles an inbound frame.
  Future<void> _onEnvelope(Envelope envelope) async {
    switch (envelope.type) {
      case EnvelopeType.message:
        final settled = await _onIncomingMessage(envelope);
        // Acknowledged whatever the outcome, unless the message is waiting
        // for its sender key: a stored message must not be delivered again,
        // and one that failed to decrypt would fail the same way on every
        // reconnect. Cloud messages are not queued, so there is nothing to
        // acknowledge.
        if (settled && !envelope.isCloudPayload) {
          _acknowledge(envelope.id);
        }
      case EnvelopeType.senderKey:
        await _onSenderKey(envelope);
        _acknowledge(envelope.id);
      case EnvelopeType.ack:
        await _onAck(envelope);
      case EnvelopeType.error:
        await _onError(envelope);
      case EnvelopeType.read:
        await _onRead(envelope);
      case EnvelopeType.typing:
        final chatId = envelope.chatId;
        final userId = envelope.senderUserId;
        if (chatId != null && userId != null && userId != _account.userId) {
          _typing.add(TypingNotice(chatId, userId));
        }
      case EnvelopeType.chatUpdated:
        final chatId = envelope.chatId;
        if (chatId != null) await refreshChat(chatId);
      case EnvelopeType.keyChange:
        _onKeyChange(envelope);
      case EnvelopeType.deviceAdded:
        _onDeviceAdded(envelope);
    }
  }

  /// Group messages that arrived before the sender key they need, by
  /// `chat:device`. Not acknowledged, so the server still has them if the
  /// app closes before the key turns up.
  final Map<String, List<Envelope>> _awaitingKey = {};

  /// Processes a message frame. Returns false when it has to wait.
  Future<bool> _onIncomingMessage(Envelope envelope) async {
    final chatId = envelope.chatId;
    final senderId = envelope.senderUserId;
    final senderDeviceId = envelope.senderDeviceId;
    final ciphertext = envelope.ciphertext;

    if (chatId == null ||
        senderId == null ||
        senderDeviceId == null ||
        ciphertext == null) {
      return true;
    }

    // A frame from this very device would be our own echo.
    if (senderDeviceId == _account.deviceId) return true;

    // Drop a message we already hold, before touching any key.
    //
    // A redelivery is not decryptable a second time: the message key was
    // destroyed when it first arrived, so attempting it raises a MAC failure
    // that looks identical to tampering.
    final envelopeId = envelope.id;
    if (envelopeId != null && await _dao.messageById(envelopeId) != null) {
      return true;
    }

    final peer = PeerAddress(userId: senderId, deviceId: senderDeviceId);
    try {
      var chat =
          await _dao.chatById(chatId) ?? await _discoverChat(chatId, senderId);
      if (chat == null) return true;

      final Uint8List plaintext;
      if (envelope.isCloudPayload) {
        if (!chat.isCloud) {
          // Plaintext arriving in a secret chat is refused outright: it is
          // either a bug or an attempt to downgrade the conversation.
          throw StateError('unencrypted message in secret chat $chatId');
        }
        plaintext = base64Decode(ciphertext);
      } else if (chat.isCloud) {
        throw StateError('encrypted message in cloud chat $chatId');
      } else if (envelope.cipherType == CipherTypes.senderKey) {
        final serialized = base64Decode(ciphertext);
        if (GroupCipher.epochOf(serialized) > chat.epoch) {
          // The group moved on and this device has not heard yet.
          chat = await refreshChat(chatId) ?? chat;
        }
        try {
          plaintext = await _groups.decrypt(
            chatId: chatId,
            chatEpoch: chat.epoch,
            senderDeviceId: senderDeviceId,
            serialized: serialized,
          );
        } on MissingSenderKeyException {
          _awaitingKey
              .putIfAbsent('$chatId:$senderDeviceId', () => [])
              .add(envelope);
          return false;
        }
      } else {
        _lastChatForPeer[peer.key] = chatId;
        final payload = EncryptedPayload.fromJson(
          jsonDecode(utf8.decode(base64Decode(ciphertext)))
              as Map<String, dynamic>,
        );
        plaintext = await _crypto.decrypt(peer, payload);
      }

      final decoded = MessagePayload.decode(plaintext);
      await _apply(
        chat,
        decoded,
        id: envelope.id ?? _newId(),
        senderId: senderId,
        senderDeviceId: senderDeviceId,
        seq: envelope.seq,
        at: DateTime.fromMillisecondsSinceEpoch(
          envelope.timestamp ?? DateTime.now().millisecondsSinceEpoch,
        ),
        countUnread: true,
      );
      if (chat.isCloud) await _advanceSynced(chatId, envelope.seq);
    } catch (error, stack) {
      // An undecryptable message is dropped rather than shown as corrupt
      // text. It is reported, though: silently swallowing this turns "my
      // messages never arrive" into a problem with no evidence anywhere.
      // Identifiers and the error only -- never the payload.
      _decryptFailures.add(
        DecryptFailure(
          peer: peer,
          chatId: chatId,
          error: error,
          stackTrace: stack,
        ),
      );
      // ignore: avoid_print
      print(
        '[frogster] could not read a message from $senderId/$senderDeviceId '
        'in chat $chatId: $error',
      );
    }
    return true;
  }

  /// Applies a payload: stores a message, or carries out what an event
  /// asks, provided its sender may.
  Future<void> _apply(
    Chat chat,
    MessagePayload payload, {
    required String id,
    required String senderId,
    required String senderDeviceId,
    required int? seq,
    required DateTime at,
    required bool countUnread,
  }) async {
    final own = senderId == _account.userId;
    switch (payload.kind) {
      case PayloadKind.reaction:
        final reaction = payload.reaction;
        if (reaction == null) return;
        await _dao.applyReaction(
          targetId: reaction.targetId,
          emoji: reaction.emoji,
          userId: senderId,
          remove: reaction.remove,
        );
        final target = await _dao.messageById(reaction.targetId);
        if (target != null) _messages.add(target);

      case PayloadKind.edit:
        final target = await _targetOf(payload, chat.id);
        // Only the author changes a message's words.
        if (target == null || target.senderId != senderId) return;
        final editedAt = payload.sentAt ?? at;
        await _dao.editMessage(target.id, payload.body, editedAt);
        await _dao.refreshPreview(chat.id, _previewOfMessage);
        _messages.add(target.copyWith(body: payload.body, editedAt: editedAt));
        _chatUpdates.add(chat.id);

      case PayloadKind.delete:
        final target = await _targetOf(payload, chat.id);
        if (target == null) return;
        final admin = chat.isGroup && (chat.member(senderId)?.isAdmin ?? false);
        if (target.senderId != senderId && !admin) return;
        await _dao.deleteMessage(target.id);
        await _dao.refreshPreview(chat.id, _previewOfMessage);
        _removed.add(target);
        _chatUpdates.add(chat.id);

      case PayloadKind.meta:
        // A secret group's name; a cloud group's comes from the server.
        final title = payload.title?.trim();
        if (!chat.isGroup || !chat.isSecret || title == null || title.isEmpty) {
          return;
        }
        if (!(chat.member(senderId)?.isAdmin ?? false)) return;
        await _dao.setTitle(chat.id, title);
        _chatUpdates.add(chat.id);

      case PayloadKind.message:
        // Already here -- usually our own message coming back in a sync.
        // Storing it again would undo what this device knows about it,
        // such as its read ticks.
        final existing = await _dao.messageById(id);
        if (existing != null) {
          if (seq != null && existing.seq == null) {
            // It reached the server; the ack was lost on the way back.
            await _dao.updateStatus(id, MessageStatus.sent, seq: seq);
            _outbox.remove(id).ignore();
          }
          return;
        }
        final message = Message(
          id: id,
          chatId: chat.id,
          senderId: senderId,
          senderDeviceId: senderDeviceId,
          body: payload.body,
          sentAt: payload.sentAt ?? at,
          // A message from another of *our* devices is one we sent
          // elsewhere: it belongs on the right-hand side.
          isOutgoing: own,
          seq: seq,
          status: own ? MessageStatus.sent : MessageStatus.delivered,
          replyToId: payload.replyToId,
          attachment: payload.attachment,
          forwardedFrom: payload.forwardedFrom,
        );
        await _dao.upsertMessage(message);
        // A message we sent from another device is already read: counting
        // it would show a badge for our own typing.
        await _dao.touchChat(
          chat.id,
          previewOf(payload.body, payload.attachment),
          message.sentAt,
          incrementUnread: countUnread && !own,
        );
        _messages.add(message);
        _chatUpdates.add(chat.id);
        if (countUnread && !own) _arrivals.add(message);
    }
  }

  Future<Message?> _targetOf(MessagePayload payload, String chatId) async {
    final id = payload.targetId;
    if (id == null) return null;
    final target = await _dao.messageById(id);
    return target?.chatId == chatId ? target : null;
  }

  /// Learns about a chat this device has never seen: created on another of
  /// our devices, or by someone who just wrote to us.
  ///
  /// Without a local row the message insert fails its foreign key and the
  /// message disappears -- exactly how "I write from the phone and the PC
  /// shows nothing" happens.
  Future<Chat?> _discoverChat(String chatId, String senderId) async {
    final remote = await refreshChat(chatId);
    if (remote != null) return remote;

    // Unreachable server: a direct secret chat can still be named from the
    // sender, and its messages still decrypted.
    final own = senderId == _account.userId;
    var peerUsername = own ? null : _resolver.usernameFor(senderId);
    if (peerUsername == null && !own) {
      peerUsername = await _resolver.lookupUsername(senderId);
    }
    final chat = Chat(
      id: chatId,
      type: 'direct',
      epoch: 0,
      peerUsername: peerUsername,
    );
    await _dao.upsertChat(chat);
    return chat;
  }

  /// Moves a cloud chat's sync position forward when [seq] is the next one,
  /// so a reconnect does not refetch what arrived live. A gap leaves it
  /// where it is, for the next sync to fill.
  Future<void> _advanceSynced(String chatId, int? seq) async {
    if (seq == null) return;
    final chat = await _dao.chatById(chatId);
    if (chat != null && seq == chat.syncedSeq + 1) {
      await _dao.setSyncedSeq(chatId, seq);
    }
  }

  /// A member's sender key, sealed in our pairwise session with them.
  Future<void> _onSenderKey(Envelope envelope) async {
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
    final peer = PeerAddress(userId: senderId, deviceId: senderDeviceId);
    try {
      final payload = EncryptedPayload.fromJson(
        jsonDecode(utf8.decode(base64Decode(ciphertext)))
            as Map<String, dynamic>,
      );
      final skdm = SenderKeyDistributionMessage.deserialize(
        await _crypto.decrypt(peer, payload),
      );
      await _groups.install(skdm, chatId: chatId, fromDeviceId: senderDeviceId);
    } catch (error, stack) {
      _decryptFailures.add(
        DecryptFailure(
          peer: peer,
          chatId: chatId,
          error: error,
          stackTrace: stack,
        ),
      );
      return;
    }

    // Messages that were waiting for exactly this key.
    final waiting = _awaitingKey.remove('$chatId:$senderDeviceId') ?? const [];
    for (final parked in waiting) {
      if (await _onIncomingMessage(parked)) _acknowledge(parked.id);
    }
  }

  Future<void> _onAck(Envelope envelope) async {
    final id = envelope.id;
    if (id == null) return;
    await _outbox.remove(id);
    _inFlight.remove(id);

    final message = await _dao.messageById(id);
    if (message == null) return;
    await _dao.updateStatus(id, MessageStatus.sent, seq: envelope.seq);
    final updated = await _dao.messageById(id);
    if (updated != null) _messages.add(updated);

    final chat = await _dao.chatById(message.chatId);
    if (chat != null && chat.isCloud) {
      await _advanceSynced(chat.id, envelope.seq);
    }
  }

  /// The server refused a frame.
  Future<void> _onError(Envelope envelope) async {
    final id = envelope.id;
    if (id == null) return;
    await _outbox.remove(id);
    final inFlight = _inFlight.remove(id);

    if (envelope.error == ServerErrors.staleEpoch) {
      // The group's membership changed while this was on its way. It was
      // encrypted under a key the group has moved past; fetch the new epoch
      // and send it again under a new key.
      final chatId = envelope.chatId ?? inFlight?.chatId;
      if (chatId != null) await refreshChat(chatId);
      if (inFlight != null) {
        try {
          await _dispatch(inFlight.chatId, inFlight.payload, id);
          return;
        } catch (_) {
          // Falls through to marking it failed.
        }
      } else if (await _dao.messageById(id) case final message?) {
        // Replayed from the outbox after a restart: rebuild from the
        // stored message.
        try {
          await _dispatch(message.chatId, _payloadFor(message), id);
          return;
        } catch (_) {}
      }
    }

    final message = await _dao.messageById(id);
    if (message != null) {
      await _dao.updateStatus(id, MessageStatus.failed);
      _messages.add(message.copyWith(status: MessageStatus.failed));
    }
  }

  /// Someone read further in a chat: another member, or we did on another
  /// device.
  Future<void> _onRead(Envelope envelope) async {
    final chatId = envelope.chatId;
    final seq = envelope.seq;
    if (chatId == null || seq == null) return;

    if (envelope.senderUserId == _account.userId) {
      if (seq >= await _dao.maxSeq(chatId)) {
        await _dao.clearUnread(chatId);
        _chatUpdates.add(chatId);
      }
      return;
    }
    await _dao.raisePeerReadSeq(chatId, seq);
    if (await _dao.markOutgoingRead(chatId, seq) > 0) {
      _reads.add(ReadUpdate(chatId, seq));
    }
  }

  /// A contact registered a new device, or replaced an existing one.
  ///
  /// Dropping the cached device list is the load-bearing part. Without it we
  /// keep encrypting for the devices we resolved earlier, so a peer who wiped
  /// and signed back in never receives anything.
  void _onKeyChange(Envelope envelope) {
    final userId = envelope.senderUserId;
    final deviceId = envelope.senderDeviceId;
    if (userId == null || deviceId == null) return;

    final username = _resolver.usernameFor(userId);
    if (username != null) {
      _resolver.invalidate(username);
    } else {
      _resolver.invalidateAll();
    }
    // Any group with them may now have a device without our sender key.
    _sharesCheckedAt.clear();

    _identityAlerts.add(
      IdentityChangeAlert(
        peer: PeerAddress(userId: userId, deviceId: deviceId),
        chatId: envelope.chatId ?? '',
      ),
    );
  }

  /// One of our *own* devices was added: a second desktop, a replaced phone.
  void _onDeviceAdded(Envelope envelope) {
    _resolver.invalidate(_account.username);
    _sharesCheckedAt.clear();
  }

  // -------------------------------------------------------------- helpers

  /// Serializes the payload for the wire.
  Uint8List _wireBody(EncryptedPayload payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload.toJson())));

  MessagePayload? _decodePayload(Uint8List bytes) {
    try {
      return MessagePayload.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// The chat-list preview line.
  ///
  /// An attachment with no caption would otherwise show an empty row, so it
  /// falls back to the file name or a placeholder the UI translates.
  static String previewOf(String body, AttachmentPayload? attachment) {
    if (body.isNotEmpty) return body;
    if (attachment == null) return '';
    if (attachment.voice) return PreviewTokens.voice;
    if (attachment.isImage) return PreviewTokens.photo;
    return attachment.fileName ?? PreviewTokens.file;
  }

  static String _previewOfMessage(Message m) => previewOf(m.body, m.attachment);

  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_account.deviceId.substring(0, 8)}';

  /// Message ids stored since the last acknowledgement frame.
  final List<String> _unacknowledged = [];
  Timer? _ackTimer;

  /// Upper bound on ids per frame; the server accepts up to 500.
  static const _maxAckBatch = 100;

  /// Queues an acknowledgement. Batched, because an offline flush delivers
  /// hundreds of messages in a burst and one frame per message would trip
  /// the server's frame rate limit.
  void _acknowledge(String? id) {
    if (id == null) return;
    _unacknowledged.add(id);
    if (_unacknowledged.length >= _maxAckBatch) {
      _flushAcknowledgements();
    } else {
      _ackTimer ??= Timer(
        const Duration(milliseconds: 300),
        _flushAcknowledgements,
      );
    }
  }

  void _flushAcknowledgements() {
    _ackTimer?.cancel();
    _ackTimer = null;
    if (_unacknowledged.isEmpty) return;
    _ws.send(
      Envelope(type: EnvelopeType.delivered, ids: List.of(_unacknowledged)),
    );
    _unacknowledged.clear();
  }

  Future<void> dispose() async {
    _flushAcknowledgements();
    await _subscription.cancel();
    await _connectionSub.cancel();
    await _identityChangeSub.cancel();
    await _messages.close();
    await _removed.close();
    await _chatUpdates.close();
    await _reads.close();
    await _typing.close();
    await _arrivals.close();
    await _identityAlerts.close();
    await _decryptFailures.close();
    await _uploadProgress.close();
  }
}
