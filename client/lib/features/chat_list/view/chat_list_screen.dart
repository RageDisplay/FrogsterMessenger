/// The list of conversations.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../data/repositories/message_repository.dart';
import '../../../data/remote/ws_client.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/brand_mark.dart';
import '../../../ui/widgets/avatars.dart';
import '../../../ui/widgets/pond_nav_bar.dart';

/// Which conversations the list shows.
enum ChatFilter { all, direct, groups, secret }

/// What a chat row's menu offers.
enum ChatAction { togglePin, toggleMute, toggleArchive, delete }

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.chats,
    required this.onOpenChat,
    required this.connection,
    this.selectedChatId,
    this.onNewChat,
    this.onOpenSettings,
    this.onChatAction,
    this.onOpenArchive,
    this.onSearch,
    this.archive = false,
  });

  /// Every chat this device has; the screen picks which to show.
  final List<Chat> chats;
  final void Function(Chat chat) onOpenChat;
  final SocketState connection;

  /// Highlighted in two-pane layouts so the user can see which conversation
  /// the detail pane is showing.
  final String? selectedChatId;

  final VoidCallback? onNewChat;
  final VoidCallback? onOpenSettings;

  /// Pin, mute, archive or delete, chosen from a row's menu.
  final void Function(Chat chat, ChatAction action)? onChatAction;

  /// Opens the archived chats.
  final VoidCallback? onOpenArchive;

  /// Opens search across chats and messages.
  final VoidCallback? onSearch;

  /// Shows the archive instead of the main list.
  final bool archive;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  var _filter = ChatFilter.all;

  /// The chats of this list: the archive, or everything not in it.
  List<Chat> get _listed => widget.chats
      .where((c) => !c.hidden && c.archived == widget.archive)
      .toList();

  List<Chat> get _archived =>
      widget.chats.where((c) => !c.hidden && c.archived).toList();

  List<Chat> get _visible {
    final listed = _listed;
    return switch (_filter) {
      ChatFilter.all => listed,
      ChatFilter.direct => listed.where((c) => !c.isGroup).toList(),
      ChatFilter.groups => listed.where((c) => c.isGroup).toList(),
      ChatFilter.secret => listed.where((c) => c.isSecret).toList(),
    };
  }

  Future<void> _showChatMenu(Chat chat) async {
    final handler = widget.onChatAction;
    if (handler == null) return;
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final action = await showModalBottomSheet<ChatAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(chat.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
              title: Text(chat.pinned ? l10n.chatUnpin : l10n.chatPin),
              onTap: () => Navigator.of(sheetContext).pop(ChatAction.togglePin),
            ),
            ListTile(
              leading: Icon(chat.muted
                  ? Icons.notifications_active_outlined
                  : Icons.notifications_off_outlined),
              title: Text(chat.muted ? l10n.chatUnmute : l10n.chatMute),
              onTap: () => Navigator.of(sheetContext).pop(ChatAction.toggleMute),
            ),
            ListTile(
              leading: Icon(chat.archived ? Icons.unarchive_outlined : Icons.archive_outlined),
              title: Text(chat.archived ? l10n.chatUnarchive : l10n.chatArchive),
              onTap: () => Navigator.of(sheetContext).pop(ChatAction.toggleArchive),
            ),
            ListTile(
              leading: Icon(
                chat.isGroup ? Icons.logout_rounded : Icons.delete_outline_rounded,
                color: pond.danger,
              ),
              title: Text(
                chat.isGroup ? l10n.leaveGroup : l10n.deleteChat,
                style: TextStyle(color: pond.danger),
              ),
              onTap: () => Navigator.of(sheetContext).pop(ChatAction.delete),
            ),
          ],
        ),
      ),
    );
    if (action != null) handler(chat, action);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = _visible;
    final listed = _listed;
    final archived = widget.archive ? const <Chat>[] : _archived;

    return Scaffold(
      appBar: widget.archive
          ? AppBar(
              title: Text(l10n.archiveTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!widget.archive) _Header(connection: widget.connection, onSearch: widget.onSearch),
            if (listed.isNotEmpty)
              _Filters(
                selected: _filter,
                onSelected: (f) => setState(() => _filter = f),
              ),
            if (archived.isNotEmpty)
              _ArchiveRow(count: archived.length, onTap: widget.onOpenArchive),
            Expanded(
              child: listed.isEmpty
                  ? _EmptyState(
                      title: widget.archive ? l10n.filterEmpty : l10n.emptyChatsTitle,
                      body: widget.archive ? null : l10n.emptyChatsBody,
                    )
                  : visible.isEmpty
                      ? _EmptyState(title: l10n.filterEmpty)
                      : _ChatBlock(
                          chats: visible,
                          selectedChatId: widget.selectedChatId,
                          onOpenChat: widget.onOpenChat,
                          onLongPress: _showChatMenu,
                        ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: widget.archive
          ? null
          : PondNavBar(
              onNewChat: widget.onNewChat,
              onOpenSettings: widget.onOpenSettings,
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.connection, this.onSearch});

  final SocketState connection;
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
      child: Row(
        children: [
          const BrandMark(size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.chatsTitle,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.6,
              ),
            ),
          ),
          ConnectionChip(state: connection),
          if (onSearch != null) ...[
            const SizedBox(width: 4),
            IconButton(
              tooltip: l10n.search,
              onPressed: onSearch,
              icon: const Icon(Icons.search_rounded),
            ),
          ],
        ],
      ),
    );
  }
}

/// A compact connection indicator: "online", "connecting…", "offline".
class ConnectionChip extends StatelessWidget {
  const ConnectionChip({super.key, required this.state});

  final SocketState state;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    final (background, foreground, dot, label) = switch (state) {
      SocketState.connected =>
        (pond.mintSoft, pond.onMintSoft, pond.mint, l10n.connectionSecure),
      SocketState.connecting =>
        (pond.lilyRaised, pond.inkMuted, pond.inkMuted, l10n.connectionConnecting),
      SocketState.disconnected =>
        (pond.dangerSoft, pond.danger, pond.danger, l10n.connectionOffline),
    };

    final chip = Semantics(
      liveRegion: true,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );

    // Offline explains itself on hover or long press.
    return state == SocketState.disconnected
        ? Tooltip(message: l10n.connectionOfflineHint, child: chip)
        : chip;
  }
}

class _Filters extends StatelessWidget {
  const _Filters({required this.selected, required this.onSelected});

  final ChatFilter selected;
  final ValueChanged<ChatFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    Widget chip(ChatFilter filter, String label) {
      final active = filter == selected;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Material(
          color: active ? pond.ink : pond.lilyRaised,
          borderRadius: BorderRadius.circular(PondRadii.chip),
          child: InkWell(
            borderRadius: BorderRadius.circular(PondRadii.chip),
            onTap: () => onSelected(filter),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w600,
                  color: active ? pond.pond : pond.inkMuted,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // Scrolls sideways rather than wrapping: four labels do not fit a narrow
    // phone in every language.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(20, 0, 14, 12),
      child: Row(
        children: [
          chip(ChatFilter.all, l10n.filterAll),
          chip(ChatFilter.direct, l10n.filterDirect),
          chip(ChatFilter.groups, l10n.filterGroups),
          chip(ChatFilter.secret, l10n.filterSecret),
        ],
      ),
    );
  }
}

/// All conversations on one card, separated by hairlines.
/// The way into the archive, above the list.
class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({required this.count, this.onTap});

  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Material(
        color: pond.lily,
        borderRadius: BorderRadius.circular(PondRadii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(PondRadii.control),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                Icon(Icons.archive_outlined, size: 20, color: pond.inkMuted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(l10n.archiveTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
                Text('$count', style: TextStyle(color: pond.inkMuted, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatBlock extends StatelessWidget {
  const _ChatBlock({
    required this.chats,
    required this.selectedChatId,
    required this.onOpenChat,
    this.onLongPress,
  });

  final List<Chat> chats;
  final String? selectedChatId;
  final void Function(Chat chat) onOpenChat;
  final void Function(Chat chat)? onLongPress;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(PondRadii.card),
        ),
        child: ColoredBox(
          color: pond.lily,
          child: ListView.separated(
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: chats.length,
            separatorBuilder: (_, _) => Padding(
              padding: const EdgeInsets.only(left: 74),
              child: Divider(height: 1, color: pond.outline),
            ),
            itemBuilder: (context, index) {
              final chat = chats[index];
              return _ChatRow(
                chat: chat,
                selected: chat.id == selectedChatId,
                onTap: () => onOpenChat(chat),
                onLongPress: onLongPress == null ? null : () => onLongPress!(chat),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    required this.chat,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final Chat chat;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    final hasUnread = chat.unreadCount > 0;
    final preview = switch (chat.lastMessagePreview) {
      PreviewTokens.photo => l10n.previewPhoto,
      PreviewTokens.file => l10n.previewFile,
      PreviewTokens.voice => l10n.previewVoice,
      final text => text ?? '',
    };

    return Material(
      color: selected ? pond.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              ChatAvatar(chat: chat),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (chat.isSecret) ...[
                          Icon(Icons.lock_rounded, size: 13, color: pond.mint),
                          const SizedBox(width: 4),
                        ],
                        Expanded(
                          child: Text(
                            chat.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                              color: chat.isSecret ? pond.mint : null,
                            ),
                          ),
                        ),
                        if (chat.muted) ...[
                          Icon(Icons.notifications_off_outlined, size: 14, color: pond.inkMuted),
                          const SizedBox(width: 4),
                        ],
                        if (chat.lastMessageAt != null)
                          Text(
                            formatListStamp(context, chat.lastMessageAt!),
                            style: TextStyle(
                              fontSize: 12,
                              color: hasUnread ? pond.accent : pond.inkMuted,
                              fontWeight:
                                  hasUnread ? FontWeight.w700 : FontWeight.w500,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: chat.draft.trim().isNotEmpty
                              ? Text.rich(
                                  TextSpan(children: [
                                    TextSpan(
                                      text: '${l10n.draftPrefix} ',
                                      style: TextStyle(color: pond.danger, fontWeight: FontWeight.w600),
                                    ),
                                    TextSpan(text: chat.draft.trim().replaceAll('\n', ' ')),
                                  ]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 14, color: pond.inkMuted),
                                )
                              : Text(
                                  preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: hasUnread ? pond.ink : pond.inkMuted,
                                  ),
                                ),
                        ),
                        if (hasUnread) ...[
                          const SizedBox(width: 8),
                          _UnreadBadge(count: chat.unreadCount, muted: chat.muted),
                        ] else if (chat.pinned) ...[
                          const SizedBox(width: 8),
                          Icon(Icons.push_pin_rounded, size: 15, color: pond.inkMuted),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, this.muted = false});

  final int count;

  /// A muted chat's badge is grey: still counted, not calling for attention.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: muted ? pond.inkMuted : pond.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: muted ? pond.pond : pond.onAccent,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, this.body});

  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(size: 44, color: pond.outline),
            const SizedBox(height: 16),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: pond.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
