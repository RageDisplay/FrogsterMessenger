/// A single message bubble with its reactions and delivery state.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../ui/theme/app_theme.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onReact,
    this.showSender = false,
    this.attachmentBuilder,
  });

  final Message message;

  /// Called with the chosen emoji and whether it should be removed.
  final void Function(String emoji, bool remove) onReact;

  /// Group chats show who sent each message; direct chats do not need to.
  final bool showSender;

  /// Renders the attachment, if any. Injected so the bubble stays a pure
  /// widget: download state and decryption belong to the screen above it.
  final Widget Function(AttachmentPayload attachment)? attachmentBuilder;

  static const _quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🎉'];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outgoing = message.isOutgoing;

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        // Full-width bubbles are hard to read; cap them so long messages wrap
        // into a comfortable measure on wide windows.
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.72,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          child: Column(
            crossAxisAlignment:
                outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onLongPress: () => _showReactionPicker(context),
                child: Material(
                  color: outgoing
                      ? scheme.outgoingBubble
                      : scheme.incomingBubble,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(outgoing ? 18 : 4),
                    bottomRight: Radius.circular(outgoing ? 4 : 18),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (showSender && !outgoing)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              message.senderId,
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: scheme.primary),
                            ),
                          ),
                        if (message.attachment != null) ...[
                          attachmentBuilder?.call(message.attachment!) ??
                              const SizedBox.shrink(),
                          if (message.body.isNotEmpty)
                            const SizedBox(height: 6),
                        ],
                        if (message.body.isNotEmpty)
                          Text(
                            message.body,
                            style: TextStyle(
                              color: outgoing
                                  ? scheme.onOutgoingBubble
                                  : scheme.onIncomingBubble,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _formatTime(message.sentAt),
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    color: (outgoing
                                            ? scheme.onOutgoingBubble
                                            : scheme.onIncomingBubble)
                                        .withValues(alpha: 0.6),
                                  ),
                            ),
                            if (outgoing) ...[
                              const SizedBox(width: 4),
                              _StatusIcon(status: message.status),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (message.reactions.isNotEmpty)
                _ReactionRow(
                  reactions: message.reactions,
                  onTap: (emoji, mine) => onReact(emoji, mine),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showReactionPicker(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 12,
            children: [
              for (final emoji in _quickReactions)
                IconButton(
                  iconSize: 32,
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    onReact(emoji, false);
                  },
                  icon: Text(emoji, style: const TextStyle(fontSize: 28)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _ReactionRow extends StatelessWidget {
  const _ReactionRow({required this.reactions, required this.onTap});

  final Map<String, Set<String>> reactions;
  final void Function(String emoji, bool alreadyReacted) onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 4,
        children: [
          // Material wraps the InkWell: an ink response needs a Material
          // ancestor to paint its splash, and the bubble above is a sibling
          // rather than a parent here.
          for (final entry in reactions.entries)
            Material(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              child: InkWell(
                onTap: () => onTap(entry.key, false),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text('${entry.key} ${entry.value.length}',
                      style: Theme.of(context).textTheme.labelSmall),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status});

  final MessageStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final (icon, color) = switch (status) {
      MessageStatus.pending => (Icons.schedule, scheme.onSurfaceVariant),
      MessageStatus.sent => (Icons.check, scheme.onSurfaceVariant),
      MessageStatus.delivered => (Icons.done_all, scheme.onSurfaceVariant),
      MessageStatus.read => (Icons.done_all, scheme.primary),
      MessageStatus.failed => (Icons.error_outline, scheme.error),
    };

    return Icon(icon, size: 14, color: color);
  }
}
