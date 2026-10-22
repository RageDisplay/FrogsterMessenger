/// State management for an open conversation.
library;

import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../crypto/crypto_engine.dart';
import '../../../data/models/models.dart';
import '../../../data/repositories/attachment_repository.dart';
import '../../../data/repositories/device_resolver.dart';
import '../../../data/repositories/message_repository.dart';
import '../view/chat_screen.dart';

sealed class ChatEvent {
  const ChatEvent();
}

class ChatOpened extends ChatEvent {
  const ChatOpened(this.chat);

  final Chat chat;
}

/// The chat itself changed: renamed, members added or removed.
class ChatInfoChanged extends ChatEvent {
  const ChatInfoChanged(this.chat);

  final Chat chat;
}

class ChatMessageSent extends ChatEvent {
  const ChatMessageSent(this.body, {this.replyToId, this.attachment});

  final String body;
  final String? replyToId;

  /// A file chosen but not yet uploaded. The bloc encrypts and uploads it
  /// before the message goes out, so the reference in the message always
  /// points at a blob that exists.
  final PickedAttachment? attachment;
}

class ChatReactionToggled extends ChatEvent {
  const ChatReactionToggled(this.targetId, this.emoji, this.remove);

  final String targetId;
  final String emoji;
  final bool remove;
}

class ChatMessageEdited extends ChatEvent {
  const ChatMessageEdited(this.message, this.body);

  final Message message;
  final String body;
}

class ChatMessageDeleted extends ChatEvent {
  const ChatMessageDeleted(this.message);

  final Message message;
}

/// Forward a message to another chat.
class ChatMessageForwarded extends ChatEvent {
  const ChatMessageForwarded(this.message, this.toChatId);

  final Message message;
  final String toChatId;
}

/// The composer's text changed: keep the draft, tell the others we type.
class ChatComposerChanged extends ChatEvent {
  const ChatComposerChanged(this.text);

  final String text;
}

class _ChatTypingSeen extends ChatEvent {
  const _ChatTypingSeen(this.userId, {required this.typing});

  final String userId;
  final bool typing;
}

class ChatRetryRequested extends ChatEvent {
  const ChatRetryRequested(this.message);

  final Message message;
}

/// The user scrolled to the top of what is loaded.
class ChatOlderRequested extends ChatEvent {
  const ChatOlderRequested();
}

/// A message arrived or changed state.
class ChatMessageReceived extends ChatEvent {
  const ChatMessageReceived(this.message);

  final Message message;
}

class ChatMessageRemoved extends ChatEvent {
  const ChatMessageRemoved(this.message);

  final Message message;
}

class ChatReadUpTo extends ChatEvent {
  const ChatReadUpTo(this.seq);

  final int seq;
}

class ChatIdentityChanged extends ChatEvent {
  const ChatIdentityChanged(this.peer, {this.blocksSending = false});

  final PeerAddress peer;

  /// True when the change stopped a message from being sent.
  final bool blocksSending;
}

class ChatIdentityAccepted extends ChatEvent {
  const ChatIdentityAccepted();
}

enum ChatStatus { initial, loading, ready, failure }

class ChatState {
  const ChatState({
    this.status = ChatStatus.initial,
    this.messages = const [],
    this.chat,
    this.changedPeer,
    this.identityChanged = false,
    this.sendingBlocked = false,
    this.uploading = false,
    this.loadingOlder = false,
    this.reachedStart = false,
    this.typingUserIds = const {},
    this.firstUnreadId,
    this.error,
  });

  final ChatStatus status;
  final List<Message> messages;
  final Chat? chat;

  /// The specific device whose identity key changed, if any.
  final PeerAddress? changedPeer;

  /// True when the peer's key changed and the notice has not been dismissed.
  final bool identityChanged;

  /// True when the change blocked the send, i.e. the strict trust policy is
  /// in force. Under the default policy the message went out regardless.
  final bool sendingBlocked;

  /// True while an attachment is being encrypted and uploaded.
  final bool uploading;

  final bool loadingOlder;

  /// Nothing older exists, locally or on the server.
  final bool reachedStart;

  /// Members typing right now.
  final Set<String> typingUserIds;

  /// The first message that was unread when the chat was opened, where the
  /// view starts and draws its divider.
  final String? firstUnreadId;

  final String? error;

  String? get chatId => chat?.id;

  /// Sending is only blocked under the strict trust policy.
  ///
  /// Replacing a phone changes the key, so blocking on every change would make
  /// an ordinary upgrade indistinguishable from an attack -- and would leave
  /// the contact permanently unreachable until both sides act.
  bool get canSend =>
      status == ChatStatus.ready && !(identityChanged && sendingBlocked);

  ChatState copyWith({
    ChatStatus? status,
    List<Message>? messages,
    Chat? chat,
    PeerAddress? changedPeer,
    bool? identityChanged,
    bool? sendingBlocked,
    bool? uploading,
    bool? loadingOlder,
    bool? reachedStart,
    Set<String>? typingUserIds,
    String? firstUnreadId,
    String? error,
  }) =>
      ChatState(
        status: status ?? this.status,
        messages: messages ?? this.messages,
        chat: chat ?? this.chat,
        changedPeer: changedPeer ?? this.changedPeer,
        identityChanged: identityChanged ?? this.identityChanged,
        sendingBlocked: sendingBlocked ?? this.sendingBlocked,
        uploading: uploading ?? this.uploading,
        loadingOlder: loadingOlder ?? this.loadingOlder,
        reachedStart: reachedStart ?? this.reachedStart,
        typingUserIds: typingUserIds ?? this.typingUserIds,
        firstUnreadId: firstUnreadId ?? this.firstUnreadId,
        error: error,
      );
}

class ChatBloc extends Bloc<ChatEvent, ChatState> {
  ChatBloc({
    required MessageRepository repository,
    required CryptoEngine crypto,
    required DeviceResolver resolver,
    AttachmentRepository? attachments,
  })  : _repository = repository,
        _crypto = crypto,
        _resolver = resolver,
        _attachments = attachments,
        super(const ChatState()) {
    on<ChatOpened>(_onOpened);
    on<ChatInfoChanged>((e, emit) => emit(state.copyWith(chat: e.chat)));
    on<ChatMessageSent>(_onSent);
    on<ChatReactionToggled>(_onReaction);
    on<ChatMessageEdited>(_onEdited);
    on<ChatMessageDeleted>(_onDeleted);
    on<ChatRetryRequested>(_onRetry);
    on<ChatMessageForwarded>(_onForwarded);
    on<ChatComposerChanged>(_onComposerChanged);
    on<_ChatTypingSeen>(_onTypingSeen);
    on<ChatOlderRequested>(_onOlder);
    on<ChatMessageReceived>(_onReceived);
    on<ChatMessageRemoved>(_onRemoved);
    on<ChatReadUpTo>(_onReadUpTo);
    on<ChatIdentityChanged>(_onIdentityChanged);
    on<ChatIdentityAccepted>(_onIdentityAccepted);

    _messageSub = _repository.incoming.listen((message) {
      if (message.chatId == state.chatId) add(ChatMessageReceived(message));
    });
    _removedSub = _repository.removed.listen((message) {
      if (message.chatId == state.chatId) add(ChatMessageRemoved(message));
    });
    // Renamed, members changed, a new epoch: the header and the sender
    // names follow.
    _chatSub = _repository.chatUpdates.listen((chatId) async {
      if (chatId != state.chatId) return;
      final chat = await _repository.chat(chatId);
      if (chat != null && !isClosed) add(ChatInfoChanged(chat));
    });
    _typingSub = _repository.typing.listen((notice) {
      if (notice.chatId != state.chatId || isClosed) return;
      add(_ChatTypingSeen(notice.userId, typing: true));
      // A notice holds a few seconds; the next keystrokes renew it.
      _typingTimers[notice.userId]?.cancel();
      _typingTimers[notice.userId] = Timer(const Duration(seconds: 6), () {
        if (!isClosed) add(_ChatTypingSeen(notice.userId, typing: false));
      });
    });
    _readSub = _repository.reads.listen((update) {
      if (update.chatId == state.chatId) add(ChatReadUpTo(update.seq));
    });
    // A device in this conversation changed its key. Usually that means the
    // contact moved to a new phone; it is surfaced either way, and only blocks
    // sending when the alert says the send actually failed.
    _alertSub = _repository.identityAlerts.listen((alert) {
      if (alert.chatId == state.chatId && (state.chat?.isSecret ?? false)) {
        add(ChatIdentityChanged(alert.peer, blocksSending: alert.blocksSending));
      }
    });
  }

  final MessageRepository _repository;
  final CryptoEngine _crypto;
  final DeviceResolver _resolver;
  final AttachmentRepository? _attachments;

  late final StreamSubscription<Message> _messageSub;
  late final StreamSubscription<Message> _removedSub;
  late final StreamSubscription<ReadUpdate> _readSub;
  late final StreamSubscription<String> _chatSub;
  late final StreamSubscription<TypingNotice> _typingSub;
  final Map<String, Timer> _typingTimers = {};
  late final StreamSubscription<IdentityChangeAlert> _alertSub;

  static const _pageSize = 50;

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    emit(state.copyWith(status: ChatStatus.loading, chat: event.chat));

    try {
      // Enough history to reach the first unread message, so the view can
      // start there rather than at the bottom.
      final unread = event.chat.unreadCount;
      final history = await _repository.history(
        event.chat.id,
        limit: unread + 10 > _pageSize ? unread + 10 : _pageSize,
      );
      final incoming = history.where((m) => !m.isOutgoing).toList();
      final firstUnread = unread > 0 && unread <= incoming.length
          ? incoming[incoming.length - unread].id
          : null;
      emit(state.copyWith(
        status: ChatStatus.ready,
        messages: history,
        reachedStart: history.length < _pageSize && event.chat.isSecret,
        firstUnreadId: firstUnread,
      ));
      await _repository.markRead(event.chat.id);
    } catch (e) {
      emit(state.copyWith(status: ChatStatus.failure, error: e.toString()));
    }
  }

  Future<void> _onOlder(ChatOlderRequested event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null || state.loadingOlder || state.reachedStart) return;
    final oldest = state.messages.where((m) => m.seq != null).firstOrNull?.seq;
    if (oldest == null) {
      emit(state.copyWith(reachedStart: true));
      return;
    }

    emit(state.copyWith(loadingOlder: true));
    try {
      final older = await _repository.loadOlder(chatId, oldest, limit: _pageSize);
      final known = {for (final m in state.messages) m.id};
      emit(state.copyWith(
        loadingOlder: false,
        reachedStart: older.isEmpty,
        messages: [...older.where((m) => !known.contains(m.id)), ...state.messages],
      ));
    } catch (e) {
      emit(state.copyWith(loadingOlder: false, error: e.toString()));
    }
  }

  Future<void> _onSent(ChatMessageSent event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;

    final picked = event.attachment;
    if (event.body.trim().isEmpty && picked == null) return;

    try {
      // Upload first: the message carries a reference to the blob, so sending
      // before the upload finishes would point recipients at nothing.
      AttachmentPayload? attachment;
      if (picked != null) {
        emit(state.copyWith(uploading: true));
        final repository = _attachments;
        if (repository == null) {
          throw StateError('attachments are not configured');
        }
        attachment = await repository.upload(
          bytes: picked.bytes,
          mimeType: picked.mimeType,
          fileName: picked.fileName,
        );
        emit(state.copyWith(uploading: false));
      }

      await _repository.send(
        chatId: chatId,
        body: event.body.trim(),
        replyToId: event.replyToId,
        attachment: attachment,
      );
    } on IdentityChangedException {
      // Strict policy only: the send was refused, so sending stays disabled
      // until the user verifies the new safety number.
      emit(state.copyWith(
        uploading: false,
        identityChanged: true,
        sendingBlocked: true,
      ));
    } catch (e) {
      emit(state.copyWith(uploading: false, error: e.toString()));
    }
  }

  Future<void> _onReaction(
    ChatReactionToggled event,
    Emitter<ChatState> emit,
  ) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    try {
      await _repository.react(
        chatId: chatId,
        targetId: event.targetId,
        emoji: event.emoji,
        remove: event.remove,
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> _onEdited(ChatMessageEdited event, Emitter<ChatState> emit) async {
    try {
      await _repository.edit(event.message, event.body.trim());
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> _onDeleted(ChatMessageDeleted event, Emitter<ChatState> emit) async {
    try {
      await _repository.delete(event.message);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> _onForwarded(ChatMessageForwarded event, Emitter<ChatState> emit) async {
    final message = event.message;
    final chat = state.chat;
    final author = message.forwardedFrom ??
        (chat?.member(message.senderId)?.name ??
            (message.isOutgoing ? null : chat?.displayName) ??
            '');
    try {
      await _repository.forward(message, event.toChatId, authorName: author);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  Future<void> _onComposerChanged(ChatComposerChanged event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    if (chatId == null) return;
    if (event.text.trim().isNotEmpty) _repository.typingIn(chatId);
    await _repository.saveDraft(chatId, event.text);
  }

  void _onTypingSeen(_ChatTypingSeen event, Emitter<ChatState> emit) {
    final ids = {...state.typingUserIds};
    if (event.typing) {
      ids.add(event.userId);
    } else {
      ids.remove(event.userId);
    }
    emit(state.copyWith(typingUserIds: ids));
  }

  Future<void> _onRetry(ChatRetryRequested event, Emitter<ChatState> emit) async {
    try {
      await _repository.retry(event.message);
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void _onReceived(ChatMessageReceived event, Emitter<ChatState> emit) {
    final updated = List<Message>.from(state.messages);
    final index = updated.indexWhere((m) => m.id == event.message.id);

    // Replace rather than append when we already know this id: an ack updates
    // an existing row, and a redelivery must not duplicate it.
    if (index >= 0) {
      updated[index] = event.message;
    } else {
      updated.add(event.message);
      if (state.typingUserIds.contains(event.message.senderId)) {
        _typingTimers.remove(event.message.senderId)?.cancel();
        emit(state.copyWith(
          typingUserIds: {...state.typingUserIds}..remove(event.message.senderId),
        ));
      }
      // Seen as it arrives: the chat is open on screen.
      if (!event.message.isOutgoing) {
        final chatId = state.chatId;
        if (chatId != null) unawaited(_repository.markRead(chatId));
      }
    }

    updated.sort((a, b) {
      final aSeq = a.seq;
      final bSeq = b.seq;
      if (aSeq != null && bSeq != null) return aSeq.compareTo(bSeq);
      if (aSeq != null) return -1;
      if (bSeq != null) return 1;
      return a.sentAt.compareTo(b.sentAt);
    });

    emit(state.copyWith(messages: updated));
  }

  void _onRemoved(ChatMessageRemoved event, Emitter<ChatState> emit) {
    emit(state.copyWith(
      messages: state.messages.where((m) => m.id != event.message.id).toList(),
    ));
  }

  void _onReadUpTo(ChatReadUpTo event, Emitter<ChatState> emit) {
    emit(state.copyWith(messages: [
      for (final m in state.messages)
        if (m.isOutgoing &&
            m.seq != null &&
            m.seq! <= event.seq &&
            (m.status == MessageStatus.sent || m.status == MessageStatus.delivered))
          m.copyWith(status: MessageStatus.read)
        else
          m,
    ]));
  }

  void _onIdentityChanged(ChatIdentityChanged event, Emitter<ChatState> emit) {
    emit(state.copyWith(
      identityChanged: true,
      sendingBlocked: event.blocksSending,
      changedPeer: event.peer,
    ));
  }

  Future<void> _onIdentityAccepted(
    ChatIdentityAccepted event,
    Emitter<ChatState> emit,
  ) async {
    final peer = state.changedPeer;
    final peerUsername = state.chat?.peerUsername;
    if (peer == null) {
      emit(state.copyWith(identityChanged: false, sendingBlocked: false));
      return;
    }

    await _crypto.acceptIdentityChange(peer);

    // Drop the cached device list so the next send re-fetches bundles and
    // rebuilds the session against the accepted key.
    if (peerUsername != null) _resolver.invalidate(peerUsername);

    emit(state.copyWith(identityChanged: false, sendingBlocked: false));
  }

  @override
  Future<void> close() async {
    await _messageSub.cancel();
    await _removedSub.cancel();
    await _readSub.cancel();
    await _chatSub.cancel();
    await _typingSub.cancel();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    await _alertSub.cancel();
    return super.close();
  }
}
