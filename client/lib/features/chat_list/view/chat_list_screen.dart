/// The list of conversations.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../data/remote/ws_client.dart';

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({
    super.key,
    required this.chats,
    required this.onOpenChat,
    required this.connection,
    this.selectedChatId,
    this.onNewChat,
    this.onOpenSettings,
    this.showAppBar = true,
  });

  final List<Chat> chats;
  final void Function(Chat chat) onOpenChat;
  final SocketState connection;

  /// Highlighted in two-pane layouts so the user can see which conversation
  /// the detail pane is showing.
  final String? selectedChatId;

  final VoidCallback? onNewChat;
  final VoidCallback? onOpenSettings;

  /// Suppressed when embedded as the list pane of a two-pane layout, which
  /// supplies its own header.
  final bool showAppBar;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: showAppBar
          ? AppBar(
              title: const Text('Frogster'),
              actions: [
                IconButton(
                  tooltip: 'Settings',
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            )
          : null,
      body: Column(
        children: [
          if (connection != SocketState.connected)
            _ConnectionBanner(state: connection),
          Expanded(
            child: chats.isEmpty
                ? const _EmptyState()
                : ListView.separated(
                    itemCount: chats.length,
                    separatorBuilder: (_, _) => const Divider(indent: 72),
                    itemBuilder: (context, index) {
                      final chat = chats[index];
                      return _ChatTile(
                        chat: chat,
                        selected: chat.id == selectedChatId,
                        onTap: () => onOpenChat(chat),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: onNewChat == null
          ? null
          : FloatingActionButton(
              onPressed: onNewChat,
              child: const Icon(Icons.add_comment_outlined),
            ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.chat,
    required this.selected,
    required this.onTap,
  });

  final Chat chat;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      selected: selected,
      selectedTileColor: scheme.secondaryContainer,
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: chat.isGroup
            ? Icon(Icons.groups_outlined, color: scheme.onPrimaryContainer)
            : Text(
                _initials(chat.displayName),
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
      ),
      title: Text(
        chat.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: chat.lastMessagePreview == null
          ? null
          : Text(
              chat.lastMessagePreview!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (chat.lastMessageAt != null)
            Text(
              _formatRelative(chat.lastMessageAt!),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          if (chat.unreadCount > 0) ...[
            const SizedBox(height: 4),
            Badge(label: Text('${chat.unreadCount}')),
          ],
        ],
      ),
    );
  }

  static String _initials(String name) =>
      name.isEmpty ? '?' : name.substring(0, 1).toUpperCase();

  /// Time for today, weekday for this week, date beyond that -- so the column
  /// stays narrow and scannable.
  static String _formatRelative(DateTime time) {
    final local = time.toLocal();
    final now = DateTime.now();
    final elapsed = now.difference(local);

    if (elapsed.inDays == 0 && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    if (elapsed.inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[local.weekday - 1];
    }
    return '${local.day}/${local.month}';
  }
}

/// Shows why messages may not be arriving, instead of leaving the list
/// silently stale.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.state});

  final SocketState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final connecting = state == SocketState.connecting;

    return Container(
      width: double.infinity,
      color: connecting ? scheme.secondaryContainer : scheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: connecting
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Icon(Icons.cloud_off,
                    size: 16, color: scheme.onErrorContainer),
          ),
          const SizedBox(width: 12),
          Text(
            connecting ? 'Connecting…' : 'Offline — messages will send later',
            style: TextStyle(
              color: connecting
                  ? scheme.onSecondaryContainer
                  : scheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 16),
          Text('No conversations yet',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Start one with the button below',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
