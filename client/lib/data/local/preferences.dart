/// Interface preferences: theme, language and notifications.
library;

import 'package:flutter/material.dart';

import 'account_store.dart';

const String _kTheme = 'frogster.pref.theme';
const String _kLocale = 'frogster.pref.locale';
const String _kNotify = 'frogster.pref.notify';
const String _kNotifyPreview = 'frogster.pref.notify_preview';
const String _kMicrophone = 'frogster.pref.microphone';
const String _kSpeaker = 'frogster.pref.speaker';
const String _kNoiseSuppression = 'frogster.pref.noise_suppression';
const String _kAutoGain = 'frogster.pref.auto_gain';

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
  String? _microphone;
  String? _speaker;
  bool _noiseSuppression = true;
  bool _autoGain = true;

  /// The input device to record from; null for the system's default.
  String? get microphone => _microphone;

  /// The output device for voice messages and channels; null for the
  /// system's default.
  String? get speaker => _speaker;

  /// Background noise removed from voice messages and calls.
  bool get noiseSuppression => _noiseSuppression;

  /// Quiet speech brought up to a comfortable level.
  bool get autoGain => _autoGain;

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
    _microphone = await _values.read(_kMicrophone);
    _speaker = await _values.read(_kSpeaker);
    _noiseSuppression = await _values.read(_kNoiseSuppression) != 'off';
    _autoGain = await _values.read(_kAutoGain) != 'off';
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

  Future<void> setMicrophone(String? deviceId) async {
    _microphone = deviceId;
    notifyListeners();
    if (deviceId == null) {
      await _values.delete(_kMicrophone);
    } else {
      await _values.write(_kMicrophone, deviceId);
    }
  }

  Future<void> setSpeaker(String? deviceId) async {
    _speaker = deviceId;
    notifyListeners();
    if (deviceId == null) {
      await _values.delete(_kSpeaker);
    } else {
      await _values.write(_kSpeaker, deviceId);
    }
  }

  Future<void> setNoiseSuppression(bool on) async {
    _noiseSuppression = on;
    notifyListeners();
    await _values.write(_kNoiseSuppression, on ? 'on' : 'off');
  }

  Future<void> setAutoGain(bool on) async {
    _autoGain = on;
    notifyListeners();
    await _values.write(_kAutoGain, on ? 'on' : 'off');
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
