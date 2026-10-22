/// A contact avatar: a rounded square in the contact's own tint.
///
/// The tint comes from a stable hash of the contact's id, so a face is
/// recognisable by colour before the name is read -- and stays the same on
/// every device.
library;

import 'package:flutter/material.dart';

import '../theme/pond_colors.dart';

class LilyAvatar extends StatelessWidget {
  const LilyAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 48,
    this.icon,
    this.secret = false,
    this.online = false,
  });

  /// Stable identity behind the colour, usually a username or chat id.
  final String seed;

  /// Name the initial is taken from.
  final String label;

  final double size;

  /// Replaces the initial, e.g. a group or lock glyph.
  final IconData? icon;

  /// Secret chats sit on the deep "night" colour whatever the contact's tint.
  final bool secret;

  /// Shows the presence dot.
  final bool online;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final (background, foreground) =
        secret ? (pond.night, pond.mint) : pond.tintFor(seed);

    final avatar = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(size * 0.31),
      ),
      alignment: Alignment.center,
      child: icon != null
          ? Icon(icon, size: size * 0.42, color: foreground)
          : Text(
              initialOf(label),
              style: TextStyle(
                color: foreground,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.36,
              ),
            ),
    );

    if (!online) return avatar;
    final dot = size * 0.26;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(
          right: -dot * 0.15,
          bottom: -dot * 0.15,
          child: Container(
            width: dot,
            height: dot,
            decoration: BoxDecoration(
              color: pond.mint,
              shape: BoxShape.circle,
              border: Border.all(color: pond.lily, width: dot * 0.22),
            ),
          ),
        ),
      ],
    );
  }

  /// First letter of [name], upper-cased; '?' for an empty name.
  static String initialOf(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return String.fromCharCode(trimmed.runes.first).toUpperCase();
  }
}
