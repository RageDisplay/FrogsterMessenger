/// Sound devices: which there are, recording from one, playing to one.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native.dart';

/// A microphone or a speaker.
class AudioDevice {
  const AudioDevice({required this.id, required this.name, this.isDefault = false});

  /// What [MicCapture], [PcmPlayer] and calls take to open this device.
  final String id;
  final String name;
  final bool isDefault;

  @override
  bool operator ==(Object other) => other is AudioDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AudioDevice($name)';
}

final _init = audioLibrary.lookupFunction<Int32 Function(Int32), int Function(int)>('fa_audio_init');
final _devices = audioLibrary
    .lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Int32), int Function(int, Pointer<Utf8>, int)>(
        'fa_audio_devices');

/// Opens the platform's audio system, once. [silent] opens one with no
/// hardware behind it that still keeps time: for tests. Returns false when
/// the device has no audio at all.
bool openAudio({bool silent = false}) => nativeAudioAvailable && _init(silent ? 1 : 0) == 0;

/// The microphones ([capture]) or speakers the system offers.
///
/// On Android this is only the default of each: AAudio cannot list them,
/// so the app asks Android itself and passes those ids instead.
List<AudioDevice> listAudioDevices({required bool capture}) {
  if (!openAudio()) return const [];
  var cap = 16 * 1024;
  while (true) {
    final out = malloc<Uint8>(cap);
    try {
      final needed = _devices(capture ? 1 : 0, out.cast(), cap);
      if (needed < 0) return const [];
      if (needed >= cap) {
        cap = needed + 1;
        continue;
      }
      return parseDeviceList(utf8.decode(out.asTypedList(needed), allowMalformed: true));
    } finally {
      malloc.free(out);
    }
  }
}

/// Reads the native list: lines of id, name and a default flag, by tabs.
List<AudioDevice> parseDeviceList(String text) => [
      for (final line in const LineSplitter().convert(text))
        if (line.split('\t') case [final id, final name, final flag] when id.isNotEmpty)
          AudioDevice(id: id, name: name.trim().isEmpty ? id : name.trim(), isDefault: flag == '1'),
    ];

final _captureNew = audioLibrary.lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Int32),
    Pointer<Void> Function(Pointer<Utf8>, int)>('fa_capture_new');
final _captureRead = audioLibrary.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Int16>, Int32),
    int Function(Pointer<Void>, Pointer<Int16>, int)>('fa_capture_read');
final _captureFree =
    audioLibrary.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_capture_free');

/// Thrown when a microphone or speaker will not open.
class AudioDeviceException implements Exception {
  const AudioDeviceException(this.message);
  final String message;
  @override
  String toString() => 'AudioDeviceException: $message';
}

Pointer<Utf8> _idOrNull(String? id) => id == null || id.isEmpty ? nullptr : id.toNativeUtf8();

/// Recording from a microphone: 48 kHz mono 16-bit, taken as it comes.
class MicCapture {
  /// Opens [deviceId], or the default microphone when it is null or gone.
  /// [voiceCall] asks the platform for its call processing (echo
  /// cancellation on Android) rather than as-plain-as-possible sound.
  MicCapture({String? deviceId, bool voiceCall = false}) {
    if (!openAudio()) throw const AudioDeviceException('no audio on this device');
    final id = _idOrNull(deviceId);
    try {
      _state = _captureNew(id, voiceCall ? 1 : 0);
    } finally {
      if (id != nullptr) malloc.free(id);
    }
    if (_state == nullptr) throw const AudioDeviceException('the microphone did not open');
  }

  static const _chunk = 9600; // 200 ms

  late final Pointer<Void> _state;
  final Pointer<Int16> _buffer = malloc<Int16>(_chunk);
  var _closed = false;

  /// What was recorded since the last call.
  Int16List read() {
    if (_closed) return Int16List(0);
    final out = BytesBuilder(copy: false);
    while (true) {
      final n = _captureRead(_state, _buffer, _chunk);
      if (n <= 0) break;
      out.add(Uint8List.fromList(_buffer.cast<Uint8>().asTypedList(n * 2)));
      if (n < _chunk) break;
    }
    final bytes = out.takeBytes();
    return bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _captureFree(_state);
    malloc.free(_buffer);
  }
}

final _playerNew = audioLibrary.lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Pointer<Int16>, Int64),
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Int16>, int)>('fa_player_new');
final _playerPlay = audioLibrary
    .lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('fa_player_play');
final _playerSeek = audioLibrary
    .lookupFunction<Void Function(Pointer<Void>, Int64), void Function(Pointer<Void>, int)>('fa_player_seek');
final _playerPosition =
    audioLibrary.lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>('fa_player_position');
final _playerPlaying =
    audioLibrary.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('fa_player_playing');
final _playerFree =
    audioLibrary.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_player_free');

/// Plays 48 kHz mono 16-bit samples on a speaker.
class PcmPlayer {
  /// Opens [deviceId] (null or gone: the default speaker) with [pcm]
  /// loaded, paused at the start.
  PcmPlayer(Int16List pcm, {String? deviceId}) : length = pcm.length {
    if (!openAudio()) throw const AudioDeviceException('no audio on this device');
    final samples = malloc<Int16>(pcm.isEmpty ? 1 : pcm.length);
    final id = _idOrNull(deviceId);
    try {
      samples.asTypedList(pcm.length).setAll(0, pcm);
      _state = _playerNew(id, samples, pcm.length);
    } finally {
      malloc.free(samples);
      if (id != nullptr) malloc.free(id);
    }
    if (_state == nullptr) throw const AudioDeviceException('the speaker did not open');
  }

  /// In samples.
  final int length;
  late final Pointer<Void> _state;
  var _closed = false;

  Duration get duration => Duration(microseconds: length * 1000000 ~/ sampleRate);
  Duration get position =>
      _closed ? Duration.zero : Duration(microseconds: _playerPosition(_state) * 1000000 ~/ sampleRate);

  /// False once it reaches the end.
  bool get playing => !_closed && _playerPlaying(_state) != 0;

  /// Plays from where it is; from the start once it has reached the end.
  void play() {
    if (!_closed) _playerPlay(_state, 1);
  }

  void pause() {
    if (!_closed) _playerPlay(_state, 0);
  }

  void seek(Duration to) {
    if (!_closed) _playerSeek(_state, to.inMicroseconds * sampleRate ~/ 1000000);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _playerFree(_state);
  }
}
