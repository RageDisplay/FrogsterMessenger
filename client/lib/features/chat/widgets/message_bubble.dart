/// A single message bubble with its reactions and delivery state.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    required this.onReact,
    this.selfUserId,
    this.senderName,
    this.onActions,
    this.onRetry,
    this.quote,
    this.onTapQuote,
    this.attachmentBuilder,
  });

  final Message message;

  /// Called with the emoji and whether this tap removes our reaction.
  final void Function(String emoji, bool remove) onReact;

  /// Who we are, so a tap on a reaction we already gave takes it back.
  final String? selfUserId;

  /// Shown above incoming messages in groups; direct chats pass null.
  final String? senderName;

  /// Opens the message's actions: long press, or right click on desktop.
  final VoidCallback? onActions;

  /// Sends a failed message again.
  final VoidCallback? onRetry;

  /// The message this one answers: who wrote it and how it began.
  final ({String author, String text})? quote;

  /// Jumps to the quoted message.
  final VoidCallback? onTapQuote;

  /// Renders the attachment, if any. Injected so the bubble stays a pure
  /// widget: download state and decryption belong to the screen above it.
  final Widget Function(AttachmentPayload attachment)? attachmentBuilder;

  static const quickReactions = ['👍', '❤️', '😂', '😮', '😢', '🐸'];

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final outgoing = message.isOutgoing;
    final background = outgoing ? pond.bubbleOut : pond.bubbleIn;
    final foreground = outgoing ? pond.onBubbleOut : pond.onBubbleIn;
    final muted = outgoing ? pond.onBubbleOutMuted : pond.inkMuted;

    const r = Radius.circular(PondRadii.bubble);
    const tail = Radius.circular(PondRadii.bubbleTail);

    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          // Measured against the conversation pane, not the window: on a
          // desktop two-pane layout the window is much wider than the chat.
          constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.78),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Column(
              crossAxisAlignment:
                  outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: onActions,
                  onSecondaryTap: onActions,
                  onTap: message.status == MessageStatus.failed ? onRetry : null,
                  child: Container(
                    decoration: BoxDecoration(
                      color: background,
                      borderRadius: BorderRadius.only(
                        topLeft: r,
                        topRight: r,
                        bottomLeft: outgoing ? r : tail,
                        bottomRight: outgoing ? tail : r,
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      message.attachment != null ? 5 : 13,
                      message.attachment != null ? 5 : 9,
                      message.attachment != null ? 5 : 13,
                      7,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (senderName != null && !outgoing)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 3),
                            child: Text(
                              senderName!,
                              style: TextStyle(
                                color: pond.accent,
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        if (message.forwardedFrom != null)
                          Padding(
                            padding: EdgeInsets.fromLTRB(
                              message.attachment != null ? 8 : 0,
                              message.attachment != null ? 4 : 0,
                              0,
                              4,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.shortcut_rounded, size: 14, color: muted),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    AppLocalizations.of(context)
                                        .forwardedFrom(message.forwardedFrom!),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontStyle: FontStyle.italic,
                                      color: muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (quote != null)
                          _Quote(
                            author: quote!.author,
                            text: quote!.text,
                            outgoing: outgoing,
                            onTap: onTapQuote,
                          ),
                        if (message.attachment != null) ...[
                          attachmentBuilder?.call(message.attachment!) ??
                              const SizedBox.shrink(),
                          if (message.body.isNotEmpty) const SizedBox(height: 6),
                        ],
                        if (message.body.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: message.attachment != null ? 10 : 0,
                            ),
                            child: Text(
                              message.body,
                              style: TextStyle(
                                color: foreground,
                                fontSize: 15,
                                height: 1.4,
                              ),
                            ),
                          ),
                        const SizedBox(height: 3),
                        Padding(
                          padding: EdgeInsets.only(
                            right: message.attachment != null ? 8 : 0,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (message.isEdited) ...[
                                Text(
                                  AppLocalizations.of(context).editedMark,
                                  style: TextStyle(fontSize: 11, color: muted),
                                ),
                                const SizedBox(width: 4),
                              ],
                              Text(
                                formatClock(context, message.sentAt),
                                style: TextStyle(fontSize: 11, color: muted),
                              ),
                              if (outgoing) ...[
                                const SizedBox(width: 4),
                                _StatusIcon(status: message.status, muted: muted),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (message.status == MessageStatus.failed)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      AppLocalizations.of(context).failedTapToRetry,
                      style: TextStyle(fontSize: 12, color: pond.danger),
                    ),
                  ),
                if (message.reactions.isNotEmpty)
                  _ReactionRow(
                    reactions: message.reactions,
                    selfUserId: selfUserId,
                    onTap: (emoji, mine) => onReact(emoji, mine),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The answered message, shown in small type at the top of the reply.
class _Quote extends StatelessWidget {
  const _Quote({
    required this.author,
    required this.text,
    required this.outgoing,
    this.onTap,
  });

  final String author;
  final String text;
  final bool outgoing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final line = outgoing ? pond.onBubbleOut : pond.accent;
    final body = outgoing ? pond.onBubbleOutMuted : pond.inkMuted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 3, 8, 3),
          decoration: BoxDecoration(
            color: line.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(6),
            border: Border(left: BorderSide(color: line, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                author,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: line),
              ),
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: body),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionRow extends StatelessWidget {
  const _ReactionRow({
    required this.reactions,
    required this.onTap,
    this.selfUserId,
  });

  final Map<String, Set<String>> reactions;
  final String? selfUserId;

  /// Called with the emoji and whether it is ours, i.e. the tap removes it.
  final void Function(String emoji, bool mine) onTap;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final entry in reactions.entries)
            Material(
              color: entry.value.contains(selfUserId) ? pond.accentSoft : pond.lily,
              shape: StadiumBorder(
                side: BorderSide(
                  color: entry.value.contains(selfUserId) ? pond.accent : pond.outline,
                ),
              ),
              child: InkWell(
                onTap: () => onTap(entry.key, entry.value.contains(selfUserId)),
                customBorder: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  child: Text(
                    '${entry.key} ${entry.value.length}',
                    style: TextStyle(fontSize: 13, color: pond.ink),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.status, required this.muted});

  final MessageStatus status;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    final (icon, color, label) = switch (status) {
      MessageStatus.pending => (Icons.schedule_rounded, muted, l10n.statusSending),
      MessageStatus.sent => (Icons.check_rounded, muted, l10n.statusSent),
      MessageStatus.delivered => (Icons.done_all_rounded, muted, l10n.statusDelivered),
      MessageStatus.read => (Icons.done_all_rounded, pond.mint, l10n.statusRead),
      MessageStatus.failed => (Icons.error_outline_rounded, pond.danger, l10n.statusFailed),
    };

    return Icon(icon, size: 15, color: color, semanticLabel: label);
  }
}
