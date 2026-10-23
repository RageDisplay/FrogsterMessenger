/// The bar over every screen while this device is in a voice channel:
/// where, how well, and the microphone, sound and hang-up buttons.
library;

import 'package:flutter/material.dart';

import '../../data/voice/voice_controller.dart';
import '../../data/voice/voice_link.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme/pond_colors.dart';

class VoiceBar extends StatelessWidget {
  const VoiceBar({super.key, required this.controller, this.onOpen});

  final VoiceController controller;

  /// Opens the group the call is in.
  final void Function(String chatId)? onOpen;

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: controller, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final session = controller.current;
    if (session == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final talking = controller.isSpeaking(controller.selfUserId);
    final status = switch (session.route) {
      VoiceRoute.connecting => l10n.voiceConnecting,
      VoiceRoute.udp => l10n.voiceConnected,
      VoiceRoute.relayed => l10n.voiceRelayed,
    };
    final rtt = session.rtt;
    return Material(
      color: pond.accent,
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onOpen == null ? null : () => onOpen!(session.chatId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: pond.onAccent.withValues(alpha: talking ? 0.35 : 0.15),
                  ),
                  child: Icon(
                    session.route == VoiceRoute.connecting ? Icons.sync_rounded : Icons.graphic_eq_rounded,
                    size: 18,
                    color: pond.onAccent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${session.channel.name} · ${session.chatTitle}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: pond.onAccent, fontWeight: FontWeight.w700, fontSize: 14),
                      ),
                      Text(
                        rtt == null || session.route == VoiceRoute.connecting
                            ? status
                            : '$status · ${l10n.voicePing(rtt.inMilliseconds)}',
                        maxLines: 1,
                        style: TextStyle(color: pond.onAccent.withValues(alpha: 0.85), fontSize: 12),
                      ),
                    ],
                  ),
                ),
                // Labels, not tooltips: the bar sits above the navigator,
                // where there is no overlay for a tooltip to show in.
                _Labelled(
                  label: session.muted ? l10n.voiceUnmute : l10n.voiceMute,
                  child: IconButton(
                    color: pond.onAccent,
                    onPressed: session.call.hasMicrophone ? () => controller.setMuted(!session.muted) : null,
                    icon: Icon(session.muted ? Icons.mic_off_rounded : Icons.mic_rounded),
                  ),
                ),
                _Labelled(
                  label: session.deafened ? l10n.voiceUndeafen : l10n.voiceDeafen,
                  child: IconButton(
                    color: pond.onAccent,
                    onPressed: () => controller.setDeafened(!session.deafened),
                    icon: Icon(session.deafened ? Icons.headset_off_rounded : Icons.headset_rounded),
                  ),
                ),
                _Labelled(
                  label: l10n.voiceLeave,
                  child: IconButton(
                    style: IconButton.styleFrom(backgroundColor: pond.danger, foregroundColor: Colors.white),
                    onPressed: controller.leave,
                    icon: const Icon(Icons.call_end_rounded),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({required this.label, required this.child});
  final String label;
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(button: true, label: label, child: child);
}
