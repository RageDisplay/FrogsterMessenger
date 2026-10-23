/// A voice message in a bubble: play, waveform, length.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/audio/voice_player.dart';
import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/pond_colors.dart';

class VoiceMessageView extends StatelessWidget {
  const VoiceMessageView({
    super.key,
    required this.attachment,
    required this.player,
    required this.load,
    this.outgoing = false,
    this.uploadProgress,
  });

  final AttachmentPayload attachment;
  final VoicePlayer player;

  /// The message's sound, fetched and decrypted.
  final Future<Uint8List> Function() load;
  final bool outgoing;
  final double? uploadProgress;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    final onBubble = outgoing ? pond.onBubbleOut : pond.onBubbleIn;
    final id = attachment.blobId;
    final bars = _bars(attachment.waveform);
    final total = Duration(milliseconds: attachment.durationMs ?? 0);

    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final playing = player.isPlaying(id);
        final loading = player.isLoading(id);
        final progress = player.progressOf(id);
        final shown = player.current == id ? player.positionOf(id) : total;
        final uploading = attachment.isUploading;
        return Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 42,
                child: uploading || loading
                    ? Padding(
                        padding: const EdgeInsets.all(9),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: onBubble,
                          value: uploading && (uploadProgress ?? 0) > 0 ? uploadProgress : null,
                        ),
                      )
                    : IconButton.filled(
                        tooltip: playing ? l10n.voicePause : l10n.voicePlay,
                        style: IconButton.styleFrom(
                          backgroundColor: outgoing ? pond.onBubbleOut : pond.accent,
                          foregroundColor: outgoing ? pond.accent : pond.onAccent,
                        ),
                        onPressed: () => player.toggle(id, load),
                        icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
                      ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTapDown: (d) => player.seek(id, (d.localPosition.dx / _width).clamp(0, 1)),
                    child: CustomPaint(
                      size: const Size(_width, 28),
                      painter: _WavePainter(
                        bars: bars,
                        progress: progress,
                        played: onBubble,
                        rest: onBubble.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _clock(shown),
                    style: TextStyle(fontSize: 11, color: onBubble.withValues(alpha: 0.8)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  static const double _width = 150;

  static Uint8List _bars(String? waveform) {
    if (waveform == null) return Uint8List(0);
    try {
      return base64Decode(waveform);
    } on FormatException {
      return Uint8List(0);
    }
  }

  static String _clock(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({required this.bars, required this.progress, required this.played, required this.rest});

  final Uint8List bars;
  final double progress;
  final Color played;
  final Color rest;

  @override
  void paint(Canvas canvas, Size size) {
    const count = 40;
    final step = size.width / count;
    final paint = Paint()
      ..strokeWidth = step * 0.55
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < count; i++) {
      // The stored bars resampled to what fits.
      final v = bars.isEmpty ? 40 : bars[(i * bars.length / count).floor().clamp(0, bars.length - 1)];
      final h = (size.height - 4) * (0.12 + 0.88 * v / 255);
      final x = step * (i + 0.5);
      paint.color = (i + 0.5) / count <= progress ? played : rest;
      canvas.drawLine(Offset(x, (size.height - h) / 2), Offset(x, (size.height + h) / 2), paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.progress != progress || old.bars != bars || old.played != played;
}
