/// Recording a voice message from the chosen microphone.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:frogster_audio/frogster_audio.dart';
import 'package:record/record.dart';

import '../local/preferences.dart';

export 'package:record/record.dart' show InputDevice;

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
Future<List<InputDevice>> listMicrophones() async {
  final recorder = AudioRecorder();
  try {
    return await recorder.listInputDevices();
  } finally {
    await recorder.dispose();
  }
}

/// The settings a recording runs with: the microphone, and what is done to
/// the sound.
RecordConfig recordConfigFor(AppPreferences prefs, {bool nativeDenoise = true}) => RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      device: prefs.microphone == null ? null : InputDevice(id: prefs.microphone!, label: ''),
      // The platform's own suppression only where ours cannot run: doing
      // both makes speech sound underwater.
      noiseSuppress: prefs.noiseSuppression && !nativeDenoise,
      autoGain: prefs.autoGain,
      echoCancel: false,
    );

/// One voice message being recorded.
class VoiceRecording {
  VoiceRecording._(this._recorder, this._pipeline);

  final AudioRecorder _recorder;
  final VoiceMessageRecorder _pipeline;
  StreamSubscription<Uint8List>? _sub;
  Timer? _ticker;

  /// Loudness right now, 0 to 1, for the level meter.
  final level = ValueNotifier<double>(0);

  /// How long so far.
  final elapsed = ValueNotifier<Duration>(Duration.zero);

  var _done = false;

  /// Starts recording, asking for the microphone the first time.
  static Future<VoiceRecording> start(AppPreferences prefs) async {
    final recorder = AudioRecorder();
    try {
      if (!await recorder.hasPermission()) {
        throw const RecordingException(RecordingProblem.permission);
      }
      final native = nativeAudioAvailable;
      final pipeline = VoiceMessageRecorder(
        denoise: prefs.noiseSuppression && native,
        normalize: prefs.autoGain,
      );
      final recording = VoiceRecording._(recorder, pipeline);
      final stream = await recorder.startStream(recordConfigFor(prefs, nativeDenoise: native));
      recording._sub = stream.listen(pipeline.add);
      recording._ticker = Timer.periodic(const Duration(milliseconds: 80), (_) {
        recording.level.value = pipeline.level;
        recording.elapsed.value = pipeline.elapsed;
      });
      return recording;
    } on RecordingException {
      await recorder.dispose();
      rethrow;
    } catch (e) {
      await recorder.dispose();
      throw RecordingException(RecordingProblem.failed, e);
    }
  }

  /// Stops and makes the message; null when it was too short to be one.
  Future<VoiceClip?> finish() async {
    if (_done) return null;
    _done = true;
    await _recorder.stop();
    await _sub?.cancel();
    _ticker?.cancel();
    await _recorder.dispose();
    return _pipeline.finish();
  }

  /// The cleaned sound so far, without stopping: for a microphone test.
  Int16List get samples => _pipeline.samples;

  /// Stops and throws the recording away.
  Future<void> cancel() async {
    if (_done) return;
    _done = true;
    _ticker?.cancel();
    await _sub?.cancel();
    await _recorder.cancel();
    await _recorder.dispose();
    _pipeline.cancel();
  }

  void dispose() {
    level.dispose();
    elapsed.dispose();
  }
}
