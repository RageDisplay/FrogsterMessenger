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
  const ChatOpened(this.chatId, this.peerUsername);

  final String chatId;

  /// Addressing is by username: the peer may own several devices, and the
  /// repository resolves them all at send time.
  final String peerUsername;
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

/// A message arrived or changed state.
class ChatMessageReceived extends ChatEvent {
  const ChatMessageReceived(this.message);

  final Message message;
}

class ChatIdentityChanged extends ChatEvent {
  const ChatIdentityChanged(this.peer);

  final PeerAddress peer;
}

class ChatIdentityAccepted extends ChatEvent {
  const ChatIdentityAccepted();
}

enum ChatStatus { initial, loading, ready, failure }

class ChatState {
  const ChatState({
    this.status = ChatStatus.initial,
    this.messages = const [],
    this.chatId,
    this.peerUsername,
    this.changedPeer,
    this.identityChanged = false,
    this.uploading = false,
    this.error,
  });

  final ChatStatus status;
  final List<Message> messages;
  final String? chatId;
  final String? peerUsername;

  /// The specific device whose identity key changed, if any.
  final PeerAddress? changedPeer;

  /// True when the peer's key changed and sending is blocked pending the
  /// user's decision.
  final bool identityChanged;

  /// True while an attachment is being encrypted and uploaded.
  final bool uploading;

  final String? error;

  /// Sending is disabled while a key change is unresolved: proceeding would
  /// hand plaintext to whoever supplied the new key.
  bool get canSend => status == ChatStatus.ready && !identityChanged;

  ChatState copyWith({
    ChatStatus? status,
    List<Message>? messages,
    String? chatId,
    String? peerUsername,
    PeerAddress? changedPeer,
    bool? identityChanged,
    bool? uploading,
    String? error,
  }) =>
      ChatState(
        status: status ?? this.status,
        messages: messages ?? this.messages,
        chatId: chatId ?? this.chatId,
        peerUsername: peerUsername ?? this.peerUsername,
        changedPeer: changedPeer ?? this.changedPeer,
        identityChanged: identityChanged ?? this.identityChanged,
        uploading: uploading ?? this.uploading,
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
    on<ChatMessageSent>(_onSent);
    on<ChatReactionToggled>(_onReaction);
    on<ChatMessageReceived>(_onReceived);
    on<ChatIdentityChanged>(_onIdentityChanged);
    on<ChatIdentityAccepted>(_onIdentityAccepted);

    _messageSub = _repository.incoming.listen((message) {
      if (message.chatId == state.chatId) {
        add(ChatMessageReceived(message));
      }
    });
    // Any device in this conversation changing its key blocks sending: we
    // cannot tell which device the user is really talking to until they check.
    _alertSub = _repository.identityAlerts.listen((alert) {
      if (alert.chatId == state.chatId) {
        add(ChatIdentityChanged(alert.peer));
      }
    });
  }

  final MessageRepository _repository;
  final CryptoEngine _crypto;
  final DeviceResolver _resolver;
  final AttachmentRepository? _attachments;

  late final StreamSubscription<Message> _messageSub;
  late final StreamSubscription<IdentityChangeAlert> _alertSub;

  Future<void> _onOpened(ChatOpened event, Emitter<ChatState> emit) async {
    emit(state.copyWith(
      status: ChatStatus.loading,
      chatId: event.chatId,
      peerUsername: event.peerUsername,
    ));

    try {
      final history = await _repository.history(event.chatId);
      await _repository.markRead(event.chatId);

      emit(state.copyWith(status: ChatStatus.ready, messages: history));
    } catch (e) {
      emit(state.copyWith(status: ChatStatus.failure, error: e.toString()));
    }
  }

  Future<void> _onSent(ChatMessageSent event, Emitter<ChatState> emit) async {
    final chatId = state.chatId;
    final peerUsername = state.peerUsername;
    if (chatId == null || peerUsername == null) return;

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

      await _repository.sendDirect(
        chatId: chatId,
        peerUsername: peerUsername,
        body: event.body.trim(),
        replyToId: event.replyToId,
        attachment: attachment,
      );
    } on IdentityChangedException {
      emit(state.copyWith(uploading: false, identityChanged: true));
    } catch (e) {
      emit(state.copyWith(uploading: false, error: e.toString()));
    }
  }

  Future<void> _onReaction(
    ChatReactionToggled event,
    Emitter<ChatState> emit,
  ) async {
    final chatId = state.chatId;
    final peerUsername = state.peerUsername;
    if (chatId == null || peerUsername == null) return;

    try {
      await _repository.sendReaction(
        chatId: chatId,
        peerUsername: peerUsername,
        targetId: event.targetId,
        emoji: event.emoji,
        remove: event.remove,
      );
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

  void _onIdentityChanged(ChatIdentityChanged event, Emitter<ChatState> emit) {
    emit(state.copyWith(identityChanged: true, changedPeer: event.peer));
  }

  Future<void> _onIdentityAccepted(
    ChatIdentityAccepted event,
    Emitter<ChatState> emit,
  ) async {
    final peer = state.changedPeer;
    final peerUsername = state.peerUsername;
    if (peer == null) return;

    await _crypto.acceptIdentityChange(peer);

    // Drop the cached device list so the next send re-fetches bundles and
    // rebuilds the session against the accepted key.
    if (peerUsername != null) _resolver.invalidate(peerUsername);

    emit(state.copyWith(identityChanged: false));
  }

  @override
  Future<void> close() async {
    await _messageSub.cancel();
    await _alertSub.cancel();
    return super.close();
  }
}
