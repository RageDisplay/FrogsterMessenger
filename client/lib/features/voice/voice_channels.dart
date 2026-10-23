/// A cloud group's voice channels, at the top of its chat: who is in each,
/// one tap to join, and for admins making, renaming and removing them.
library;

import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../data/voice/voice_controller.dart';
import '../../data/voice/voice_models.dart';
import '../../l10n/app_localizations.dart';
import '../../ui/theme/pond_colors.dart';
import '../../ui/widgets/avatars.dart';

class VoiceChannelsPanel extends StatefulWidget {
  const VoiceChannelsPanel({super.key, required this.chat, required this.controller});

  final Chat chat;
  final VoiceController controller;

  @override
  State<VoiceChannelsPanel> createState() => _VoiceChannelsPanelState();
}

class _VoiceChannelsPanelState extends State<VoiceChannelsPanel> {
  /// Null until the user opens or closes it: then it follows whether anyone
  /// is talking.
  bool? _open;

  Chat get chat => widget.chat;
  VoiceController get voice => widget.controller;

  Future<void> _join(VoiceChannel channel) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await voice.join(chat.id, channel, chatTitle: chat.displayName);
    } on VoiceJoinException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(switch (e.problem) {
          VoiceJoinProblem.full => l10n.voiceFull,
          VoiceJoinProblem.gone => l10n.voiceGone,
          VoiceJoinProblem.failed => l10n.voiceJoinFailed,
        }),
      ));
    }
  }

  Future<String?> _askName({String initial = ''}) {
    final l10n = AppLocalizations.of(context);
    final field = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(initial.isEmpty ? l10n.voiceNewChannel : l10n.voiceRenameChannel),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 32,
          decoration: InputDecoration(hintText: l10n.voiceChannelNameHint),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, field.text.trim()), child: Text(l10n.save)),
        ],
      ),
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.actionFailed('$e'))));
    }
  }

  Future<void> _create() async {
    final name = await _askName();
    if (name == null || name.isEmpty) return;
    await _guard(() => voice.createChannel(chat.id, name));
    // Shown, so the new channel can be joined straight away.
    if (mounted) setState(() => _open = true);
  }

  Future<void> _manage(VoiceChannel channel, String action) async {
    if (action == 'rename') {
      final name = await _askName(initial: channel.name);
      if (name == null || name.isEmpty || name == channel.name) return;
      await _guard(() => voice.renameChannel(chat.id, channel.id, name));
    } else if (action == 'delete') {
      await _guard(() => voice.deleteChannel(chat.id, channel.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: voice, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final channels = voice.channels(chat.id);
    if (channels == null || (channels.isEmpty && !chat.isAdmin)) return const SizedBox.shrink();
    final people = channels.fold(0, (n, c) => n + c.participants.length);
    final here = voice.current?.chatId == chat.id;
    final open = _open ?? (people > 0 || here);

    return Material(
      color: pond.lily,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => setState(() => _open = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.graphic_eq_rounded, size: 18, color: people > 0 ? pond.mint : pond.inkMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      people > 0 ? l10n.voiceChannelsActive(people) : l10n.voiceChannels,
                      style: TextStyle(fontWeight: FontWeight.w600, color: pond.ink, fontSize: 13),
                    ),
                  ),
                  if (chat.isAdmin)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: l10n.voiceNewChannel,
                      onPressed: _create,
                      icon: const Icon(Icons.add_rounded, size: 20),
                    ),
                  Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: pond.inkMuted),
                ],
              ),
            ),
          ),
          if (open)
            for (final channel in channels)
              _ChannelTile(
                chat: chat,
                channel: channel,
                voice: voice,
                onJoin: () => _join(channel),
                onManage: chat.isAdmin ? (action) => _manage(channel, action) : null,
              ),
          Divider(height: 1, color: pond.outline),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  const _ChannelTile({
    required this.chat,
    required this.channel,
    required this.voice,
    required this.onJoin,
    this.onManage,
  });

  final Chat chat;
  final VoiceChannel channel;
  final VoiceController voice;
  final VoidCallback onJoin;
  final void Function(String action)? onManage;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final inside = voice.current?.channel.id == channel.id;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.volume_up_rounded, size: 18, color: inside ? pond.accent : pond.inkMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: pond.ink, fontWeight: inside ? FontWeight.w700 : FontWeight.w500)),
                if (channel.participants.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final p in channel.participants) _Person(chat: chat, participant: p, voice: voice),
                    ],
                  ),
                ],
              ],
            ),
          ),
          if (inside)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(l10n.voiceYouAreHere, style: TextStyle(color: pond.accent, fontSize: 12)),
            )
          else
            TextButton(
              onPressed: voice.joining ? null : onJoin,
              child: Text(l10n.voiceJoin),
            ),
          if (onManage != null)
            PopupMenuButton<String>(
              tooltip: l10n.voiceManageChannel,
              onSelected: onManage,
              itemBuilder: (context) => [
                PopupMenuItem(value: 'rename', child: Text(l10n.voiceRenameChannel)),
                PopupMenuItem(value: 'delete', child: Text(l10n.voiceDeleteChannel)),
              ],
            ),
        ],
      ),
    );
  }
}

/// Someone in a channel: a ring while they talk, a crossed microphone or
/// headset when they turned theirs off.
class _Person extends StatelessWidget {
  const _Person({required this.chat, required this.participant, required this.voice});

  final Chat chat;
  final VoiceParticipant participant;
  final VoiceController voice;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final member = chat.member(participant.userId);
    final speaking = voice.isSpeaking(participant.userId);
    final name = member?.name ?? '…';
    return Tooltip(
      message: name,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: speaking ? pond.mint : Colors.transparent, width: 2),
            ),
            child: member == null
                ? CircleAvatar(radius: 11, child: Text(name.characters.first))
                : UserAvatar.member(member, size: 22),
          ),
          const SizedBox(width: 4),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 110),
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: pond.ink)),
          ),
          if (participant.deafened)
            Icon(Icons.headset_off_rounded, size: 14, color: pond.danger)
          else if (participant.muted)
            Icon(Icons.mic_off_rounded, size: 14, color: pond.inkMuted),
        ],
      ),
    );
  }
}
