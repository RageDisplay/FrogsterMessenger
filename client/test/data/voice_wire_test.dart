/// Voice datagrams: byte for byte what the server's relay makes and takes.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/voice/voice_wire.dart';

String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List unhex(String s) =>
    Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

VoiceCipher vectorCipher() => VoiceCipher(
      tag: Uint8List.fromList([0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8]),
      secret: Uint8List.fromList(List.generate(32, (i) => i + 1)),
    );

/// From server/internal/voice/manager_test.go, TestWireVector.
const wantUp = '01a1a2a3a4a5a6a7a800000000000000013e11414f59a96c1dcbcc3ef986b046daf3f431';
const wantDown = '01a1a2a3a4a5a6a7a800000000000000010660bd9cd407715a76d02914b1da52144c3ae1';

void main() {
  test('sealing matches the relay, both ways', () {
    final c = vectorCipher();
    expect(hex(c.sealAt(1, Uint8List.fromList([VoiceKind.ping, 0x68, 0x69]))), wantUp);
    expect(hex(c.sealAt(1, Uint8List.fromList([VoiceKind.pong, 0x68, 0x69]), down: true)), wantDown);
    expect(hex(vectorCipher().ping(Uint8List.fromList([0x68, 0x69]))), wantUp, reason: 'the first datagram is 1');
  });

  test("the relay's datagram opens, once", () {
    final c = vectorCipher();
    final pong = c.open(unhex(wantDown));
    expect(pong, isA<VoicePong>());
    expect((pong! as VoicePong).body, [0x68, 0x69]);
    expect(c.open(unhex(wantDown)), isNull, reason: 'a replay');
  });

  test('anything else does not open', () {
    final up = unhex(wantUp);
    expect(vectorCipher().open(up), isNull, reason: 'our own datagram, reflected: the other key');
    final flipped = unhex(wantDown)..[30] ^= 1;
    expect(vectorCipher().open(flipped), isNull);
    final otherTag = unhex(wantDown)..[3] ^= 1;
    expect(vectorCipher().open(otherTag), isNull);
    final version = unhex(wantDown)..[0] = 2;
    expect(vectorCipher().open(version), isNull);
    expect(vectorCipher().open(Uint8List(10)), isNull);
  });

  test('sound from the relay names who said it', () {
    final c = vectorCipher();
    final plain = Uint8List.fromList([VoiceKind.audio, 0, 0, 0, 42, 0x01, 0x02, 9, 9, 9]);
    final got = c.open(c.sealAt(5, plain, down: true));
    expect(got, isA<VoiceAudio>());
    final audio = got! as VoiceAudio;
    expect((audio.member, audio.seq), (42, 0x0102));
    expect(audio.opus, [9, 9, 9]);
  });

  test('reordered datagrams open, each once; ones far behind do not', () {
    final relay = vectorCipher();
    final c = vectorCipher();
    Uint8List pong(int n) => relay.sealAt(n, Uint8List.fromList([VoiceKind.pong]), down: true);
    for (final n in [1, 3, 2, 10, 5]) {
      expect(c.open(pong(n)), isNotNull, reason: '$n');
    }
    for (final n in [1, 3, 10]) {
      expect(c.open(pong(n)), isNull, reason: '$n again');
    }
    expect(c.open(pong(200)), isNotNull);
    expect(c.open(pong(200 - 64)), isNull);
    expect(c.open(pong(200 - 63)), isNotNull);
  });

  test('every datagram going up has a new counter', () {
    final c = vectorCipher();
    final a = c.audio(1, Uint8List.fromList([1]));
    final b = c.audio(1, Uint8List.fromList([1]));
    expect(hex(a.sublist(9, 17)), '0000000000000001');
    expect(hex(b.sublist(9, 17)), '0000000000000002');
    expect(hex(a), isNot(hex(b)));
  });
}
