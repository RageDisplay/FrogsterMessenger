/// The native library: RNNoise and Opus behind a handful of C functions.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// Samples per 10 ms frame at 48 kHz, the unit everything here works in.
const int frameSamples = 480;

/// The one sample rate used throughout: RNNoise's, and Opus's full band.
const int sampleRate = 48000;

final DynamicLibrary _lib = () {
  // Tests on a PC load the library straight from a build folder.
  final override = Platform.environment['FROGSTER_AUDIO_LIB'];
  if (override != null) return DynamicLibrary.open(override);
  if (Platform.isWindows) return DynamicLibrary.open('frogster_audio.dll');
  if (Platform.isAndroid || Platform.isLinux) return DynamicLibrary.open('libfrogster_audio.so');
  if (Platform.isMacOS || Platform.isIOS) return DynamicLibrary.open('frogster_audio.framework/frogster_audio');
  throw UnsupportedError('no native audio on ${Platform.operatingSystem}');
}();

final _denoiserNew = _lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('fa_denoiser_new');
final _denoiserFree =
    _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_denoiser_free');
final _denoise = _lib.lookupFunction<Float Function(Pointer<Void>, Pointer<Int16>),
    double Function(Pointer<Void>, Pointer<Int16>)>('fa_denoise');
final _encoderNew = _lib.lookupFunction<Pointer<Void> Function(Int32, Int32),
    Pointer<Void> Function(int, int)>('fa_encoder_new');
final _encoderFree =
    _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_encoder_free');
final _encode = _lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Int16>, Int32, Pointer<Uint8>, Int32),
    int Function(Pointer<Void>, Pointer<Int16>, int, Pointer<Uint8>, int)>('fa_encode');
final _decoderNew = _lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('fa_decoder_new');
final _decoderFree =
    _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_decoder_free');
final _decode = _lib.lookupFunction<
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Int16>, Int32, Int32),
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Int16>, int, int)>('fa_decode');

/// Whether the native library loads on this device.
bool get nativeAudioAvailable {
  try {
    _lib;
    return true;
  } catch (_) {
    return false;
  }
}

/// Removes background noise from speech: fans, traffic, keyboards.
///
/// Holds state from frame to frame, so one per stream.
class Denoiser {
  Denoiser() : _state = _denoiserNew() {
    if (_state == nullptr) throw StateError('could not create a denoiser');
  }

  final Pointer<Void> _state;
  final Pointer<Int16> _frame = malloc<Int16>(frameSamples);
  var _closed = false;

  /// Cleans one [frameSamples]-long frame in place. Returns how likely it is
  /// to be speech, 0 to 1.
  double process(Int16List frame) {
    if (_closed) throw StateError('denoiser closed');
    if (frame.length != frameSamples) throw ArgumentError('a frame is $frameSamples samples');
    _frame.asTypedList(frameSamples).setAll(0, frame);
    final speech = _denoise(_state, _frame);
    frame.setAll(0, _frame.asTypedList(frameSamples));
    return speech;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _denoiserFree(_state);
    malloc.free(_frame);
  }
}

/// Opus for speech, mono, 48 kHz.
class VoiceEncoder {
  /// [expectedLoss] above zero adds redundancy for live calls, where
  /// packets get lost; a recorded message has no losses to plan for.
  VoiceEncoder({int bitrate = 24000, int expectedLoss = 0}) : _state = _encoderNew(bitrate, expectedLoss) {
    if (_state == nullptr) throw StateError('could not create an Opus encoder');
  }

  static const _maxSamples = 2880; // 60 ms
  static const _maxPacket = 4000;

  final Pointer<Void> _state;
  final Pointer<Int16> _pcm = malloc<Int16>(_maxSamples);
  final Pointer<Uint8> _out = malloc<Uint8>(_maxPacket);
  var _closed = false;

  /// One packet for [pcm]: 2.5, 5, 10, 20, 40 or 60 ms of samples.
  Uint8List encode(Int16List pcm) {
    if (_closed) throw StateError('encoder closed');
    if (pcm.length > _maxSamples) throw ArgumentError('at most $_maxSamples samples');
    _pcm.asTypedList(pcm.length).setAll(0, pcm);
    final n = _encode(_state, _pcm, pcm.length, _out, _maxPacket);
    if (n < 0) throw StateError('Opus encoding failed: $n');
    return Uint8List.fromList(_out.asTypedList(n));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _encoderFree(_state);
    malloc.free(_pcm);
    malloc.free(_out);
  }
}

/// Opus back to samples.
class VoiceDecoder {
  VoiceDecoder() : _state = _decoderNew() {
    if (_state == nullptr) throw StateError('could not create an Opus decoder');
  }

  static const _maxSamples = 5760; // 120 ms, the longest packet
  static const _maxPacket = 4000;

  final Pointer<Void> _state;
  final Pointer<Int16> _pcm = malloc<Int16>(_maxSamples);
  final Pointer<Uint8> _in = malloc<Uint8>(_maxPacket);
  var _closed = false;

  /// The samples in [packet]. A null packet was lost: the decoder fills the
  /// gap with something plausible, [frames] samples long.
  Int16List decode(Uint8List? packet, {int frames = 960, bool fec = false}) {
    if (_closed) throw StateError('decoder closed');
    int n;
    if (packet == null) {
      n = _decode(_state, nullptr, 0, _pcm, frames, 0);
    } else {
      if (packet.length > _maxPacket) throw ArgumentError('packet too long');
      _in.asTypedList(packet.length).setAll(0, packet);
      n = _decode(_state, _in, packet.length, _pcm, fec ? frames : _maxSamples, fec ? 1 : 0);
    }
    if (n < 0) throw FormatException('not an Opus packet ($n)');
    return Int16List.fromList(_pcm.asTypedList(n));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _decoderFree(_state);
    malloc.free(_pcm);
    malloc.free(_in);
  }
}
