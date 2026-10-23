// The voice channel engine, driven by hand: samples in one side, packets
// across, samples out the other. Needs FROGSTER_AUDIO_LIB, like the other
// native tests.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster_audio/frogster_audio.dart';

/// Something the voice detector takes for speech: a voiced vowel, its pitch
/// wandering, its harmonics shaped by the formants of "a", in syllables.
Int16List speech(double seconds, {int seed = 1, double loudness = 6000}) {
  final random = math.Random(seed);
  final n = (seconds * sampleRate).round();
  final out = Int16List(n);
  var phase = 0.0;
  const formants = [(700.0, 130.0), (1220.0, 70.0), (2600.0, 160.0)];
  double envelope(double f) {
    var g = 0.0;
    for (final (centre, width) in formants) {
      g += 1 / (1 + math.pow((f - centre) / width, 2));
    }
    return g;
  }

  final jitter = random.nextDouble();
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final f0 = 140 + 25 * math.sin(2 * math.pi * 0.7 * t + jitter);
    phase += 2 * math.pi * f0 / sampleRate;
    var v = 0.0;
    for (var h = 1; h * f0 < 4000; h++) {
      v += envelope(h * f0) * math.sin(h * phase) / h;
    }
    // Syllables: four a second, with a short gap between.
    final syllable = math.max(0.0, math.sin(math.pi * ((t * 4) % 1)));
    out[i] = (v * loudness * syllable).round().clamp(-32768, 32767);
  }
  return out;
}

double rms(Int16List pcm) {
  if (pcm.isEmpty) return 0;
  var sum = 0.0;
  for (final s in pcm) {
    sum += s * s;
  }
  return math.sqrt(sum / pcm.length);
}

/// Runs [pcm] through [from] and returns the packets it made.
List<CallPacket> send(CallEngine from, Int16List pcm) {
  from.feed(pcm);
  return from.takePackets();
}

/// Renders [seconds] of what [to] plays, 10 ms at a time as a device would.
Int16List listen(CallEngine to, double seconds) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; i < seconds * 100; i++) {
    final chunk = to.render(480);
    out.add(chunk.buffer.asUint8List());
  }
  final bytes = out.takeBytes();
  return bytes.buffer.asInt16List(0, bytes.length ~/ 2);
}

/// Plays [packets] into [to] as a network would deliver them: each when its
/// 20 ms comes (plus [delay] ticks), the speakers taking 20 ms every tick.
/// [lost] are indexes that never arrive. Returns what was played, with
/// [after] seconds more at the end.
Int16List play(CallEngine to, int member, List<CallPacket> packets,
    {Set<int> lost = const {}, int Function(int index)? delay, double after = 0.3}) {
  final first = packets.first.seq;
  final arrivals = <int, List<CallPacket>>{};
  for (final (i, p) in packets.indexed) {
    if (lost.contains(i)) continue;
    final tick = ((p.seq - first) & 0xffff) + (delay?.call(i) ?? 0);
    arrivals.putIfAbsent(tick, () => []).add(p);
  }
  // As long as the packets span, whatever the delays: runs compare.
  final last = ((packets.last.seq - first) & 0xffff) + 4 + (after * 50).round();
  final out = BytesBuilder(copy: false);
  for (var t = 0; t <= last; t++) {
    // Within a tick, newest first: the reordering a network does.
    for (final p in (arrivals[t] ?? const <CallPacket>[]).reversed) {
      to.push(member, p.seq, p.opus);
    }
    out.add(to.render(960).buffer.asUint8List());
  }
  final bytes = out.takeBytes();
  return bytes.buffer.asInt16List(0, bytes.length ~/ 2);
}

void main() {
  final native = Platform.environment['FROGSTER_AUDIO_LIB'] != null;
  late CallEngine alice, bob;

  // First, before anything opens the real audio system.
  setUpAll(() {
    if (native) openAudio(silent: true);
  });

  setUp(() {
    if (!native) return;
    alice = CallEngine(devices: false);
    bob = CallEngine(devices: false);
  });
  tearDown(() {
    if (!native) return;
    alice.close();
    bob.close();
  });

  group('the call engine', () {
    test('speech goes out in 20 ms packets, silence and noise do not', () {
      final talk = send(alice, speech(2));
      expect(talk.length, greaterThan(60), reason: 'two seconds of speech is up to 100 packets');
      for (var i = 1; i < talk.length; i++) {
        expect((talk[i].seq - talk[i - 1].seq) & 0xffff, greaterThanOrEqualTo(1));
      }
      expect(talk.every((p) => p.opus.length < 200), isTrue, reason: '32 kbit/s is 80 bytes a packet');

      // Half a second of the tail still goes, so the ends of words are not
      // cut off; then nothing.
      final tail = send(alice, Int16List(sampleRate));
      expect(tail.length, inInclusiveRange(20, 30));
      final random = math.Random(5);
      final fan = Int16List.fromList([for (var i = 0; i < sampleRate * 8; i++) (random.nextDouble() * 2 - 1) * 2000 ~/ 1]);
      // A fan switched on is taken for speech for a moment, while the
      // suppressor learns it; after that it is not sent at all, even
      // though it now and then sounds like speech for a frame or two.
      expect(send(alice, Int16List.sublistView(fan, 0, sampleRate)).length, lessThan(40));
      expect(send(alice, Int16List.sublistView(fan, sampleRate)), isEmpty, reason: 'a fan is not speech');
      expect(send(alice, Int16List(sampleRate)), isEmpty);
    }, skip: !native);

    test('typing is not sent', () {
      // Key presses: short sharp clicks, a few a second, over quiet.
      final random = math.Random(8);
      final typing = Int16List(sampleRate * 6);
      for (var at = 0; at < typing.length; at += 9000 + random.nextInt(9000)) {
        for (var i = 0; i < 400 && at + i < typing.length; i++) {
          typing[at + i] = ((random.nextDouble() * 2 - 1) * 20000 * math.exp(-i / 60)).round();
        }
      }
      for (var i = 0; i < typing.length; i++) {
        typing[i] += ((random.nextDouble() * 2 - 1) * 150).round();
      }
      expect(send(alice, typing), isEmpty);
    }, skip: !native);

    test('a gap in the numbers is the silence between', () {
      final first = send(alice, speech(1));
      send(alice, Int16List(sampleRate * 2)); // two seconds quiet
      final second = send(alice, speech(1, seed: 2));
      final gap = (second.first.seq - first.last.seq) & 0xffff;
      expect(gap, greaterThan(50), reason: 'numbered every 20 ms whether sent or not');
    }, skip: !native);

    test('muted sends nothing; deafened hears nothing', () {
      alice.configure(muted: true);
      expect(send(alice, speech(1)), isEmpty);
      alice.configure();
      final packets = send(alice, speech(1));
      expect(packets, isNotEmpty);

      bob.configure(deafened: true);
      expect(rms(play(bob, 1, packets)), 0);
      // Deafened means muted too.
      expect(send(bob, speech(1)), isEmpty);
    }, skip: !native);

    test('speech arrives on the other side, all of it', () {
      final packets = send(alice, speech(2));
      final heard = play(bob, 7, packets);
      expect(rms(heard), greaterThan(300));
      // Every packet played: as much sound as was sent, give or take the
      // start of the buffer.
      final first = heard.indexWhere((s) => s != 0);
      final last = heard.lastIndexWhere((s) => s != 0);
      expect(last - first, greaterThan((packets.length - 3) * 960));
      expect(bob.peerLevel(7), greaterThan(0));
      expect(bob.peerLevel(8), 0);
    }, skip: !native);

    test('packets out of order play as if they came in order', () {
      final packets = send(alice, speech(1.5));
      final inOrder = CallEngine(devices: false);
      final expected = play(inOrder, 3, packets, delay: (i) => 1);
      inOrder.close();
      // Each even packet a tick late, arriving after the odd one behind it.
      final heard = play(bob, 3, packets, delay: (i) => i.isEven ? 1 : 0);
      expect(heard, expected);
    }, skip: !native);

    test('a jumpy network is ridden out', () {
      final random = math.Random(11);
      final packets = send(alice, speech(3));
      final heard = play(bob, 3, packets, delay: (i) => random.nextInt(4), after: 0.5);
      final first = heard.indexWhere((s) => s != 0);
      final last = heard.lastIndexWhere((s) => s != 0);
      var silent = 0;
      for (var at = first; at + 960 <= last; at += 960) {
        if (Int16List.sublistView(heard, at, at + 960).every((s) => s == 0)) silent++;
      }
      expect(silent, lessThan(4), reason: 'up to 60 ms late is absorbed by the buffer');
    }, skip: !native);

    test('a burst is not played in full: the delay stays short', () {
      final packets = send(alice, speech(2));
      for (final p in packets) {
        bob.push(4, p.seq, p.opus);
      }
      final heard = listen(bob, 2);
      final last = heard.lastIndexWhere((s) => s != 0);
      expect(last, lessThan(960 * 12), reason: 'far behind, it skips ahead instead of lagging');
    }, skip: !native);

    test('a lost packet is covered, and the rest stays in time', () {
      final packets = send(alice, speech(2));
      final whole = CallEngine(devices: false);
      final reference = play(whole, 4, packets);
      whole.close();
      final heard = play(bob, 4, packets, lost: {30});
      expect(heard.length, reference.length);
      // Concealed, the lost 20 ms is replaced by 20 ms of something: what
      // follows lines up with the reference again. Skipped or padded, it
      // would be shifted, and a shifted voice does not match.
      // Where it was lost there is sound, not 20 ms of nothing.
      int longestSilence(Int16List pcm) {
        final first = pcm.indexWhere((s) => s != 0);
        final last = pcm.lastIndexWhere((s) => s != 0);
        var run = 0, longest = 0;
        for (var i = first; i <= last; i++) {
          run = pcm[i] == 0 ? run + 1 : 0;
          longest = math.max(longest, run);
        }
        return longest;
      }

      expect(longestSilence(heard), lessThan(math.max(200, longestSilence(reference) + 100)));
      final from = 960 * 36, to = 960 * 64;
      final diff = Int16List.fromList([for (var i = from; i < to; i++) heard[i] - reference[i]]);
      expect(rms(diff) / rms(Int16List.sublistView(reference, from, to)), lessThan(0.3));
    }, skip: !native);

    test('a packet from before what was played is dropped, not played late', () {
      final packets = send(alice, speech(1));
      final before = play(bob, 5, packets, lost: {0});
      expect(rms(before), greaterThan(0));
      bob.push(5, packets.first.seq, packets.first.opus);
      expect(rms(listen(bob, 0.5)), 0, reason: 'nothing left to play but the late packet');
    }, skip: !native);

    test('two people talking at once are both heard', () {
      final carol = CallEngine(devices: false);
      final a = send(alice, speech(1, seed: 1));
      final c = send(carol, speech(1, seed: 9, loudness: 3000));
      carol.close();

      Int16List together(CallEngine to, {bool withA = true, bool withC = true}) {
        final out = BytesBuilder(copy: false);
        for (var i = 0; i < math.max(a.length, c.length) + 15; i++) {
          if (withA && i < a.length) to.push(1, a[i].seq, a[i].opus);
          if (withC && i < c.length) to.push(2, c[i].seq, c[i].opus);
          out.add(to.render(960).buffer.asUint8List());
        }
        final bytes = out.takeBytes();
        return bytes.buffer.asInt16List(0, bytes.length ~/ 2);
      }

      final both = together(bob);
      // Both were decoded: each has a level of their own.
      expect(bob.peerLevel(1), greaterThan(0));
      expect(bob.peerLevel(2), greaterThan(0));

      // And both are in what is played: louder than either alone.
      double alone({required bool isA}) {
        final e = CallEngine(devices: false);
        final out = rms(together(e, withA: isA, withC: !isA));
        e.close();
        return out;
      }

      expect(rms(both), greaterThan(math.max(alone(isA: true), alone(isA: false)) * 1.05));
    }, skip: !native);

    test('someone who left is forgotten', () {
      final packets = send(alice, speech(1));
      for (final p in packets.take(10)) {
        bob.push(6, p.seq, p.opus);
      }
      bob.removePeer(6);
      expect(rms(listen(bob, 1)), 0);
      expect(bob.peerLevel(6), 0);
    }, skip: !native);

    test('junk is not taken for a packet', () {
      bob.push(9, 1, Uint8List(0));
      bob.push(9, 2, Uint8List(600)); // longer than any packet
      // Member 0 is no one, however good the sound.
      for (final p in send(alice, speech(1))) {
        bob.push(0, p.seq, p.opus);
      }
      expect(rms(listen(bob, 1)), 0);
    }, skip: !native);
  });

  group('devices with no hardware', () {
    test('the device list parses', () {
      final list = parseDeviceList('{0.0.1}.{abc}\tMicrophone (USB)\t1\n\tno id\t0\nbroken line\n');
      expect(list.single.id, '{0.0.1}.{abc}');
      expect(list.single.name, 'Microphone (USB)');
      expect(list.single.isDefault, isTrue);
    });

    test('recording keeps time', () async {
      final mic = MicCapture();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final got = mic.read();
      mic.close();
      expect(got.length, inInclusiveRange(sampleRate * 0.15, sampleRate * 0.6));
    }, skip: !native);

    test('a player plays to the end, pauses, seeks and replays', () async {
      final player = PcmPlayer(Int16List(sampleRate ~/ 5)); // 200 ms
      expect(player.duration, const Duration(milliseconds: 200));
      expect(player.playing, isFalse);
      player.play();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      player.pause();
      final paused = player.position;
      expect(paused, greaterThan(Duration.zero));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(player.position, paused);
      player.seek(const Duration(milliseconds: 150));
      player.play();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.playing, isFalse, reason: 'it stops at the end by itself');
      expect(player.position, player.duration);
      player.play(); // from the start again
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(player.position, lessThan(const Duration(milliseconds: 150)));
      player.close();
    }, skip: !native);
  });
}
