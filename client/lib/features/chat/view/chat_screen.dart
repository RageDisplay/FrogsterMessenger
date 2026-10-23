/// The conversation view.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/audio/voice_player.dart';
import '../../../data/audio/voice_recording.dart';
import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/avatars.dart';
import '../attachments.dart';
import '../bloc/chat_bloc.dart';
import '../widgets/attachment_view.dart';
import '../widgets/message_bubble.dart';
import '../../voice/voice_channels.dart';
import '../../voice/voice_scope.dart';
import '../widgets/voice_message_view.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.selfUserId,
    this.onBack,
    this.onShowSafetyNumber,
    this.onOpenInfo,
    this.onPickForwardTarget,
    this.onPickAttachment,
    this.onDownloadAttachment,
    this.onOpenAttachment,
    this.onSaveAttachment,
    this.cachedAttachment,
    this.voicePlayer,
    this.startRecording,
  });

  /// The signed-in user, to tell our reactions and messages apart.
  final String? selfUserId;

  /// Opens the group's details: members, name, leaving.
  final VoidCallback? onOpenInfo;

  /// Asks which chat to forward a message to.
  final Future<Chat?> Function()? onPickForwardTarget;

  /// Opens a picker and returns the chosen files; empty if cancelled.
  final Future<List<PickedAttachment>> Function(AttachSource source)? onPickAttachment;

  /// Fetches and decrypts an attachment.
  final Future<Uint8List> Function(AttachmentPayload, void Function(double fraction) onProgress)?
      onDownloadAttachment;

  /// Hands decrypted bytes to the platform to open.
  final void Function(AttachmentPayload, Uint8List)? onOpenAttachment;

  /// Asks where to keep a decrypted file and saves it there.
  final void Function(AttachmentPayload, Uint8List)? onSaveAttachment;

  /// A file already fetched, if there is one: shown without a round trip.
  final Uint8List? Function(AttachmentPayload)? cachedAttachment;

  /// Plays voice messages, one at a time across the app.
  final VoicePlayer? voicePlayer;

  /// Starts recording a voice message from the chosen microphone.
  final Future<VoiceRecording> Function()? startRecording;

  /// Closes the conversation. Supplied in narrow layouts, where the chat
  /// covers the list; in two-pane layouts the list stays visible and no back
  /// affordance is needed.
  final VoidCallback? onBack;

  final VoidCallback? onShowSafetyNumber;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _composer = TextEditingController();
  final _scroll = ScrollController();

  /// The message being edited, when the composer is in edit mode.
  Message? _editing;

  /// The message being answered.
  Message? _replyTo;

  /// Lets the view jump to a message: the first unread one, or a quoted one.
  final _keys = <String, GlobalKey>{};
  GlobalKey _keyFor(String id) => _keys.putIfAbsent(id, GlobalKey.new);

  var _draftRestored = false;
  var _jumpedToUnread = false;
  Timer? _draftTimer;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _composer.addListener(_onComposerText);
  }

  var _composerEmpty = true;

  /// The send button turns into a microphone while there is nothing to send.
  void _onComposerText() {
    final empty = _composer.text.trim().isEmpty;
    if (empty != _composerEmpty) setState(() => _composerEmpty = empty);
  }

  VoiceRecording? _recording;

  /// Held down rather than tapped: letting go sends.
  var _holding = false;

  /// The microphone button is under a finger right now.
  var _pressing = false;

  Future<void> _startRecording({required bool hold}) async {
    final start = widget.startRecording;
    if (start == null || _recording != null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    HapticFeedback.mediumImpact();
    widget.voicePlayer?.stop();
    try {
      final recording = await start();
      if (!mounted) {
        await recording.cancel();
        return;
      }
      setState(() {
        _recording = recording;
        // Let go before the microphone was ready: that was a tap after all,
        // and the recording carries on until sent or thrown away.
        _holding = hold && _pressing;
      });
    } on RecordingException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.problem == RecordingProblem.permission ? l10n.micPermission : l10n.micFailed),
      ));
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    final recording = _recording;
    if (recording == null) return;
    final bloc = context.read<ChatBloc>();
    final replyTo = _replyTo?.id;
    setState(() {
      _recording = null;
      _holding = false;
      if (send) _replyTo = null;
    });
    if (!send) {
      await recording.cancel();
      recording.dispose();
      return;
    }
    final clip = await recording.finish();
    recording.dispose();
    if (clip == null) return; // too short to be a message
    bloc.add(ChatMessageSent('', replyToId: replyTo, attachments: [
      PickedAttachment(
        bytes: clip.ogg,
        mimeType: 'audio/ogg',
        fileName: 'voice.ogg',
        voice: true,
        durationMs: clip.duration.inMilliseconds,
        waveform: clip.waveform,
      ),
    ]));
    _scrollToBottom();
  }

  /// Asks for older messages as the top of what is loaded comes into view.
  /// The list runs bottom-up, so the top is the far end of the scroll.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - 300) {
      context.read<ChatBloc>().add(const ChatOlderRequested());
    }
  }

  /// Keeps the draft and tells the others we type, without writing to the
  /// database on every keystroke.
  void _onComposerChanged(String text) {
    if (_editing != null) return;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), () {
      if (mounted) context.read<ChatBloc>().add(ChatComposerChanged(text));
    });
  }

  void _jumpTo(String messageId) {
    final target = _keys[messageId]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      alignment: 0.5,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// First time the conversation is ready: put the draft back, and start
  /// at the first unread message rather than the bottom.
  void _onReady(ChatState state) {
    if (!_draftRestored) {
      _draftRestored = true;
      final draft = state.chat?.draft ?? '';
      if (draft.isNotEmpty && _composer.text.isEmpty) _composer.text = draft;
    }
    final firstUnread = state.firstUnreadId;
    if (!_jumpedToUnread && firstUnread != null) {
      _jumpedToUnread = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _keys[firstUnread]?.currentContext;
        if (target != null) Scrollable.ensureVisible(target, alignment: 0.9);
      });
    }
  }

  String _authorOf(Message message, Chat? chat, AppLocalizations l10n) {
    if (message.isOutgoing) return l10n.you;
    return chat?.member(message.senderId)?.name ?? chat?.displayName ?? '';
  }

  String _snippet(Message message, AppLocalizations l10n) {
    if (message.body.isNotEmpty) return message.body;
    final attachment = message.attachment;
    if (attachment == null) return l10n.replyUnknown;
    return attachment.isImage ? l10n.previewPhoto : (attachment.fileName ?? l10n.previewFile);
  }

  Future<void> _forward(BuildContext context, Message message) async {
    final picker = widget.onPickForwardTarget;
    if (picker == null) return;
    final bloc = context.read<ChatBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final target = await picker();
    if (target == null) return;
    bloc.add(ChatMessageForwarded(message, target.id));
    messenger.showSnackBar(SnackBar(content: Text(l10n.forwardedDone(target.displayName))));
  }

  /// Per-attachment download state, keyed by blob id.
  ///
  /// Held here rather than in the bloc because it is view state: it does not
  /// survive leaving the conversation, and nothing outside this screen needs
  /// to know how far a download has got.
  final _downloads = <String, _DownloadState>{};

  /// Files staged for sending, shown above the composer until sent.
  var _staged = <PickedAttachment>[];
  var _picking = false;

  @override
  void dispose() {
    // A draft typed in the last moments before leaving is kept too.
    if (_draftTimer?.isActive ?? false) {
      _draftTimer!.cancel();
      if (_editing == null) context.read<ChatBloc>().add(ChatComposerChanged(_composer.text));
    }
    final recording = _recording;
    if (recording != null) recording.cancel().then((_) => recording.dispose());
    _composer.removeListener(_onComposerText);
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
    if (text.isEmpty && staged.isEmpty) return;

    context.read<ChatBloc>().add(
          ChatMessageSent(text, attachments: staged, replyToId: _replyTo?.id),
        );
    _draftTimer?.cancel();
    _composer.clear();
    setState(() {
      _staged = [];
      _replyTo = null;
    });
    _scrollToBottom();
  }

  /// Asks where the file comes from, then lets the user pick it.
  Future<void> _pickAttachment() async {
    final picker = widget.onPickAttachment;
    if (picker == null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final source = await showModalBottomSheet<AttachSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: Text(l10n.attachGallery),
                onTap: () => Navigator.of(sheetContext).pop(AttachSource.gallery),
              ),
              if (AttachmentPicker.hasCamera)
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: Text(l10n.attachCamera),
                  onTap: () => Navigator.of(sheetContext).pop(AttachSource.camera),
                ),
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: Text(l10n.attachFile),
                subtitle: Text(l10n.attachFileHint),
                onTap: () => Navigator.of(sheetContext).pop(AttachSource.file),
              ),
            ],
          ),
        ),
      ),
    );
    if (source == null || !mounted) return;

    setState(() => _picking = true);
    try {
      final picked = await picker(source);
      if (picked.isNotEmpty && mounted) setState(() => _staged = [..._staged, ...picked]);
    } on PickRejected catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.fileTooLargeNamed(e.fileName))));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.couldNotReadFile('$e'))));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Photos come in by themselves; anything else waits for a tap.
  void _maybeAutoDownload(AttachmentPayload attachment) {
    if (!attachment.isImage ||
        attachment.isUploading ||
        attachment.size > autoDownloadImageBytes ||
        _downloads.containsKey(attachment.blobId)) {
      return;
    }
    // Not during build: starting a download changes state.
    _downloads[attachment.blobId] = const _DownloadState(state: AttachmentState.downloading);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _download(attachment);
    });
  }

  void _openAttachment(AttachmentPayload attachment, Uint8List bytes) {
    if (attachment.isImage) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => ImageViewer(
          bytes: bytes,
          title: attachment.fileName,
          onSave: widget.onSaveAttachment == null
              ? null
              : () => widget.onSaveAttachment!(attachment, bytes),
        ),
      ));
      return;
    }
    widget.onOpenAttachment?.call(attachment, bytes);
  }

  /// Decrypted bytes on hand for an attachment: downloaded in this screen,
  /// or kept from earlier.
  Uint8List? _bytesOf(AttachmentPayload attachment) =>
      _downloads[attachment.blobId]?.bytes ?? widget.cachedAttachment?.call(attachment);

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
      var shown = 0.0;
      final bytes = await downloader(attachment, (fraction) {
        // A redraw per percent is plenty.
        if (!mounted || fraction - shown < 0.01) return;
        shown = fraction;
        setState(() {
          _downloads[attachment.blobId] =
              _DownloadState(state: AttachmentState.downloading, progress: fraction);
        });
      });
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

  void _startReply(Message message) {
    setState(() {
      _editing = null;
      _replyTo = message;
    });
  }

  void _startEditing(Message message) {
    setState(() {
      _editing = message;
      _replyTo = null;
    });
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
    final attachment = message.attachment;
    final saveable = attachment == null ? null : _bytesOf(attachment);

    final action = await showModalBottomSheet<String>(
      context: context,
      // Taller than a landscape phone: it scrolls rather than cutting off
      // the actions at the bottom.
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
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
              if (message.seq != null)
                ListTile(
                  leading: const Icon(Icons.reply_rounded),
                  title: Text(l10n.actionReply),
                  onTap: () => Navigator.of(sheetContext).pop('reply'),
                ),
              if (message.seq != null && widget.onPickForwardTarget != null)
                ListTile(
                  leading: const Icon(Icons.shortcut_rounded),
                  title: Text(l10n.actionForward),
                  onTap: () => Navigator.of(sheetContext).pop('forward'),
                ),
              if (message.body.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: Text(l10n.actionCopy),
                  onTap: () => Navigator.of(sheetContext).pop('copy'),
                ),
              if (message.seq != null)
                ListTile(
                  leading: const Icon(Icons.check_circle_outline_rounded),
                  title: Text(l10n.actionSelect),
                  onTap: () => Navigator.of(sheetContext).pop('select'),
                ),
              if (saveable != null && widget.onSaveAttachment != null)
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: Text(l10n.saveFile),
                  onTap: () => Navigator.of(sheetContext).pop('save'),
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
    } else if (action == 'select') {
      setState(() => _selection = {message.id});
    } else if (action == 'reply') {
      _startReply(message);
    } else if (action == 'forward') {
      if (context.mounted) await _forward(context, message);
    } else if (action == 'save') {
      widget.onSaveAttachment?.call(attachment!, saveable!);
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

  /// Messages picked to act on together; empty outside selection mode.
  var _selection = <String>{};

  bool _canDelete(Message m, Chat? chat) =>
      m.isOutgoing || ((chat?.isGroup ?? false) && (chat?.isAdmin ?? false));

  void _toggleSelected(Message m) {
    if (m.seq == null) return;
    setState(() {
      final next = {..._selection};
      if (!next.remove(m.id)) next.add(m.id);
      _selection = next;
    });
  }

  /// The selected messages, oldest first, as the conversation shows them.
  List<Message> _selected(ChatState state) =>
      [for (final m in state.messages) if (_selection.contains(m.id)) m];

  Future<void> _copySelected(ChatState state) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final chat = state.chat;
    final text = [
      for (final m in _selected(state))
        if (m.body.isNotEmpty)
          (chat?.isGroup ?? false) ? '${_authorOf(m, chat, l10n)}: ${m.body}' : m.body,
    ].join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    setState(() => _selection = {});
    messenger.showSnackBar(SnackBar(content: Text(l10n.textCopied)));
  }

  Future<void> _forwardSelected(ChatState state) async {
    final picker = widget.onPickForwardTarget;
    if (picker == null) return;
    final bloc = context.read<ChatBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final messages = _selected(state);
    final target = await picker();
    if (target == null) return;
    for (final m in messages) {
      bloc.add(ChatMessageForwarded(m, target.id));
    }
    if (mounted) setState(() => _selection = {});
    messenger.showSnackBar(SnackBar(content: Text(l10n.forwardedDone(target.displayName))));
  }

  Future<void> _deleteSelected(ChatState state) async {
    final bloc = context.read<ChatBloc>();
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final messages = _selected(state);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteMessagesTitle(messages.length)),
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
    if (!(confirmed ?? false)) return;
    for (final m in messages) {
      bloc.add(ChatMessageDeleted(m));
    }
    if (mounted) setState(() => _selection = {});
  }

  /// The list runs bottom-up, so the newest message is at offset zero.
  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<ChatBloc, ChatState>(
      listenWhen: (previous, current) =>
          previous.status != ChatStatus.ready && current.status == ChatStatus.ready,
      listener: (context, state) => _onReady(state),
      builder: (context, state) {
        final chat = state.chat;
        final l10n = AppLocalizations.of(context);
        final typing = state.typingUserIds;
        final typingText = typing.isEmpty
            ? null
            : !(chat?.isGroup ?? false)
                ? l10n.typing
                : typing.length > 1
                    ? l10n.typingSeveral
                    : l10n.typingNamed(chat?.member(typing.first)?.name ?? '');
        // Gone from the conversation, e.g. deleted elsewhere: unselected.
        final present = {for (final m in state.messages) m.id};
        if (_selection.any((id) => !present.contains(id))) {
          _selection = _selection.where(present.contains).toSet();
        }
        final selecting = _selection.isNotEmpty;
        final selected = selecting ? _selected(state) : const <Message>[];
        return PopScope(
          // Back leaves selection before it leaves the chat.
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && selecting) setState(() => _selection = {});
          },
          child: Scaffold(
          body: SafeArea(
            child: Column(
              children: [
                if (selecting)
                  _SelectionBar(
                    count: _selection.length,
                    onCancel: () => setState(() => _selection = {}),
                    onCopy: selected.any((m) => m.body.isNotEmpty) ? () => _copySelected(state) : null,
                    onForward: widget.onPickForwardTarget == null ? null : () => _forwardSelected(state),
                    onDelete: selected.every((m) => _canDelete(m, chat)) ? () => _deleteSelected(state) : null,
                  )
                else if (chat != null)
                  _Header(
                    chat: chat,
                    onBack: widget.onBack,
                    // Only a secret direct chat has one safety number to
                    // compare; elsewhere there is nothing to verify.
                    onShowSafetyNumber:
                        chat.isSecret && !chat.isGroup ? widget.onShowSafetyNumber : null,
                    onOpenInfo: chat.isGroup ? widget.onOpenInfo : null,
                    typing: typingText,
                  ),
                if (chat != null && chat.isGroup && chat.isCloud)
                  Builder(builder: (context) {
                    final voice = VoiceScope.of(context);
                    return voice == null
                        ? const SizedBox.shrink()
                        : VoiceChannelsPanel(chat: chat, controller: voice);
                  }),
                if (state.identityChanged)
                  _IdentityChangeBanner(blocksSending: state.sendingBlocked),
                Expanded(child: _buildBody(context, state)),
                if (_staged.isNotEmpty)
                  _StagedAttachments(
                    attachments: _staged,
                    onRemove: (file) => setState(
                      () => _staged = _staged.where((f) => !identical(f, file)).toList(),
                    ),
                  ),
                if (_editing != null)
                  _EditingBar(message: _editing!, onCancel: _cancelEditing),
                if (_replyTo != null)
                  _ReplyBar(
                    author: _authorOf(_replyTo!, chat, l10n),
                    text: _snippet(_replyTo!, l10n),
                    onCancel: () => setState(() => _replyTo = null),
                  ),
                if (_recording != null)
                  _RecordingBar(
                    recording: _recording!,
                    holding: _holding,
                    onCancel: () => _finishRecording(send: false),
                    onSend: () => _finishRecording(send: true),
                  )
                else
                _Composer(
                  controller: _composer,
                  onMicTap: _composerEmpty && _staged.isEmpty && _editing == null && widget.startRecording != null && state.canSend
                      ? () => _startRecording(hold: false)
                      : null,
                  onMicHoldStart: () {
                    _pressing = true;
                    _startRecording(hold: true);
                  },
                  onMicHoldEnd: () {
                    _pressing = false;
                    if (_holding) _finishRecording(send: true);
                  },
                  onMicHoldCancel: () {
                    _pressing = false;
                    if (_holding) _finishRecording(send: false);
                  },
                  enabled: state.canSend,
                  onChanged: _onComposerChanged,
                  onSend: () => _send(context),
                  onAttach: widget.onPickAttachment == null ||
                          _picking ||
                          _editing != null
                      ? null
                      : _pickAttachment,
                ),
              ],
            ),
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
    final messages = state.messages;
    final byId = {for (final m in messages) m.id: m};
    final extra = state.loadingOlder ? 1 : 0;

    // Bottom-up: index 0 is the newest message. The view opens at the
    // bottom without scrolling there, and older pages grow at the far end.
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      scrollCacheExtent: const ScrollCacheExtent.pixels(2000),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: messages.length + extra,
      itemBuilder: (context, rawIndex) {
        if (rawIndex >= messages.length) {
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
        final index = messages.length - 1 - rawIndex;
        final message = messages[index];
        final previous = index == 0 ? null : messages[index - 1];
        // In a group, each run of messages from one person carries their
        // name once.
        final showName = (chat?.isGroup ?? false) &&
            !message.isOutgoing &&
            (previous == null ||
                previous.senderId != message.senderId ||
                !isSameDay(previous.sentAt, message.sentAt));
        final replied = message.replyToId == null ? null : byId[message.replyToId];
        final bubble = MessageBubble(
          message: message,
          selfUserId: widget.selfUserId,
          senderName: showName
              ? (chat?.member(message.senderId)?.name ?? message.senderId.substring(0, 8))
              : null,
          quote: message.replyToId == null
              ? null
              : (
                  author: replied == null ? l10n.replyUnknown : _authorOf(replied, chat, l10n),
                  text: replied == null ? '…' : _snippet(replied, l10n),
                ),
          onTapQuote: replied == null ? null : () => _jumpTo(replied.id),
          onActions: () => _showActions(context, message),
          onRetry: () => context.read<ChatBloc>().add(ChatRetryRequested(message)),
          onReact: (emoji, remove) => context.read<ChatBloc>().add(
                ChatReactionToggled(message.id, emoji, remove),
              ),
          attachmentBuilder: (attachment) {
            final player = widget.voicePlayer;
            if (attachment.voice && player != null) {
              return VoiceMessageView(
                attachment: attachment,
                player: player,
                outgoing: message.isOutgoing,
                uploadProgress: state.uploads[message.id],
                load: () async =>
                    _bytesOf(attachment) ??
                    await widget.onDownloadAttachment!(attachment, (_) {}),
              );
            }
            final bytes = _bytesOf(attachment);
            if (bytes == null) _maybeAutoDownload(attachment);
            final download = _downloads[attachment.blobId] ??
                const _DownloadState(state: AttachmentState.idle);

            return AttachmentView(
              attachment: attachment,
              state: bytes != null ? AttachmentState.ready : download.state,
              decrypted: bytes,
              progress: download.progress,
              uploadProgress: state.uploads[message.id],
              error: download.error,
              outgoing: message.isOutgoing,
              onDownload: () => _download(attachment),
              onOpen: bytes == null ? null : () => _openAttachment(attachment, bytes),
              onSave: bytes == null || widget.onSaveAttachment == null
                  ? null
                  : () => widget.onSaveAttachment!(attachment, bytes),
            );
          },
        );
        final selecting = _selection.isNotEmpty;
        final Widget swipeable;
        if (selecting) {
          // While selecting, a tap picks the message instead of acting on it.
          final picked = _selection.contains(message.id);
          swipeable = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _toggleSelected(message),
            child: Container(
              color: picked ? context.pond.accentSoft : null,
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Icon(
                      picked ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 22,
                      color: picked ? context.pond.accent : context.pond.inkMuted,
                    ),
                  ),
                  Expanded(child: AbsorbPointer(child: bubble)),
                ],
              ),
            ),
          );
        } else {
          swipeable = message.seq == null
              ? bubble
              : _SwipeToReply(onReply: () => _startReply(message), child: bubble);
        }
        final newDay = previous == null || !isSameDay(previous.sentAt, message.sentAt);
        final unreadStart = message.id == state.firstUnreadId;
        return KeyedSubtree(
          key: _keyFor(message.id),
          child: Column(
            children: [
              if (newDay) _DayChip(label: formatDayLabel(context, message.sentAt)),
              if (unreadStart) _UnreadDivider(label: l10n.unreadDivider),
              swipeable,
            ],
          ),
        );
      },
    );
  }
}

/// Drag a message to the right to answer it, as on a phone.
class _SwipeToReply extends StatefulWidget {
  const _SwipeToReply({required this.onReply, required this.child});

  final VoidCallback onReply;
  final Widget child;

  @override
  State<_SwipeToReply> createState() => _SwipeToReplyState();
}

class _SwipeToReplyState extends State<_SwipeToReply> {
  static const _trigger = 56.0;
  var _dx = 0.0;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return GestureDetector(
      onHorizontalDragUpdate: (d) => setState(() => _dx = (_dx + d.delta.dx).clamp(0, 80)),
      onHorizontalDragEnd: (_) {
        if (_dx >= _trigger) {
          HapticFeedback.selectionClick();
          widget.onReply();
        }
        setState(() => _dx = 0);
      },
      onHorizontalDragCancel: () => setState(() => _dx = 0),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          if (_dx > 8)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Opacity(
                opacity: (_dx / _trigger).clamp(0, 1),
                child: Icon(Icons.reply_rounded, color: pond.accent),
              ),
            ),
          AnimatedContainer(
            duration: Duration(milliseconds: _dx == 0 ? 180 : 0),
            transform: Matrix4.translationValues(_dx, 0, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}

class _UnreadDivider extends StatelessWidget {
  const _UnreadDivider({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(vertical: 5),
      color: pond.accentSoft,
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: pond.accent,
        ),
      ),
    );
  }
}

/// Replaces the header while messages are selected.
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onCancel,
    this.onCopy,
    this.onForward,
    this.onDelete,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback? onCopy;
  final VoidCallback? onForward;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: pond.accentSoft,
        border: Border(bottom: BorderSide(color: pond.outline)),
      ),
      child: Row(
        children: [
          IconButton(tooltip: l10n.cancel, onPressed: onCancel, icon: const Icon(Icons.close_rounded)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              l10n.selectedCount(count),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pond.onAccentSoft),
            ),
          ),
          if (onCopy != null)
            IconButton(tooltip: l10n.actionCopy, onPressed: onCopy, icon: const Icon(Icons.copy_rounded)),
          if (onForward != null)
            IconButton(tooltip: l10n.actionForward, onPressed: onForward, icon: const Icon(Icons.shortcut_rounded)),
          if (onDelete != null)
            IconButton(
              tooltip: l10n.actionDelete,
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline_rounded, color: pond.danger),
            ),
        ],
      ),
    );
  }
}

/// Shown above the composer while answering a message.
class _ReplyBar extends StatelessWidget {
  const _ReplyBar({required this.author, required this.text, required this.onCancel});

  final String author;
  final String text;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
      padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
      decoration: BoxDecoration(
        color: pond.lily,
        borderRadius: BorderRadius.circular(PondRadii.control),
        border: Border.all(color: pond.outline),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 18, color: pond.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.replyingTo(author),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: pond.accent),
                ),
                Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: pond.inkMuted),
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

/// The header: back, the chat, and what can be checked or opened about it.
class _Header extends StatelessWidget {
  const _Header({
    required this.chat,
    this.onBack,
    this.onShowSafetyNumber,
    this.onOpenInfo,
    this.typing,
  });

  final Chat chat;
  final VoidCallback? onBack;
  final VoidCallback? onShowSafetyNumber;
  final VoidCallback? onOpenInfo;

  /// Replaces the subtitle while someone types.
  final String? typing;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    final peer = peerOf(chat, AvatarScope.of(context)?.selfUserId);
    final subtitle = typing ?? switch ((chat.isGroup, chat.isSecret)) {
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
                    ChatAvatar(chat: chat, size: 40, showPresence: false),
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
                                child: typing == null && peer != null
                                    // A direct chat says whether the other
                                    // person is around.
                                    ? PresenceLine(
                                        userId: peer.userId,
                                        fallback: subtitle,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: chat.isSecret ? pond.mint : pond.inkMuted,
                                        ),
                                      )
                                    : Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: typing != null
                                              ? pond.accent
                                              : chat.isSecret ? pond.mint : pond.inkMuted,
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
  const _DownloadState({required this.state, this.bytes, this.error, this.progress = 0});

  final AttachmentState state;
  final double progress;
  final Uint8List? bytes;
  final String? error;
}

/// The files waiting to be sent, each with a way to change your mind.
class _StagedAttachments extends StatelessWidget {
  const _StagedAttachments({required this.attachments, required this.onRemove});

  final List<PickedAttachment> attachments;
  final ValueChanged<PickedAttachment> onRemove;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    return Container(
      height: 92,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final file = attachments[index];
          return Stack(
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: pond.lily,
                  borderRadius: BorderRadius.circular(PondRadii.control),
                  border: Border.all(color: pond.outline),
                ),
                clipBehavior: Clip.antiAlias,
                child: file.isImage
                    ? Image.memory(file.bytes, fit: BoxFit.cover, cacheWidth: 200)
                    : Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.insert_drive_file_outlined, color: pond.accent),
                            const SizedBox(height: 6),
                            Text(
                              file.fileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: IconButton.filled(
                  tooltip: l10n.removeAttachment,
                  onPressed: () => onRemove(file),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(26, 26),
                    fixedSize: const Size(26, 26),
                    padding: EdgeInsets.zero,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 16),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
/// Replaces the composer while a voice message is recorded.
class _RecordingBar extends StatelessWidget {
  const _RecordingBar({
    required this.recording,
    required this.holding,
    required this.onCancel,
    required this.onSend,
  });

  final VoiceRecording recording;
  final bool holding;
  final VoidCallback onCancel;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
      child: Row(
        children: [
          IconButton(
            tooltip: l10n.voiceDiscard,
            onPressed: onCancel,
            icon: Icon(Icons.delete_outline_rounded, color: pond.danger),
          ),
          const SizedBox(width: 4),
          Icon(Icons.fiber_manual_record_rounded, color: pond.danger, size: 14),
          const SizedBox(width: 6),
          ValueListenableBuilder<Duration>(
            valueListenable: recording.elapsed,
            builder: (_, d, _) => Text(
              '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: holding
                ? Text(
                    l10n.voiceSlideToCancel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pond.inkMuted),
                  )
                : ValueListenableBuilder<double>(
                    valueListenable: recording.level,
                    builder: (_, level, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: level,
                        minHeight: 6,
                        color: pond.accent,
                        backgroundColor: pond.lilyRaised,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 8),
          if (!holding)
            IconButton(
              tooltip: l10n.send,
              onPressed: onSend,
              style: IconButton.styleFrom(
                backgroundColor: pond.accent,
                foregroundColor: pond.onAccent,
                fixedSize: const Size(46, 46),
              ),
              icon: const Icon(Icons.arrow_upward_rounded, size: 21),
            )
          else
            Icon(Icons.mic_rounded, color: pond.accent, size: 28),
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
    this.onChanged,
    this.onAttach,
    this.onMicTap,
    this.onMicHoldStart,
    this.onMicHoldEnd,
    this.onMicHoldCancel,
  });

  /// Set when there is nothing to send: the send button is a microphone.
  final VoidCallback? onMicTap;
  final VoidCallback? onMicHoldStart;
  final VoidCallback? onMicHoldEnd;
  final VoidCallback? onMicHoldCancel;

  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onSend;
  final ValueChanged<String>? onChanged;
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
              onChanged: onChanged,
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
          if (onMicTap != null)
            GestureDetector(
              onLongPressStart: (_) => onMicHoldStart?.call(),
              onLongPressEnd: (_) => onMicHoldEnd?.call(),
              // Sliding away from the button throws the recording away.
              onLongPressMoveUpdate: (d) {
                if (d.offsetFromOrigin.dx < -90) onMicHoldCancel?.call();
              },
              child: IconButton(
                tooltip: l10n.voiceRecord,
                onPressed: onMicTap,
                style: IconButton.styleFrom(
                  backgroundColor: pond.accent,
                  foregroundColor: pond.onAccent,
                  fixedSize: const Size(46, 46),
                  shape: square,
                ),
                icon: const Icon(Icons.mic_rounded, size: 22),
              ),
            )
          else
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
