/// Renders an attachment inside a message bubble.
///
/// Photos load by themselves, as in any messenger; other files wait for a
/// tap, so a video nobody asked for does not spend the user's mobile data.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/pond_colors.dart';

/// How far a download has progressed.
enum AttachmentState { idle, downloading, ready, failed }

/// Photos up to this size load without a tap. Larger ones are rare, and
/// usually sent as files on purpose.
const int autoDownloadImageBytes = 20 * 1024 * 1024;

class AttachmentView extends StatelessWidget {
  const AttachmentView({
    super.key,
    required this.attachment,
    required this.state,
    required this.onDownload,
    this.progress = 0,
    this.uploadProgress,
    this.decrypted,
    this.error,
    this.onOpen,
    this.onSave,
    this.outgoing = false,
  });

  final AttachmentPayload attachment;
  final AttachmentState state;
  final VoidCallback onDownload;

  final double progress;

  /// How far the file has gone up, while it is being sent from here.
  final double? uploadProgress;

  /// Decrypted bytes, once the download finished and verified.
  final Uint8List? decrypted;

  final String? error;

  /// Shows the photo full screen, or opens the file.
  final VoidCallback? onOpen;

  /// Saves the file somewhere the user picks.
  final VoidCallback? onSave;
  final bool outgoing;

  static const _maxImageHeight = 320.0;
  static const _maxImageWidth = 300.0;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    if (attachment.isImage) return _image(context);

    final uploading = attachment.isUploading;
    return InkWell(
      onTap: uploading
          ? null
          : switch (state) {
              AttachmentState.idle || AttachmentState.failed => onDownload,
              AttachmentState.ready => onOpen,
              AttachmentState.downloading => null,
            },
      borderRadius: BorderRadius.circular(18),
      child: _Tile(
        icon: uploading ? Icons.upload_rounded : _iconFor(state),
        title: attachment.fileName ?? _labelFor(l10n, attachment.mimeType),
        subtitle: uploading
            ? '${((uploadProgress ?? 0) * 100).toStringAsFixed(0)}% · ${attachment.displaySize}'
            : switch (state) {
                AttachmentState.idle => attachment.displaySize,
                AttachmentState.downloading => '${(progress * 100).toStringAsFixed(0)}%',
                AttachmentState.ready => l10n.attachmentTapToOpen(attachment.displaySize),
                AttachmentState.failed => error ?? l10n.attachmentDownloadFailed,
              },
        outgoing: outgoing,
        progress: uploading
            ? (uploadProgress ?? 0)
            : state == AttachmentState.downloading ? progress : null,
        isError: !uploading && state == AttachmentState.failed,
        iconColor: !uploading && state == AttachmentState.failed ? pond.danger : null,
        trailing: state == AttachmentState.ready && onSave != null
            ? IconButton(
                tooltip: l10n.saveFile,
                onPressed: onSave,
                icon: Icon(
                  Icons.download_for_offline_outlined,
                  color: outgoing ? pond.onBubbleOut : pond.onBubbleIn,
                ),
              )
            : null,
      ),
    );
  }

  /// A photo keeps its shape from the first frame: the sender put its size
  /// in the message, so the bubble does not jump when the pixels arrive.
  Widget _image(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    final w = attachment.width;
    final h = attachment.height;
    final aspect = (w != null && h != null && w > 0 && h > 0) ? w / h : 4 / 3;
    var width = _maxImageWidth;
    var height = width / aspect;
    if (height > _maxImageHeight) {
      height = _maxImageHeight;
      width = (height * aspect).clamp(120.0, _maxImageWidth);
    }
    height = height.clamp(90.0, _maxImageHeight);

    final bytes = decrypted;
    final uploading = attachment.isUploading;
    Widget content;
    if (bytes != null) {
      content = Image.memory(
        bytes,
        fit: BoxFit.cover,
        width: width,
        height: height,
        gaplessPlayback: true,
        // Decoded at the size it is shown, not at its full 12 megapixels.
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        // A corrupt image must not take the whole conversation down.
        errorBuilder: (context, _, _) => _Tile(
          icon: Icons.broken_image_outlined,
          title: attachment.fileName ?? l10n.attachmentPhoto,
          subtitle: l10n.attachmentCannotDisplay,
          outgoing: outgoing,
        ),
      );
    } else {
      content = Container(
        width: width,
        height: height,
        color: pond.lilyRaised,
        alignment: Alignment.center,
        child: switch (state) {
          AttachmentState.failed => IconButton(
              tooltip: error ?? l10n.attachmentDownloadFailed,
              onPressed: onDownload,
              icon: Icon(Icons.refresh_rounded, color: pond.danger),
            ),
          AttachmentState.idle when !uploading => IconButton.filledTonal(
              tooltip: attachment.displaySize,
              onPressed: onDownload,
              icon: const Icon(Icons.download_rounded),
            ),
          _ => SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                value: state == AttachmentState.downloading && progress > 0 ? progress : null,
              ),
            ),
        },
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: bytes == null ? null : onOpen,
            child: content,
          ),
          if (uploading && bytes != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.35),
                child: Center(
                  child: SizedBox.square(
                    dimension: 40,
                    child: CircularProgressIndicator(
                      strokeWidth: 3.5,
                      color: Colors.white,
                      backgroundColor: Colors.white24,
                      value: uploadProgress == null || uploadProgress == 0 ? null : uploadProgress,
                    ),
                  ),
                ),
              ),
            ),
        ],
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
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool outgoing;
  final double? progress;
  final bool isError;
  final Color? iconColor;
  final Widget? trailing;

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
                    value: progress == 0 ? null : progress,
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
          ?trailing,
        ],
      ),
    );
  }
}

/// A photo full screen, to zoom into and save.
class ImageViewer extends StatelessWidget {
  const ImageViewer({super.key, required this.bytes, this.title, this.onSave});

  final Uint8List bytes;
  final String? title;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: title == null ? null : Text(title!, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (onSave != null)
            IconButton(
              tooltip: l10n.saveFile,
              onPressed: onSave,
              icon: const Icon(Icons.download_rounded),
            ),
        ],
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
      ),
    );
  }
}
