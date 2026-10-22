/// Renders an attachment inside a message bubble.
///
/// A file is not fetched until the user asks for it: attachments arrive as a
/// reference plus a key, and downloading every one automatically would burn
/// mobile data and confirm to a network observer exactly which messages
/// carried files.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/pond_colors.dart';

/// How far a download has progressed.
enum AttachmentState { idle, downloading, ready, failed }

class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    required this.state,
    required this.onDownload,
    this.progress = 0,
    this.decrypted,
    this.error,
    this.onOpen,
    this.outgoing = false,
  });

  final AttachmentPayload attachment;
  final AttachmentState state;
  final VoidCallback onDownload;

  final double progress;

  /// Decrypted bytes, once the download finished and verified.
  final Uint8List? decrypted;

  final String? error;
  final VoidCallback? onOpen;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    // An image that has been fetched and verified can be shown inline.
    if (attachment.isImage && state == AttachmentState.ready && decrypted != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Image.memory(
            decrypted!,
            fit: BoxFit.cover,
            // A corrupt image must not take the whole conversation down.
            errorBuilder: (context, _, _) => _Tile(
              icon: Icons.broken_image_outlined,
              title: attachment.fileName ?? l10n.attachmentPhoto,
              subtitle: l10n.attachmentCannotDisplay,
              outgoing: outgoing,
            ),
          ),
        ),
      );
    }

    return InkWell(
      onTap: switch (state) {
        AttachmentState.idle || AttachmentState.failed => onDownload,
        AttachmentState.ready => onOpen,
        AttachmentState.downloading => null,
      },
      borderRadius: BorderRadius.circular(18),
      child: _Tile(
        icon: _iconFor(state),
        title: attachment.fileName ?? _labelFor(l10n, attachment.mimeType),
        subtitle: switch (state) {
          AttachmentState.idle => attachment.displaySize,
          AttachmentState.downloading =>
            '${(progress * 100).toStringAsFixed(0)}%',
          AttachmentState.ready =>
            l10n.attachmentTapToOpen(attachment.displaySize),
          AttachmentState.failed => error ?? l10n.attachmentDownloadFailed,
        },
        outgoing: outgoing,
        progress: state == AttachmentState.downloading ? progress : null,
        isError: state == AttachmentState.failed,
        iconColor: state == AttachmentState.failed ? pond.danger : null,
      ),
    );
  }

  static IconData _iconFor(AttachmentState state) => switch (state) {
        AttachmentState.idle => Icons.download_rounded,
        AttachmentState.downloading => Icons.hourglass_top_rounded,
        AttachmentState.ready => Icons.insert_drive_file_outlined,
        AttachmentState.failed => Icons.error_outline_rounded,
      };

  /// A readable label when the sender did not include a file name.
  static String _labelFor(AppLocalizations l10n, String mimeType) {
    if (mimeType.startsWith('image/')) return l10n.attachmentPhoto;
    if (mimeType.startsWith('video/')) return l10n.attachmentVideo;
    if (mimeType.startsWith('audio/')) return l10n.attachmentAudio;
    if (mimeType == 'application/pdf') return l10n.attachmentPdf;
    return l10n.attachmentFile;
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.outgoing,
    this.progress,
    this.isError = false,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool outgoing;
  final double? progress;
  final bool isError;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final onBubble = outgoing ? pond.onBubbleOut : pond.onBubbleIn;
    final chipColor =
        outgoing ? pond.onBubbleOut.withValues(alpha: 0.18) : pond.lilyRaised;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      constraints: const BoxConstraints(minWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(14),
            ),
            padding: const EdgeInsets.all(10),
            child: progress != null
                ? CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 3,
                    color: onBubble,
                  )
                : Icon(icon, size: 22, color: iconColor ?? onBubble),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: onBubble),
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: isError
                            ? pond.danger
                            : onBubble.withValues(alpha: 0.75),
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
