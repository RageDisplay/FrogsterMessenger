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
import '../../../ui/widgets/lily_avatar.dart';
import '../../../ui/widgets/pond_nav_bar.dart';

/// Which conversations the list shows.
enum ChatFilter { all, direct, groups, secret }

class ChatListScreen extends StatefulWidget {
  const ChatListScreen({
    super.key,
    required this.chats,
    required this.onOpenChat,
    required this.connection,
    this.selectedChatId,
    this.onNewChat,
    this.onOpenSettings,
  });

  final List<Chat> chats;
  final void Function(Chat chat) onOpenChat;
  final SocketState connection;

  /// Highlighted in two-pane layouts so the user can see which conversation
  /// the detail pane is showing.
  final String? selectedChatId;

  final VoidCallback? onNewChat;
  final VoidCallback? onOpenSettings;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  var _filter = ChatFilter.all;

  List<Chat> get _visible => switch (_filter) {
        ChatFilter.all => widget.chats,
        ChatFilter.direct => widget.chats.where((c) => !c.isGroup).toList(),
        ChatFilter.groups => widget.chats.where((c) => c.isGroup).toList(),
        ChatFilter.secret => widget.chats.where((c) => c.isSecret).toList(),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = _visible;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(connection: widget.connection),
            if (widget.chats.isNotEmpty)
              _Filters(
                selected: _filter,
                onSelected: (f) => setState(() => _filter = f),
              ),
            Expanded(
              child: widget.chats.isEmpty
                  ? _EmptyState(
                      title: l10n.emptyChatsTitle,
                      body: l10n.emptyChatsBody,
                    )
                  : visible.isEmpty
                      ? _EmptyState(title: l10n.filterEmpty)
                      : _ChatBlock(
                          chats: visible,
                          selectedChatId: widget.selectedChatId,
                          onOpenChat: widget.onOpenChat,
                        ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: PondNavBar(
        onNewChat: widget.onNewChat,
        onOpenSettings: widget.onOpenSettings,
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.connection});

  final SocketState connection;

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
class _ChatBlock extends StatelessWidget {
  const _ChatBlock({
    required this.chats,
    required this.selectedChatId,
    required this.onOpenChat,
  });

  final List<Chat> chats;
  final String? selectedChatId;
  final void Function(Chat chat) onOpenChat;

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
  });

  final Chat chat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    final hasUnread = chat.unreadCount > 0;
    final preview = switch (chat.lastMessagePreview) {
      PreviewTokens.photo => l10n.previewPhoto,
      PreviewTokens.file => l10n.previewFile,
      final text => text ?? '',
    };

    return Material(
      color: selected ? pond.accentSoft : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              LilyAvatar(
                seed: chat.peerUsername ?? chat.id,
                label: chat.displayName,
                icon: chat.isGroup ? Icons.groups_rounded : null,
                secret: chat.isSecret,
              ),
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
                          child: Text(
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
                          _UnreadBadge(count: chat.unreadCount),
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
  const _UnreadBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: pond.accent,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: pond.onAccent,
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
