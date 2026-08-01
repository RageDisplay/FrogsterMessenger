/// The conversation view.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/models/models.dart';
import '../bloc/chat_bloc.dart';
import '../widgets/attachment_view.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.title,
    this.onBack,
    this.onShowSafetyNumber,
    this.onPickAttachment,
    this.onDownloadAttachment,
    this.onOpenAttachment,
  });

  final String title;

  /// Opens the file picker and returns the chosen file, or null if cancelled.
  final Future<PickedAttachment?> Function()? onPickAttachment;

  /// Fetches and decrypts an attachment.
  final Future<Uint8List> Function(AttachmentPayload)? onDownloadAttachment;

  /// Hands decrypted bytes to the platform to open.
  final void Function(AttachmentPayload, Uint8List)? onOpenAttachment;

  /// Closes the conversation. Supplied in narrow layouts, where the chat
  /// covers the list; in two-pane layouts the list stays visible and no back
  /// affordance is needed.
  final VoidCallback? onBack;

  final VoidCallback? onShowSafetyNumber;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// A file chosen by the user, before encryption.
class PickedAttachment {
  const PickedAttachment({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// Per-attachment download state, keyed by blob id.
  ///
  /// Held here rather than in the bloc because it is view state: it does not
  /// survive leaving the conversation, and nothing outside this screen needs
  /// to know how far a download has got.
  final _downloads = <String, _DownloadState>{};

  /// The file staged for sending, shown above the composer until sent.
  PickedAttachment? _staged;
  var _uploading = false;

  @override
  void dispose() {
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send(BuildContext context) {
    final text = _composer.text.trim();
    final staged = _staged;

    // A message needs either text or a file; an empty send is a no-op.
    if (text.isEmpty && staged == null) return;

    context.read<ChatBloc>().add(ChatMessageSent(text, attachment: staged));
    _composer.clear();
    setState(() => _staged = null);
    _scrollToBottom();
  }

  Future<void> _pickAttachment() async {
    final picker = widget.onPickAttachment;
    if (picker == null) return;

    setState(() => _uploading = true);
    try {
      final picked = await picker();
      if (picked != null && mounted) setState(() => _staged = picked);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not read the file: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// Fetches and decrypts an attachment on demand.
  ///
  /// Downloads are explicit rather than automatic: fetching every attachment
  /// as it arrives would spend the user's mobile data for them, and would tell
  /// a network observer exactly which messages carried files.
  Future<void> _download(AttachmentPayload attachment) async {
    final downloader = widget.onDownloadAttachment;
    if (downloader == null) return;

    setState(() {
      _downloads[attachment.blobId] =
          const _DownloadState(state: AttachmentState.downloading);
    });

    try {
      final bytes = await downloader(attachment);
      if (!mounted) return;
      setState(() {
        _downloads[attachment.blobId] = _DownloadState(
          state: AttachmentState.ready,
          bytes: bytes,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _downloads[attachment.blobId] = _DownloadState(
          state: AttachmentState.failed,
          // Surfaced verbatim: a digest mismatch means the blob was altered,
          // and the user should see that rather than a generic failure.
          error: e is Exception ? e.toString().split(': ').last : 'Failed',
        );
      });
    }
  }

  void _scrollToBottom() {
    // Deferred: the new message has not been laid out yet when the event is
    // dispatched, so the max extent is still the old one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (previous, current) =>
          previous.messages.length != current.messages.length,
      listener: (context, state) => _scrollToBottom(),
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.title),
            leading: widget.onBack == null
                ? null
                : BackButton(onPressed: widget.onBack),
            actions: [
              IconButton(
                tooltip: 'Safety number',
                onPressed: widget.onShowSafetyNumber,
                icon: const Icon(Icons.verified_user_outlined),
              ),
            ],
          ),
          body: Column(
            children: [
              if (state.identityChanged)
                _IdentityChangeBanner(blocksSending: state.sendingBlocked),
              Expanded(child: _buildBody(context, state)),
              if (_staged != null)
                _StagedAttachment(
                  attachment: _staged!,
                  onRemove: () => setState(() => _staged = null),
                ),
              _Composer(
                controller: _composer,
                enabled: state.canSend,
                onSend: () => _send(context),
                onAttach: widget.onPickAttachment == null || _uploading
                    ? null
                    : _pickAttachment,
                hasStagedFile: _staged != null,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ChatState state) {
    if (state.status == ChatStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.status == ChatStatus.failure) {
      return Center(child: Text(state.error ?? 'Could not load messages'));
    }
    if (state.messages.isEmpty) {
      return const Center(child: Text('No messages yet'));
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.messages.length,
      itemBuilder: (context, index) {
        final message = state.messages[index];
        return MessageBubble(
          message: message,
          onReact: (emoji, remove) => context.read<ChatBloc>().add(
                ChatReactionToggled(message.id, emoji, remove),
              ),
          attachmentBuilder: (attachment) {
            final download = _downloads[attachment.blobId] ??
                const _DownloadState(state: AttachmentState.idle);

            return AttachmentView(
              attachment: attachment,
              state: download.state,
              decrypted: download.bytes,
              error: download.error,
              outgoing: message.isOutgoing,
              onDownload: () => _download(attachment),
              onOpen: download.bytes == null
                  ? null
                  : () => widget.onOpenAttachment
                      ?.call(attachment, download.bytes!),
            );
          },
        );
      },
    );
  }
}

/// Blocks sending until the user decides what to do about a changed key.
///
/// This is deliberately intrusive. A silent re-pin would hide exactly the
/// event that a key-substitution attack produces.
class _IdentityChangeBanner extends StatelessWidget {
  const _IdentityChangeBanner({required this.blocksSending});

  /// True under the strict trust policy, where the message was refused.
  final bool blocksSending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    // Two different events wear the same words otherwise. Blocking means we
    // refused to send; the informational form means the conversation carried
    // on and the user is being told why the safety number moved.
    final background =
        blocksSending ? scheme.errorContainer : scheme.secondaryContainer;
    final foreground =
        blocksSending ? scheme.onErrorContainer : scheme.onSecondaryContainer;

    return MaterialBanner(
      backgroundColor: background,
      leading: Icon(
        blocksSending ? Icons.gpp_maybe : Icons.info_outline,
        color: foreground,
      ),
      content: Text(
        blocksSending
            ? 'This contact\'s safety number has changed. They may have '
                'reinstalled the app — or someone may be intercepting your '
                'messages. Verify before sending.'
            : 'This contact\'s safety number has changed, usually because they '
                'switched to a new device. Your messages are still encrypted. '
                'Verify the number if you want to be certain.',
        style: TextStyle(color: foreground),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              context.read<ChatBloc>().add(const ChatIdentityAccepted()),
          child: Text(blocksSending ? 'I verified it' : 'Got it'),
        ),
      ],
    );
  }
}

/// View state for one attachment download.
class _DownloadState {
  const _DownloadState({required this.state, this.bytes, this.error});

  final AttachmentState state;
  final Uint8List? bytes;
  final String? error;
}

/// The file waiting to be sent, with a way to change your mind.
class _StagedAttachment extends StatelessWidget {
  const _StagedAttachment({required this.attachment, required this.onRemove});

  final PickedAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.attach_file, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              attachment.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: 'Remove',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            onPressed: onRemove,
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
    this.onAttach,
    this.hasStagedFile = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback? onAttach;

  /// A staged file makes the send button live even with an empty text field.
  final bool hasStagedFile;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              tooltip: 'Attach photo',
              onPressed: enabled ? onAttach : null,
              icon: const Icon(Icons.attach_file),
            ),
            Expanded(
              child: TextField(
                controller: controller,
                enabled: enabled,
                minLines: 1,
                maxLines: 5,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => enabled ? onSend() : null,
                decoration: InputDecoration(
                  hintText: enabled ? 'Message' : 'Verify the contact to send',
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: enabled ? onSend : null,
              icon: const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }
}
