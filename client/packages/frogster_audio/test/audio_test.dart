// Runs against the native library when FROGSTER_AUDIO_LIB points at a
// build of it; the container tests need nothing native.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster_audio/frogster_audio.dart';

Int16List tone(double hz, double seconds, {double amplitude = 8000}) => Int16List.fromList([
      for (var i = 0; i < (seconds * sampleRate).round(); i++)
        (amplitude * math.sin(2 * math.pi * hz * i / sampleRate)).round(),
    ]);

double energy(Int16List pcm, [int from = 0]) {
  var sum = 0.0;
  for (var i = from; i < pcm.length; i++) {
    sum += pcm[i] * pcm[i];
  }
  return sum / math.max(1, pcm.length - from);
}

void main() {
  final native = Platform.environment['FROGSTER_AUDIO_LIB'] != null;

  group('Ogg Opus container', () {
    test('packets come back as they went in, across page and lacing boundaries', () {
      final writer = OggOpusWriter(serial: 7);
      final packets = [
        for (var i = 0; i < 120; i++) Uint8List.fromList(List.generate(i * 5 % 600, (j) => (i + j) & 0xff)),
      ];
      for (final p in packets) {
        writer.add(p, 960);
      }
      final file = writer.finish();
      final back = readOggOpus(file);
      expect(back.preSkip, opusPreSkip);
      expect(back.packets.length, packets.length);
      for (var i = 0; i < packets.length; i++) {
        expect(back.packets[i], packets[i], reason: 'packet $i');
      }
    });

    test('a damaged page is refused, not half-read', () {
      final writer = OggOpusWriter()..add(Uint8List.fromList([1, 2, 3]), 960);
      final file = writer.finish();
      file[file.length - 2] ^= 0x40;
      expect(() => readOggOpus(file), throwsFormatException);
      expect(() => readOggOpus(Uint8List.fromList('not ogg at all, really'.codeUnits)), throwsFormatException);
    });

    test('WAV header describes the samples', () {
      final wav = pcmToWav(Int16List.fromList([0, 1, -1, 32767]));
      final h = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(h.getUint32(24, Endian.little), sampleRate);
      expect(h.getUint32(40, Endian.little), 8);
      expect(wav.length, 44 + 8);
    });
  });

  test('a waveform is scaled to its loudest bar', () {
    final pcm = Int16List.fromList([...tone(200, 0.5, amplitude: 1000), ...tone(200, 0.5, amplitude: 9000)]);
    final bars = waveformOf(pcm, bars: 4);
    expect(bars[3], 255);
    expect(bars[0], lessThan(60));
  });

  group('native', () {
    test('speech survives Opus: length and loudness', () {
      final pcm = tone(440, 1.0);
      final clip = encodeVoice(Int16List.fromList(pcm));
      expect(clip.duration.inMilliseconds, 1000);
      expect(clip.ogg.length, lessThan(6000), reason: '24 kbit/s is about 3 KB a second');
      final back = decodeVoice(clip.ogg);
      expect((back.length - pcm.length).abs(), lessThan(1000));
      // Levelled up, then encoded: louder than the input, never clipped.
      final ratio = energy(back, 4800) / energy(pcm, 4800);
      expect(ratio, greaterThan(1));
    }, skip: !native);

    test('noise is removed, and not taken for speech', () {
      final random = math.Random(3);
      final noise = Int16List.fromList([for (var i = 0; i < sampleRate; i++) (random.nextDouble() * 2 - 1) * 3000 ~/ 1]);
      final before = energy(noise, sampleRate ~/ 2);
      final denoiser = Denoiser();
      var speech = 0.0;
      for (var at = 0; at + frameSamples <= noise.length; at += frameSamples) {
        final frame = Int16List.sublistView(noise, at, at + frameSamples);
        final copy = Int16List.fromList(frame);
        speech = denoiser.process(copy);
        frame.setAll(0, copy);
      }
      denoiser.close();
      final after = energy(noise, sampleRate ~/ 2);
      expect(10 * math.log(before / after) / math.ln10, greaterThan(15), reason: 'at least 15 dB quieter');
      expect(speech, lessThan(0.5));
    }, skip: !native);

    test('the recorder takes chunks of any size, odd ones included', () async {
      final pcm = tone(300, 1.2);
      final bytes = pcm.buffer.asUint8List();
      final recorder = VoiceMessageRecorder(denoise: false);
      for (var at = 0; at < bytes.length; at += 1023) {
        recorder.add(Uint8List.sublistView(bytes, at, math.min(at + 1023, bytes.length)));
      }
      expect(recorder.elapsed.inMilliseconds, closeTo(1200, 10));
      final clip = await recorder.finish();
      expect(clip, isNotNull);
      expect(clip!.duration.inMilliseconds, closeTo(1200, 10));

      final short = VoiceMessageRecorder(denoise: false)..add(Uint8List(9600));
      expect(await short.finish(), isNull, reason: 'a tap is not a message');
    }, skip: !native);
  });
}
