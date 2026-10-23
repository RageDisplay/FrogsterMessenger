/// The link to the relay: which path it takes, what it sends and what it
/// hands the engine, and how it recovers when a path goes quiet.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/voice/voice_link.dart';
import 'package:frogster/data/voice/voice_wire.dart';
import 'package:frogster_audio/frogster_audio.dart' show CallPacket;

final tag = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
final secret = Uint8List.fromList(List.generate(32, (i) => 200 - i));

class FakeEngine implements VoiceEngine {
  final outgoing = <CallPacket>[];
  final heard = <(int, int, String)>[];

  @override
  List<CallPacket> takePackets() {
    final out = [...outgoing];
    outgoing.clear();
    return out;
  }

  @override
  void push(int member, int seq, Uint8List opus) => heard.add((member, seq, utf8.decode(opus)));
}

/// A stand-in relay behind one path: answers pings when [answering], and
/// remembers what it was sent.
class FakeRelay {
  final cipher = VoiceCipher(tag: tag, secret: secret);
  var answering = true;
  var counter = 0;
  final received = <Uint8List>[];

  Uint8List seal(List<int> plain) => cipher.sealAt(++counter, Uint8List.fromList(plain), down: true);

  void onDatagram(FakePath path, Uint8List datagram) {
    final plain = cipher.openAsRelay(datagram);
    if (plain == null) return;
    received.add(plain);
    if (answering && plain[0] == VoiceKind.ping) {
      scheduleMicrotask(() => path.deliver(seal([VoiceKind.pong, ...plain.sublist(1)])));
    }
  }

  /// Audio as the relay forwards it from [member].
  Uint8List audio(int member, int seq, String opus) {
    final b = BytesBuilder()
      ..addByte(VoiceKind.audio)
      ..add((ByteData(4)..setUint32(0, member)).buffer.asUint8List())
      ..add((ByteData(2)..setUint16(0, seq)).buffer.asUint8List())
      ..add(utf8.encode(opus));
    return seal(b.takeBytes());
  }
}

class FakePath implements VoicePath {
  FakePath(this.relay);
  final FakeRelay relay;
  final _in = StreamController<Uint8List>.broadcast(sync: true);
  var closed = false;

  @override
  void send(Uint8List datagram) {
    if (!closed) relay.onDatagram(this, datagram);
  }

  void deliver(Uint8List datagram) {
    if (!closed) _in.add(datagram);
  }

  @override
  Stream<Uint8List> get datagrams => _in.stream;

  @override
  Future<void> close() async {
    closed = true;
    await _in.close();
  }
}

Future<void> eventually(bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  late FakeEngine engine;
  late FakeRelay udpRelay, wsRelay;
  late List<FakePath> udpPaths, wsPaths;
  late List<VoiceLinkStatus> statuses;
  VoiceLink? link;

  setUp(() {
    engine = FakeEngine();
    udpRelay = FakeRelay();
    wsRelay = FakeRelay();
    udpPaths = [];
    wsPaths = [];
    statuses = [];
  });

  tearDown(() async => link?.stop());

  VoiceLink start({bool withUdp = true, Duration silence = const Duration(seconds: 6)}) => link = VoiceLink(
        cipher: VoiceCipher(tag: tag, secret: secret),
        engine: engine,
        openUdp: withUdp ? () async => (udpPaths..add(FakePath(udpRelay))).last : null,
        openWebSocket: () async => (wsPaths..add(FakePath(wsRelay))).last,
        onStatus: statuses.add,
        tick: const Duration(milliseconds: 5),
        probe: const Duration(milliseconds: 150),
        silenceLimit: silence,
        pingEvery: const Duration(milliseconds: 50),
      );

  test('UDP when it answers', () async {
    await start().start();
    expect(link!.route, VoiceRoute.udp);
    expect(wsPaths, isEmpty);
    expect(statuses.first.route, VoiceRoute.connecting);
  });

  test('the WebSocket when UDP does not', () async {
    udpRelay.answering = false;
    await start().start();
    expect(link!.route, VoiceRoute.relayed);
    expect(udpPaths.single.closed, isTrue, reason: 'the dead path is let go');
  });

  test("sound goes out sealed and numbered as the engine made it; others' comes in", () async {
    await start().start();
    engine.outgoing.addAll([
      (seq: 7, opus: Uint8List.fromList(utf8.encode('hello'))),
      (seq: 8, opus: Uint8List.fromList(utf8.encode('world'))),
    ]);
    await eventually(() => udpRelay.received.where((p) => p[0] == VoiceKind.audio).length == 2);
    final audio = udpRelay.received.where((p) => p[0] == VoiceKind.audio).toList();
    expect([for (final p in audio) ByteData.sublistView(p).getUint16(1)], [7, 8]);
    expect(utf8.decode(audio.first.sublist(3)), 'hello');

    final path = udpPaths.single;
    path.deliver(udpRelay.audio(42, 3, 'hi there'));
    path.deliver(udpRelay.audio(42, 3, 'hi there')..[20] ^= 1); // damaged: dropped
    expect(engine.heard, [(42, 3, 'hi there')]);
  });

  test('the round trip is measured', () async {
    await start().start();
    await eventually(() => statuses.any((s) => s.rtt != null));
    expect(statuses.lastWhere((s) => s.rtt != null).rtt, lessThan(const Duration(seconds: 1)));
  });

  test('a path gone quiet is replaced', () async {
    await start(silence: const Duration(milliseconds: 300)).start();
    expect(link!.route, VoiceRoute.udp);
    // The network changes: UDP stops getting through.
    udpRelay.answering = false;
    await eventually(() => wsPaths.isNotEmpty && link!.route == VoiceRoute.relayed);
    expect(udpPaths.first.closed, isTrue);
  });

  test('a path that answers is kept, however long nobody talks', () async {
    await start(silence: const Duration(milliseconds: 300)).start();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(udpPaths.length, 1);
    expect(wsPaths, isEmpty);
    expect(link!.route, VoiceRoute.udp);
  });

  test('without UDP from the server, straight to the WebSocket', () async {
    await start(withUdp: false).start();
    expect(link!.route, VoiceRoute.relayed);
    expect(udpPaths, isEmpty);
  });

  test('stopped, it sends nothing more', () async {
    await start().start();
    await link!.stop();
    final before = udpRelay.received.length;
    engine.outgoing.add((seq: 1, opus: Uint8List.fromList([1])));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(udpRelay.received.length, before);
    expect(engine.outgoing, hasLength(1), reason: 'the engine is no longer drained');
    expect(udpPaths.single.closed, isTrue);
  });
}
