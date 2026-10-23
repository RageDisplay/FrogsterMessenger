/// Recording a voice message from the chosen microphone.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:frogster_audio/frogster_audio.dart';

import '../local/preferences.dart';
import 'audio_platform.dart';

/// Why recording could not start.
enum RecordingProblem { permission, noMicrophone, failed }

class RecordingException implements Exception {
  const RecordingException(this.problem, [this.detail]);

  final RecordingProblem problem;
  final Object? detail;

  @override
  String toString() => 'RecordingException(${problem.name}${detail == null ? '' : ': $detail'})';
}

/// The microphones this device has.
Future<List<AudioDevice>> listMicrophones([AudioPlatform platform = const NativeAudioPlatform()]) =>
    platform.devices(capture: true);

/// The speakers and headphones this device has.
Future<List<AudioDevice>> listSpeakers([AudioPlatform platform = const NativeAudioPlatform()]) =>
    platform.devices(capture: false);

/// One voice message being recorded.
class VoiceRecording {
  VoiceRecording._(this._mic, this._pipeline) {
    _ticker = Timer.periodic(const Duration(milliseconds: 40), (_) => _drain());
  }

  final MicCapture _mic;
  final VoiceMessageRecorder _pipeline;
  late final Timer _ticker;

  /// Loudness right now, 0 to 1, for the level meter.
  final level = ValueNotifier<double>(0);

  /// How long so far.
  final elapsed = ValueNotifier<Duration>(Duration.zero);

  var _done = false;

  /// Starts recording, asking for the microphone the first time.
  static Future<VoiceRecording> start(AppPreferences prefs,
      {AudioPlatform platform = const NativeAudioPlatform()}) async {
    if (!await platform.requestMicrophone()) {
      throw const RecordingException(RecordingProblem.permission);
    }
    if (!nativeAudioAvailable) throw const RecordingException(RecordingProblem.failed);
    final MicCapture mic;
    try {
      mic = MicCapture(deviceId: prefs.microphone);
    } on AudioDeviceException catch (e) {
      throw RecordingException(RecordingProblem.noMicrophone, e);
    }
    return VoiceRecording._(
      mic,
      VoiceMessageRecorder(denoise: prefs.noiseSuppression, normalize: prefs.autoGain),
    );
  }

  void _drain() {
    if (_done) return;
    _pipeline.addSamples(_mic.read());
    level.value = _pipeline.level;
    elapsed.value = _pipeline.elapsed;
  }

  /// Stops and makes the message; null when it was too short to be one.
  Future<VoiceClip?> finish() async {
    if (_done) return null;
    _drain();
    _done = true;
    _ticker.cancel();
    _mic.close();
    return _pipeline.finish();
  }

  /// The cleaned sound so far, without stopping: for a microphone test.
  Int16List get samples => _pipeline.samples;

  /// Stops and throws the recording away.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    _ticker.cancel();
    _mic.close();
    _pipeline.cancel();
  }

  void dispose() {
    level.dispose();
    elapsed.dispose();
  }
}
