/// Avatars that know whose they are: the picture, if any, and whether the
/// person is online.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/models/models.dart';
import '../../data/repositories/avatar_store.dart';
import '../../data/repositories/presence_tracker.dart';
import '../../l10n/app_localizations.dart';
import '../format.dart';
import '../theme/pond_colors.dart';
import 'lily_avatar.dart';

/// Makes pictures and presence available below it.
class AvatarScope extends InheritedWidget {
  const AvatarScope({
    super.key,
    required this.avatars,
    required this.presence,
    required this.selfUserId,
    required super.child,
  });

  final AvatarStore? avatars;
  final PresenceTracker? presence;
  final String? selfUserId;

  static AvatarScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AvatarScope>();

  @override
  bool updateShouldNotify(AvatarScope old) =>
      avatars != old.avatars || presence != old.presence || selfUserId != old.selfUserId;
}

/// The other person in a direct chat.
ChatMember? peerOf(Chat chat, String? selfUserId) => chat.isGroup
    ? null
    : chat.members.where((m) => m.userId != selfUserId).firstOrNull;

/// A chat's avatar: the peer's picture for a direct chat, the group's for
/// a cloud group, and the online dot for a peer who is around.
class ChatAvatar extends StatelessWidget {
  const ChatAvatar({super.key, required this.chat, this.size = 48, this.showPresence = true});

  final Chat chat;
  final double size;
  final bool showPresence;

  @override
  Widget build(BuildContext context) {
    final scope = AvatarScope.of(context);
    final peer = peerOf(chat, scope?.selfUserId);
    final (owner, id, version) = peer != null
        ? (AvatarOwner.user, peer.userId, peer.avatarVersion)
        // A secret group's look stays between its members.
        : (AvatarOwner.chat, chat.id, chat.isSecret ? 0 : chat.avatarVersion);

    return _Resolved(
      owner: owner,
      id: id,
      version: version,
      presenceOf: showPresence ? peer?.userId : null,
      builder: (image, online) => LilyAvatar(
        seed: chat.peerUsername ?? chat.id,
        label: chat.displayName,
        icon: chat.isGroup ? Icons.groups_rounded : null,
        secret: chat.isSecret,
        size: size,
        image: image,
        online: online,
      ),
    );
  }
}

/// A person's avatar.
class UserAvatar extends StatelessWidget {
  const UserAvatar({
    super.key,
    required this.userId,
    required this.username,
    required this.name,
    this.avatarVersion = 0,
    this.size = 40,
    this.showPresence = false,
  });

  UserAvatar.member(ChatMember member, {Key? key, double size = 40, bool showPresence = false})
      : this(
          key: key,
          userId: member.userId,
          username: member.username,
          name: member.name,
          avatarVersion: member.avatarVersion,
          size: size,
          showPresence: showPresence,
        );

  final String userId;
  final String username;
  final String name;
  final int avatarVersion;
  final double size;
  final bool showPresence;

  @override
  Widget build(BuildContext context) => _Resolved(
        owner: AvatarOwner.user,
        id: userId,
        version: avatarVersion,
        presenceOf: showPresence ? userId : null,
        builder: (image, online) => LilyAvatar(
          seed: username,
          label: name,
          size: size,
          image: image,
          online: online,
        ),
      );
}

/// "online", "last seen at 14:05", "last seen recently" -- or null when
/// nothing has been heard.
String? presenceText(BuildContext context, Presence presence) {
  final l10n = AppLocalizations.of(context);
  return switch (presence.status) {
    PresenceStatus.online => l10n.presenceOnline,
    PresenceStatus.offline when presence.lastSeen != null =>
      l10n.presenceLastSeen(formatLastSeen(context, presence.lastSeen!)),
    PresenceStatus.offline || PresenceStatus.recently => l10n.presenceRecently,
    PresenceStatus.week => l10n.presenceWeek,
    PresenceStatus.month => l10n.presenceMonth,
    PresenceStatus.longAgo => l10n.presenceLongAgo,
    PresenceStatus.unknown => null,
  };
}

/// Someone's presence as a line of text, kept up to date; [fallback] until
/// anything is known.
class PresenceLine extends StatelessWidget {
  const PresenceLine({super.key, required this.userId, required this.fallback, this.style});

  final String userId;
  final String fallback;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final statuses = AvatarScope.of(context)?.presence?.statuses ?? _Resolved._noPresence;
    final pond = context.pond;
    return ValueListenableBuilder<Map<String, Presence>>(
      valueListenable: statuses,
      builder: (context, all, _) {
        final presence = all[userId] ?? Presence.unknown;
        final text = presenceText(context, presence);
        return Text(
          text ?? fallback,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: (style ?? TextStyle(fontSize: 13, color: pond.inkMuted)).copyWith(
            color: presence.isOnline ? pond.accent : null,
          ),
        );
      },
    );
  }
}

class _Resolved extends StatelessWidget {
  const _Resolved({
    required this.owner,
    required this.id,
    required this.version,
    required this.presenceOf,
    required this.builder,
  });

  final AvatarOwner owner;
  final String id;
  final int version;
  final String? presenceOf;
  final Widget Function(Uint8List? image, bool online) builder;

  @override
  Widget build(BuildContext context) {
    final scope = AvatarScope.of(context);
    final avatars = scope?.avatars;
    final presence = scope?.presence;
    final image = avatars?.watch(owner, id, version) ?? _none;
    final statuses = presence?.statuses ?? _noPresence;
    return ValueListenableBuilder<Uint8List?>(
      valueListenable: image,
      builder: (context, bytes, _) => ValueListenableBuilder<Map<String, Presence>>(
        valueListenable: statuses,
        builder: (context, all, _) => builder(
          bytes,
          presenceOf != null && (all[presenceOf]?.isOnline ?? false),
        ),
      ),
    );
  }

  static final _none = ValueNotifier<Uint8List?>(null);
  static final _noPresence = ValueNotifier<Map<String, Presence>>(const {});
}
