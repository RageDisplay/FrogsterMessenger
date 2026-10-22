/// Interface preferences: theme and language.
library;

import 'package:flutter/material.dart';

import 'account_store.dart';

const String _kTheme = 'frogster.pref.theme';
const String _kLocale = 'frogster.pref.locale';

/// Languages the interface is translated into.
const List<Locale> supportedLocales = [Locale('ru'), Locale('en')];

class AppPreferences extends ChangeNotifier {
  AppPreferences([SecureValues? values])
      : _values = values ?? PlatformSecureValues();

  final SecureValues _values;

  ThemeMode _themeMode = ThemeMode.system;

  /// Null follows the system language.
  Locale? _locale;

  ThemeMode get themeMode => _themeMode;
  Locale? get locale => _locale;

  Future<void> load() async {
    _themeMode = switch (await _values.read(_kTheme)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    final code = await _values.read(_kLocale);
    _locale = supportedLocales
        .where((l) => l.languageCode == code)
        .firstOrNull;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _values.write(_kTheme, mode.name);
  }

  Future<void> setLocale(Locale? locale) async {
    if (locale == _locale) return;
    _locale = locale;
    notifyListeners();
    if (locale == null) {
      await _values.delete(_kLocale);
    } else {
      await _values.write(_kLocale, locale.languageCode);
    }
  }
}

/// Picks the interface language for the system's preference list: Russian or
/// English when either is preferred, Russian when neither is.
Locale resolveLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  for (final locale in preferred ?? const <Locale>[]) {
    for (final candidate in supported) {
      if (candidate.languageCode == locale.languageCode) return candidate;
    }
  }
  return const Locale('ru');
}
