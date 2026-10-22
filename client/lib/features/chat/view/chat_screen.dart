/// The conversation view.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/lily_avatar.dart';
import '../bloc/chat_bloc.dart';
import '../widgets/attachment_view.dart';
import '../widgets/message_bubble.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.selfUserId,
    this.onBack,
    this.onShowSafetyNumber,
    this.onOpenInfo,
    this.onPickAttachment,
    this.onDownloadAttachment,
    this.onOpenAttachment,
  });

  /// The signed-in user, to tell our reactions and messages apart.
  final String? selfUserId;

  /// Opens the group's details: members, name, leaving.
  final VoidCallback? onOpenInfo;

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

  /// The message being edited, when the composer is in edit mode.
  Message? _editing;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  /// Asks for older messages as the top of what is loaded comes into view.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= 200) {
      context.read<ChatBloc>().add(const ChatOlderRequested());
    }
  }

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

    final editing = _editing;
    if (editing != null) {
      if (text.isNotEmpty && text != editing.body) {
        context.read<ChatBloc>().add(ChatMessageEdited(editing, text));
      }
      _composer.clear();
      setState(() => _editing = null);
      return;
    }

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
          SnackBar(
            content: Text(AppLocalizations.of(context).couldNotReadFile('$e')),
          ),
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

  void _startEditing(Message message) {
    setState(() => _editing = message);
    _composer.text = message.body;
    _composer.selection = TextSelection.collapsed(offset: message.body.length);
  }

  void _cancelEditing() {
    setState(() => _editing = null);
    _composer.clear();
  }

  /// The actions a message offers, with quick reactions on top.
  Future<void> _showActions(BuildContext context, Message message) async {
    final bloc = context.read<ChatBloc>();
    final chat = bloc.state.chat;
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final canDelete = message.isOutgoing ||
        ((chat?.isGroup ?? false) && (chat?.isAdmin ?? false));

    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.seq != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final emoji in MessageBubble.quickReactions)
                        InkResponse(
                          radius: 26,
                          onTap: () => Navigator.of(sheetContext).pop('react:$emoji'),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Text(emoji, style: const TextStyle(fontSize: 28)),
                          ),
                        ),
                    ],
                  ),
                ),
              if (message.body.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: Text(l10n.actionCopy),
                  onTap: () => Navigator.of(sheetContext).pop('copy'),
                ),
              if (message.status == MessageStatus.failed)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: Text(l10n.actionRetry),
                  onTap: () => Navigator.of(sheetContext).pop('retry'),
                ),
              if (message.isOutgoing && message.seq != null && message.body.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: Text(l10n.actionEdit),
                  onTap: () => Navigator.of(sheetContext).pop('edit'),
                ),
              if (canDelete)
                ListTile(
                  leading: Icon(Icons.delete_outline_rounded, color: pond.danger),
                  title: Text(l10n.actionDelete, style: TextStyle(color: pond.danger)),
                  onTap: () => Navigator.of(sheetContext).pop('delete'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    if (action.startsWith('react:')) {
      final emoji = action.substring('react:'.length);
      final mine = message.reactions[emoji]?.contains(widget.selfUserId) ?? false;
      bloc.add(ChatReactionToggled(message.id, emoji, mine));
    } else if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: message.body));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l10n.textCopied)));
      }
    } else if (action == 'retry') {
      bloc.add(ChatRetryRequested(message));
    } else if (action == 'edit') {
      _startEditing(message);
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(l10n.deleteMessageTitle),
          content: Text(l10n.deleteMessageBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: pond.danger),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.delete),
            ),
          ],
        ),
      );
      if (confirmed ?? false) bloc.add(ChatMessageDeleted(message));
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
      // New messages at the bottom scroll into view; older ones loaded at the
      // top must not yank the view away from what the user is reading.
      listenWhen: (previous, current) =>
          previous.messages.length != current.messages.length &&
          (previous.messages.isEmpty ||
              current.messages.isEmpty ||
              previous.messages.last.id != current.messages.last.id),
      listener: (context, state) => _scrollToBottom(),
      builder: (context, state) {
        final chat = state.chat;
        return Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (chat != null)
                  _Header(
                    chat: chat,
                    onBack: widget.onBack,
                    // Only a secret direct chat has one safety number to
                    // compare; elsewhere there is nothing to verify.
                    onShowSafetyNumber:
                        chat.isSecret && !chat.isGroup ? widget.onShowSafetyNumber : null,
                    onOpenInfo: chat.isGroup ? widget.onOpenInfo : null,
                  ),
                if (state.identityChanged)
                  _IdentityChangeBanner(blocksSending: state.sendingBlocked),
                Expanded(child: _buildBody(context, state)),
                if (_staged != null)
                  _StagedAttachment(
                    attachment: _staged!,
                    onRemove: () => setState(() => _staged = null),
                  ),
                if (_editing != null)
                  _EditingBar(message: _editing!, onCancel: _cancelEditing),
                _Composer(
                  controller: _composer,
                  enabled: state.canSend,
                  onSend: () => _send(context),
                  onAttach: widget.onPickAttachment == null ||
                          _uploading ||
                          _editing != null
                      ? null
                      : _pickAttachment,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, ChatState state) {
    if (state.status == ChatStatus.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final l10n = AppLocalizations.of(context);
    if (state.status == ChatStatus.failure) {
      return Center(child: Text(state.error ?? l10n.couldNotLoad));
    }
    if (state.messages.isEmpty) {
      return Center(
        child: Text(
          l10n.noMessages,
          style: TextStyle(color: context.pond.inkMuted),
        ),
      );
    }

    final chat = state.chat;
    final offset = state.loadingOlder ? 1 : 0;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: state.messages.length + offset,
      itemBuilder: (context, rawIndex) {
        if (rawIndex < offset) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final index = rawIndex - offset;
        final message = state.messages[index];
        final previous = index == 0 ? null : state.messages[index - 1];
        // In a group, each run of messages from one person carries their
        // name once.
        final showName = (chat?.isGroup ?? false) &&
            !message.isOutgoing &&
            (previous == null ||
                previous.senderId != message.senderId ||
                !isSameDay(previous.sentAt, message.sentAt));
        final bubble = MessageBubble(
          message: message,
          selfUserId: widget.selfUserId,
          senderName: showName
              ? (chat?.member(message.senderId)?.name ?? message.senderId.substring(0, 8))
              : null,
          onActions: () => _showActions(context, message),
          onRetry: () => context.read<ChatBloc>().add(ChatRetryRequested(message)),
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
        if (previous != null && isSameDay(previous.sentAt, message.sentAt)) {
          return bubble;
        }
        return Column(
          children: [
            _DayChip(label: formatDayLabel(context, message.sentAt)),
            bubble,
          ],
        );
      },
    );
  }
}

/// The header: back, the chat, and what can be checked or opened about it.
class _Header extends StatelessWidget {
  const _Header({
    required this.chat,
    this.onBack,
    this.onShowSafetyNumber,
    this.onOpenInfo,
  });

  final Chat chat;
  final VoidCallback? onBack;
  final VoidCallback? onShowSafetyNumber;
  final VoidCallback? onOpenInfo;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    final subtitle = switch ((chat.isGroup, chat.isSecret)) {
      (true, true) => l10n.secretGroupSubtitle(chat.members.length),
      (true, false) => l10n.membersCount(chat.members.length),
      (false, true) => l10n.secretChatSubtitle,
      (false, false) => chat.peerUsername == null ? '' : '@${chat.peerUsername}',
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: pond.outline)),
      ),
      child: Row(
        children: [
          if (onBack != null) ...[
            IconButton(
              tooltip: l10n.back,
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 2),
          ] else
            const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: onOpenInfo,
              borderRadius: BorderRadius.circular(PondRadii.control),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    LilyAvatar(
                      seed: chat.peerUsername ?? chat.id,
                      label: chat.displayName,
                      icon: chat.isGroup ? Icons.groups_rounded : null,
                      secret: chat.isSecret,
                      size: 40,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chat.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Row(
                            children: [
                              if (chat.isSecret) ...[
                                Icon(Icons.lock_rounded, size: 11, color: pond.mint),
                                const SizedBox(width: 4),
                              ],
                              Flexible(
                                child: Text(
                                  subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: chat.isSecret ? pond.mint : pond.inkMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (onShowSafetyNumber != null)
            _RoundButton(
              tooltip: l10n.safetyNumberTooltip,
              icon: Icons.verified_user_outlined,
              onPressed: onShowSafetyNumber,
              tinted: true,
            ),
          if (onOpenInfo != null)
            _RoundButton(
              tooltip: l10n.groupInfo,
              icon: Icons.info_outline_rounded,
              onPressed: onOpenInfo,
            ),
        ],
      ),
    );
  }
}

/// Shown above the composer while a message is being edited.
class _EditingBar extends StatelessWidget {
  const _EditingBar({required this.message, required this.onCancel});

  final Message message;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: pond.accentSoft,
        borderRadius: BorderRadius.circular(PondRadii.control),
      ),
      child: Row(
        children: [
          Icon(Icons.edit_outlined, size: 18, color: pond.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.editingMessage,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: pond.accent,
                  ),
                ),
                Text(
                  message.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: pond.onAccentSoft),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.cancel,
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.tinted = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      style: IconButton.styleFrom(
        backgroundColor: pond.lilyRaised,
        foregroundColor: tinted ? pond.accent : pond.ink,
        fixedSize: const Size(40, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
        ),
      ),
      icon: Icon(icon, size: 19),
    );
  }
}

class _DayChip extends StatelessWidget {
  const _DayChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 8),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          color: pond.inkMuted,
        ),
      ),
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
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    // Two different events wear the same words otherwise. Blocking means we
    // refused to send; the informational form means the conversation carried
    // on and the user is being told why the safety number moved.
    final background = blocksSending ? pond.dangerSoft : pond.night;
    final foreground = blocksSending ? pond.danger : pond.onNight;
    final accent = blocksSending ? pond.danger : pond.mint;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(PondRadii.card),
          border: Border.all(color: pond.outline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  blocksSending
                      ? Icons.gpp_maybe_rounded
                      : Icons.info_outline_rounded,
                  color: accent,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    blocksSending
                        ? l10n.identityChangedBlocking
                        : l10n.identityChangedInfo,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: accent),
              onPressed: () =>
                  context.read<ChatBloc>().add(const ChatIdentityAccepted()),
              child: Text(blocksSending ? l10n.iVerifiedIt : l10n.gotIt),
            ),
          ],
        ),
      ),
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
    final pond = context.pond;

    return Container(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: pond.lily,
        borderRadius: BorderRadius.circular(PondRadii.control),
        border: Border.all(color: pond.outline),
      ),
      child: Row(
        children: [
          Icon(Icons.image_outlined, size: 20, color: pond.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              attachment.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).removeAttachment,
            onPressed: onRemove,
            icon: const Icon(Icons.close_rounded, size: 20),
          ),
        ],
      ),
    );
  }
}

/// The composer: attach, the text field, send.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
    this.onAttach,
  });

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final VoidCallback? onAttach;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    final square = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PondRadii.control),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          IconButton(
            tooltip: l10n.attach,
            onPressed: enabled ? onAttach : null,
            style: IconButton.styleFrom(
              backgroundColor: pond.lilyRaised,
              foregroundColor: pond.accent,
              fixedSize: const Size(46, 46),
              shape: square,
            ),
            icon: const Icon(Icons.attach_file_rounded, size: 21),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => enabled ? onSend() : null,
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: enabled ? l10n.messagePlaceholder : l10n.verifyToSend,
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: l10n.send,
            onPressed: enabled ? onSend : null,
            style: IconButton.styleFrom(
              backgroundColor: pond.accent,
              foregroundColor: pond.onAccent,
              disabledBackgroundColor: pond.lilyRaised,
              fixedSize: const Size(46, 46),
              shape: square,
            ),
            icon: const Icon(Icons.arrow_upward_rounded, size: 21),
          ),
        ],
      ),
    );
  }
}
