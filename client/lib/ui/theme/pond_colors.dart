/// The "Lily pond" palette: Frogster's own colours, light and dark.
///
/// Restrained on purpose: near-neutral grounds with a violet cast, one deep
/// violet accent, and a muted mint reserved for "secure" and "online". Kept
/// as a theme extension rather than squeezed into Material's colour roles,
/// because the design has surfaces Material has no names for (the secret-chat
/// tile, presence, per-contact avatar tints).
library;

import 'package:flutter/material.dart';

@immutable
class PondColors extends ThemeExtension<PondColors> {
  const PondColors({
    required this.pond,
    required this.lily,
    required this.lilyRaised,
    required this.outline,
    required this.ink,
    required this.inkMuted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.onAccentSoft,
    required this.night,
    required this.onNight,
    required this.onNightMuted,
    required this.mint,
    required this.mintSoft,
    required this.onMintSoft,
    required this.bubbleIn,
    required this.onBubbleIn,
    required this.bubbleOut,
    required this.onBubbleOut,
    required this.onBubbleOutMuted,
    required this.danger,
    required this.onDanger,
    required this.dangerSoft,
    required this.avatarTints,
  });

  /// The background.
  final Color pond;

  /// Cards, sheets, the navigation bar.
  final Color lily;

  /// Controls on a card and input fields.
  final Color lilyRaised;

  /// Hairlines: dividers and field borders.
  final Color outline;

  final Color ink;
  final Color inkMuted;

  final Color accent;
  final Color onAccent;

  /// Selected tabs and quiet highlights.
  final Color accentSoft;
  final Color onAccentSoft;

  /// The deep violet used for secret chats: it reads as "sealed" in both
  /// themes.
  final Color night;
  final Color onNight;
  final Color onNightMuted;

  /// "Secure", "online", "verified".
  final Color mint;
  final Color mintSoft;
  final Color onMintSoft;

  final Color bubbleIn;
  final Color onBubbleIn;
  final Color bubbleOut;
  final Color onBubbleOut;
  final Color onBubbleOutMuted;

  final Color danger;
  final Color onDanger;
  final Color dangerSoft;

  /// Background/foreground pairs for contact avatars, picked by a stable hash
  /// of the contact so everyone keeps their colour.
  final List<(Color, Color)> avatarTints;

  static const light = PondColors(
    pond: Color(0xFFF4F2F8),
    lily: Color(0xFFFFFFFF),
    lilyRaised: Color(0xFFEEEBF4),
    outline: Color(0xFFE3DEEB),
    ink: Color(0xFF17131F),
    inkMuted: Color(0xFF6D6680),
    accent: Color(0xFF5B2BD1),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFEEE9F9),
    onAccentSoft: Color(0xFF43199F),
    night: Color(0xFF1D1730),
    onNight: Color(0xFFFFFFFF),
    onNightMuted: Color(0xFFC9C2DA),
    mint: Color(0xFF23A57B),
    mintSoft: Color(0xFFE9F6F0),
    onMintSoft: Color(0xFF1B6B50),
    bubbleIn: Color(0xFFFFFFFF),
    onBubbleIn: Color(0xFF17131F),
    bubbleOut: Color(0xFF5B2BD1),
    onBubbleOut: Color(0xFFFFFFFF),
    onBubbleOutMuted: Color(0xFFDCD1FA),
    danger: Color(0xFFB4233F),
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFFBE7EB),
    avatarTints: [
      (Color(0xFFE7E0FA), Color(0xFF3F2196)),
      (Color(0xFFFBE6DA), Color(0xFF8A3A13)),
      (Color(0xFFDDF2EA), Color(0xFF145C45)),
      (Color(0xFFE3EEFB), Color(0xFF174A7A)),
      (Color(0xFFF5EBCF), Color(0xFF6A4A06)),
      (Color(0xFFF3E1EE), Color(0xFF73245C)),
    ],
  );

  static const dark = PondColors(
    pond: Color(0xFF0F0D14),
    lily: Color(0xFF16131D),
    lilyRaised: Color(0xFF1E1A28),
    outline: Color(0xFF2A2536),
    ink: Color(0xFFEDEAF4),
    inkMuted: Color(0xFF8C859E),
    accent: Color(0xFF6B3BE0),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF221B36),
    onAccentSoft: Color(0xFFC9B8FF),
    night: Color(0xFF1D1730),
    onNight: Color(0xFFEDEAF4),
    onNightMuted: Color(0xFFA59EB8),
    mint: Color(0xFFA9E8D2),
    mintSoft: Color(0xFF14261F),
    onMintSoft: Color(0xFFA9E8D2),
    bubbleIn: Color(0xFF1C1826),
    onBubbleIn: Color(0xFFEDEAF4),
    bubbleOut: Color(0xFF6B3BE0),
    onBubbleOut: Color(0xFFFFFFFF),
    onBubbleOutMuted: Color(0xFFE4DBFF),
    danger: Color(0xFFFF8A9E),
    onDanger: Color(0xFF3A0812),
    dangerSoft: Color(0xFF2E1219),
    avatarTints: [
      (Color(0xFF2A2145), Color(0xFFCDBEFF)),
      (Color(0xFF3A2219), Color(0xFFF5CDB8)),
      (Color(0xFF173029), Color(0xFFB4E6D3)),
      (Color(0xFF172736), Color(0xFFBCD7F2)),
      (Color(0xFF332A14), Color(0xFFEBD9A6)),
      (Color(0xFF341C2E), Color(0xFFEBC6E0)),
    ],
  );

  /// The avatar colours for [key], stable across launches and devices.
  (Color, Color) tintFor(String key) =>
      avatarTints[stableHash(key) % avatarTints.length];

  @override
  PondColors copyWith() => this;

  @override
  PondColors lerp(PondColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return PondColors(
      pond: l(pond, other.pond),
      lily: l(lily, other.lily),
      lilyRaised: l(lilyRaised, other.lilyRaised),
      outline: l(outline, other.outline),
      ink: l(ink, other.ink),
      inkMuted: l(inkMuted, other.inkMuted),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      onAccentSoft: l(onAccentSoft, other.onAccentSoft),
      night: l(night, other.night),
      onNight: l(onNight, other.onNight),
      onNightMuted: l(onNightMuted, other.onNightMuted),
      mint: l(mint, other.mint),
      mintSoft: l(mintSoft, other.mintSoft),
      onMintSoft: l(onMintSoft, other.onMintSoft),
      bubbleIn: l(bubbleIn, other.bubbleIn),
      onBubbleIn: l(onBubbleIn, other.onBubbleIn),
      bubbleOut: l(bubbleOut, other.bubbleOut),
      onBubbleOut: l(onBubbleOut, other.onBubbleOut),
      onBubbleOutMuted: l(onBubbleOutMuted, other.onBubbleOutMuted),
      danger: l(danger, other.danger),
      onDanger: l(onDanger, other.onDanger),
      dangerSoft: l(dangerSoft, other.dangerSoft),
      avatarTints: t < 0.5 ? avatarTints : other.avatarTints,
    );
  }
}

/// FNV-1a over the UTF-16 code units: the same value on every platform and in
/// every run, unlike [String.hashCode].
int stableHash(String input) {
  var hash = 0x811C9DC5;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

extension PondTheme on BuildContext {
  PondColors get pond => Theme.of(this).extension<PondColors>()!;
}
