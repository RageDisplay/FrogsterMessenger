/// What sound needs from the platform beyond the native library: which
/// devices there are, the microphone permission, and staying alive in the
/// background during a call.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:frogster_audio/frogster_audio.dart';

abstract interface class AudioPlatform {
  /// Asks for the microphone when it is not allowed yet. False when refused.
  Future<bool> requestMicrophone();

  /// Microphones ([capture]) or speakers to choose from.
  Future<List<AudioDevice>> devices({required bool capture});

  /// A voice channel started: on Android, a foreground service with the
  /// notification [title] and [text] keeps it alive in the background.
  Future<void> callStarted({required String title, required String text});
  Future<void> callEnded();
}

class NativeAudioPlatform implements AudioPlatform {
  const NativeAudioPlatform();

  static const _channel = MethodChannel('frogster/audio');

  @override
  Future<bool> requestMicrophone() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestMicrophone') ?? false;
  }

  @override
  Future<List<AudioDevice>> devices({required bool capture}) async {
    if (Platform.isAndroid) {
      // AAudio cannot list devices, but takes Android's own device ids.
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>('devices', {'capture': capture});
      return [
        for (final d in list ?? const <Map<Object?, Object?>>[])
          AudioDevice(id: d['id']! as String, name: d['name']! as String),
      ];
    }
    return listAudioDevices(capture: capture);
  }

  @override
  Future<void> callStarted({required String title, required String text}) async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('callStarted', {'title': title, 'text': text});
  }

  @override
  Future<void> callEnded() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('callEnded');
  }
}
