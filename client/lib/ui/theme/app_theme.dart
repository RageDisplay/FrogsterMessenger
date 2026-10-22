/// Frogster's theme: the "Lily pond" design system on top of Material 3.
///
/// The Material colour scheme is filled from the pond palette explicitly
/// rather than generated from a seed, so stock widgets (dialogs, snack bars,
/// switches) land on the same violets as the custom ones instead of a
/// machine-derived approximation.
library;

import 'package:flutter/material.dart';

import 'pond_colors.dart';

/// Corner radii: modest and consistent, so the interface reads as a tool
/// rather than a toy.
class PondRadii {
  static const double chip = 10;
  static const double control = 13;
  static const double card = 18;
  static const double sheet = 22;

  /// Message bubbles, and their tucked corner pointing at the sender.
  static const double bubble = 16;
  static const double bubbleTail = 5;
}

const String pondFontFamily = 'Manrope';

class AppTheme {
  static ThemeData light() => _build(PondColors.light, Brightness.light);
  static ThemeData dark() => _build(PondColors.dark, Brightness.dark);

  static ThemeData _build(PondColors c, Brightness brightness) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.onAccentSoft,
      secondary: c.night,
      onSecondary: c.onNight,
      secondaryContainer: c.accentSoft,
      onSecondaryContainer: c.onAccentSoft,
      tertiary: c.mint,
      onTertiary: c.night,
      error: c.danger,
      onError: c.onDanger,
      errorContainer: c.dangerSoft,
      onErrorContainer: c.danger,
      surface: c.pond,
      onSurface: c.ink,
      onSurfaceVariant: c.inkMuted,
      surfaceContainerLowest: c.lily,
      surfaceContainerLow: c.lily,
      surfaceContainer: c.lily,
      surfaceContainerHigh: c.lilyRaised,
      surfaceContainerHighest: c.lilyRaised,
      outline: c.inkMuted,
      outlineVariant: c.outline,
      inverseSurface: c.night,
      onInverseSurface: c.onNight,
      inversePrimary: c.accentSoft,
      shadow: const Color(0xFF1A0E40),
      scrim: const Color(0xFF0B0718),
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: pondFontFamily,
    );
    final text = base.textTheme.apply(
      bodyColor: c.ink,
      displayColor: c.ink,
    );

    final pill = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PondRadii.control),
    );

    return base.copyWith(
      scaffoldBackgroundColor: c.pond,
      extensions: [c],
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: c.pond,
        foregroundColor: c.ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.lilyRaised,
        hintStyle: TextStyle(color: c.inkMuted),
        labelStyle: TextStyle(color: c.inkMuted),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
          borderSide: BorderSide(color: c.outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
          borderSide: BorderSide(color: c.outline),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
          borderSide: BorderSide(color: c.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PondRadii.control),
          borderSide: BorderSide(color: c.danger, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          minimumSize: const Size(0, 50),
          shape: pill,
          textStyle: const TextStyle(
            fontFamily: pondFontFamily,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.accent,
          minimumSize: const Size(0, 48),
          shape: pill,
          side: BorderSide(color: c.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.accent,
          minimumSize: const Size(0, 44),
          shape: pill,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: c.ink,
          minimumSize: const Size(44, 44),
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: c.lily,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PondRadii.card),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.lily,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PondRadii.sheet),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.lily,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(PondRadii.sheet),
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.night,
        contentTextStyle: TextStyle(color: c.onNight, fontFamily: pondFontFamily),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PondRadii.chip),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: c.lilyRaised,
          foregroundColor: c.inkMuted,
          selectedBackgroundColor: c.accent,
          selectedForegroundColor: c.onAccent,
          side: BorderSide.none,
          shape: pill,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent),
      dividerTheme: DividerThemeData(color: c.outline, space: 1, thickness: 1),
      listTileTheme: ListTileThemeData(
        iconColor: c.inkMuted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PondRadii.chip),
        ),
      ),
    );
  }
}
