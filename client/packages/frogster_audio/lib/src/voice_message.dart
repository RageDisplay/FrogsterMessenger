/// Recording and playing voice messages: clean, level, encode; decode.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'native.dart';
import 'ogg_opus.dart';

/// A finished voice message.
class VoiceClip {
  const VoiceClip({required this.ogg, required this.duration, required this.waveform});

  /// Ogg Opus, playable anywhere.
  final Uint8List ogg;
  final Duration duration;

  /// Base64 of one loudness byte per bar, for drawing.
  final String waveform;
}

/// Bars in a voice message's waveform.
const int waveformBars = 64;

/// Takes microphone audio as it comes -- 16-bit mono at 48 kHz, in chunks of
/// any size -- and makes a voice message of it.
///
/// Noise is removed as the audio arrives, so a long message costs nothing
/// extra at the end; levelling and encoding happen once, off the UI thread.
class VoiceMessageRecorder {
  VoiceMessageRecorder({bool denoise = true, this.normalize = true})
      : _denoiser = denoise && nativeAudioAvailable ? Denoiser() : null;

  /// Brings quiet speech up to a comfortable loudness.
  final bool normalize;

  final Denoiser? _denoiser;
  final _frame = Int16List(frameSamples);
  var _inFrame = 0;
  int? _carry; // the low byte of a sample split across chunks
  final _clean = BytesBuilder(copy: false);
  var _samples = 0;

  /// Loudness of the last frame, 0 to 1, for a live level meter.
  double level = 0;

  /// The cleaned recording so far, for playing back a microphone test.
  Int16List get samples {
    final bytes = _clean.toBytes();
    return Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2);
  }

  /// Recorded so far.
  Duration get elapsed => Duration(microseconds: _samples * 1000000 ~/ sampleRate);

  /// Adds little-endian 16-bit samples.
  void add(Uint8List chunk) {
    var i = 0;
    if (_carry != null && chunk.isNotEmpty) {
      _push(_toInt16(_carry!, chunk[0]));
      _carry = null;
      i = 1;
    }
    for (; i + 1 < chunk.length; i += 2) {
      _push(_toInt16(chunk[i], chunk[i + 1]));
    }
    if (i < chunk.length) _carry = chunk[i];
  }

  static int _toInt16(int lo, int hi) {
    final v = lo | (hi << 8);
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  void _push(int sample) {
    _frame[_inFrame++] = sample;
    if (_inFrame < frameSamples) return;
    _inFrame = 0;
    _denoiser?.process(_frame);
    var sum = 0.0;
    for (final s in _frame) {
      sum += s * s;
    }
    level = math.min(1, math.sqrt(sum / frameSamples) / 8000);
    _clean.add(Uint8List.fromList(_frame.buffer.asUint8List()));
    _samples += frameSamples;
  }

  /// The message, or null when it is too short to be one.
  Future<VoiceClip?> finish({Duration minimum = const Duration(milliseconds: 700)}) async {
    _denoiser?.close();
    if (elapsed < minimum) return null;
    final pcm = _clean.takeBytes();
    final normalize = this.normalize;
    return Isolate.run(
      () => encodeVoice(Int16List.view(pcm.buffer, pcm.offsetInBytes, pcm.length ~/ 2), level: normalize),
    );
  }

  void cancel() => _denoiser?.close();
}

/// Levels and encodes a recording. Public for tests; the recorder calls it
/// in an isolate of its own.
VoiceClip encodeVoice(Int16List pcm, {bool level = true}) {
  if (level) _level(pcm);
  final encoder = VoiceEncoder(bitrate: 24000);
  final writer = OggOpusWriter();
  const packet = 960; // 20 ms
  try {
    for (var at = 0; at < pcm.length; at += packet) {
      final frame = Int16List(packet)..setAll(0, Int16List.sublistView(pcm, at, math.min(at + packet, pcm.length)));
      writer.add(encoder.encode(frame), packet);
    }
  } finally {
    encoder.close();
  }
  return VoiceClip(
    ogg: writer.finish(),
    duration: Duration(microseconds: pcm.length * 1000000 ~/ sampleRate),
    waveform: base64Encode(waveformOf(pcm)),
  );
}

/// Brings a quiet recording up to a comfortable level -- no more than 6x,
/// so silence is not turned into hiss -- and never past the peak.
void _level(Int16List pcm) {
  var peak = 1;
  for (final s in pcm) {
    final a = s.abs();
    if (a > peak) peak = a;
  }
  final gain = math.min(6.0, 29000 / peak);
  if (gain <= 1.05) return;
  for (var i = 0; i < pcm.length; i++) {
    pcm[i] = (pcm[i] * gain).round().clamp(-32768, 32767);
  }
}

/// One loudness byte per bar, scaled so the loudest bar is full height.
Uint8List waveformOf(Int16List pcm, {int bars = waveformBars}) {
  final out = Uint8List(bars);
  if (pcm.isEmpty) return out;
  final rms = List<double>.filled(bars, 0);
  for (var b = 0; b < bars; b++) {
    final from = pcm.length * b ~/ bars;
    final to = math.max(from + 1, pcm.length * (b + 1) ~/ bars);
    var sum = 0.0;
    for (var i = from; i < to && i < pcm.length; i++) {
      sum += pcm[i] * pcm[i];
    }
    rms[b] = math.sqrt(sum / (to - from));
  }
  final top = rms.reduce(math.max);
  if (top == 0) return out;
  for (var b = 0; b < bars; b++) {
    out[b] = (rms[b] / top * 255).round();
  }
  return out;
}

/// A voice message back to samples, the encoder's look-ahead dropped.
Int16List decodeVoice(Uint8List ogg) {
  final stream = readOggOpus(ogg);
  final decoder = VoiceDecoder();
  final out = BytesBuilder(copy: false);
  try {
    for (final packet in stream.packets) {
      final pcm = decoder.decode(packet);
      out.add(pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes));
    }
  } finally {
    decoder.close();
  }
  final bytes = out.takeBytes();
  final all = Int16List.view(bytes.buffer, bytes.offsetInBytes, bytes.length ~/ 2);
  return Int16List.fromList(all.sublist(math.min(stream.preSkip, all.length)));
}

/// A voice message as a WAV file, for the platform player.
Future<Uint8List> voiceToWav(Uint8List ogg) => Isolate.run(() => pcmToWav(decodeVoice(ogg)));
