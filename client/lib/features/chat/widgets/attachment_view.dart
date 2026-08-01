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
    final scheme = Theme.of(context).colorScheme;

    // An image that has been fetched and verified can be shown inline.
    if (attachment.isImage && state == AttachmentState.ready && decrypted != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: Image.memory(
            decrypted!,
            fit: BoxFit.cover,
            // A corrupt image must not take the whole conversation down.
            errorBuilder: (context, _, _) => _Tile(
              icon: Icons.broken_image_outlined,
              title: attachment.fileName ?? 'Image',
              subtitle: 'Could not display',
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
      borderRadius: BorderRadius.circular(12),
      child: _Tile(
        icon: _iconFor(state),
        title: attachment.fileName ?? _labelFor(attachment.mimeType),
        subtitle: switch (state) {
          AttachmentState.idle => attachment.displaySize,
          AttachmentState.downloading =>
            '${(progress * 100).toStringAsFixed(0)}%',
          AttachmentState.ready => 'Tap to open · ${attachment.displaySize}',
          AttachmentState.failed => error ?? 'Download failed',
        },
        outgoing: outgoing,
        progress: state == AttachmentState.downloading ? progress : null,
        isError: state == AttachmentState.failed,
        iconColor: state == AttachmentState.failed ? scheme.error : null,
      ),
    );
  }

  static IconData _iconFor(AttachmentState state) => switch (state) {
        AttachmentState.idle => Icons.download_outlined,
        AttachmentState.downloading => Icons.hourglass_top,
        AttachmentState.ready => Icons.insert_drive_file_outlined,
        AttachmentState.failed => Icons.error_outline,
      };

  /// A readable label when the sender did not include a file name.
  static String _labelFor(String mimeType) {
    if (mimeType.startsWith('image/')) return 'Photo';
    if (mimeType.startsWith('video/')) return 'Video';
    if (mimeType.startsWith('audio/')) return 'Audio';
    if (mimeType == 'application/pdf') return 'PDF document';
    return 'File';
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
    final scheme = Theme.of(context).colorScheme;
    final onBubble = outgoing ? scheme.onPrimaryContainer : scheme.onSurface;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      constraints: const BoxConstraints(minWidth: 180),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 36,
            height: 36,
            child: progress != null
                ? CircularProgressIndicator(value: progress, strokeWidth: 3)
                : Icon(icon, color: iconColor ?? onBubble),
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
                            ? scheme.error
                            : onBubble.withValues(alpha: 0.7),
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
