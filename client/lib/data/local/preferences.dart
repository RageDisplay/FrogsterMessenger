/// Interface preferences: theme, language and notifications.
library;

import 'package:flutter/material.dart';

import 'account_store.dart';

const String _kTheme = 'frogster.pref.theme';
const String _kLocale = 'frogster.pref.locale';
const String _kNotify = 'frogster.pref.notify';
const String _kNotifyPreview = 'frogster.pref.notify_preview';

/// Languages the interface is translated into.
const List<Locale> supportedLocales = [Locale('ru'), Locale('en')];

class AppPreferences extends ChangeNotifier {
  AppPreferences([SecureValues? values])
      : _values = values ?? PlatformSecureValues();

  final SecureValues _values;

  ThemeMode _themeMode = ThemeMode.system;

  /// Null follows the system language.
  Locale? _locale;

  bool _notifications = true;
  bool _notificationPreview = true;

  ThemeMode get themeMode => _themeMode;
  Locale? get locale => _locale;
  bool get notifications => _notifications;

  /// Whether a notification shows who wrote and what.
  bool get notificationPreview => _notificationPreview;

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
    _notifications = await _values.read(_kNotify) != 'off';
    _notificationPreview = await _values.read(_kNotifyPreview) != 'off';
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == _themeMode) return;
    _themeMode = mode;
    notifyListeners();
    await _values.write(_kTheme, mode.name);
  }

  Future<void> setNotifications(bool on) async {
    _notifications = on;
    notifyListeners();
    await _values.write(_kNotify, on ? 'on' : 'off');
  }

  Future<void> setNotificationPreview(bool on) async {
    _notificationPreview = on;
    notifyListeners();
    await _values.write(_kNotifyPreview, on ? 'on' : 'off');
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
