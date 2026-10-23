/// Errors the app ran into, kept on the device so a user can pass them on.
///
/// A release build shows a failed widget as a grey box and drops other
/// errors on the floor; without this, a crash report is a description and
/// nothing else. The log holds stack traces and error messages, never message
/// text the app handles: errors here are about code, not content.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class ErrorLog {
  ErrorLog._(this._file);

  /// Kept to this size: the newest errors matter, old ones are dropped.
  static const maxBytes = 256 * 1024;

  static ErrorLog? _instance;
  static ErrorLog? get instance => _instance;

  final File _file;
  Future<void> _writing = Future.value();

  /// Starts recording every uncaught error: in widgets, in async code, and
  /// in the platform dispatcher.
  static Future<void> install(Directory dir) async {
    final log = ErrorLog._(File('${dir.path}${Platform.pathSeparator}errors.log'));
    _instance = log;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.record(details.exceptionAsString(), details.stack, context: details.context?.toString());
      previous?.call(details);
    };
    final platform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      log.record('$error', stack);
      return platform?.call(error, stack) ?? true;
    };
  }

  /// Adds one error. Never throws: a log that fails must not cause errors.
  void record(String error, StackTrace? stack, {String? context}) {
    final entry = StringBuffer()
      ..writeln('=== ${DateTime.now().toIso8601String()} ${Platform.operatingSystem} '
          '${const String.fromEnvironment('FROGSTER_VERSION', defaultValue: 'dev')}')
      ..writeln(context == null ? error : '$error ($context)')
      ..writeln(stack ?? '(no stack)');
    _writing = _writing.then((_) async {
      try {
        if (await _file.exists() && await _file.length() > maxBytes) {
          final text = await _file.readAsString();
          await _file.writeAsString(text.substring(text.length - maxBytes ~/ 2));
        }
        await _file.writeAsString(entry.toString(), mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  /// Everything recorded, for the user to copy; empty when nothing went wrong.
  Future<String> read() async {
    await _writing;
    try {
      return await _file.exists() ? await _file.readAsString() : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> clear() async {
    await _writing;
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
