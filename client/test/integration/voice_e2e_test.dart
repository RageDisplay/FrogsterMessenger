/// Voice channels against a running server: REST to make and join a
/// channel, the `voice` frames over the WebSocket, and sound through the
/// relay over UDP and over the WebSocket path.
///
/// Skipped unless pointed at a server, like server_e2e_test.dart:
///
///   FROGSTER_E2E_SERVER=http://localhost:8080
///   flutter test --no-pub test/integration/voice_e2e_test.dart
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/data/remote/server_config.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/data/voice/voice_link.dart';
import 'package:frogster/data/voice/voice_models.dart';
import 'package:frogster/data/voice/voice_wire.dart';
import 'package:frogster_audio/frogster_audio.dart' show CallEngine, CallPacket;

final _server = Platform.environment['FROGSTER_E2E_SERVER'];
final _ca = Platform.environment['FROGSTER_E2E_CA'];

/// An engine that says what it is told to and remembers what it heard.
class _Engine implements VoiceEngine {
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

class _Person {
  _Person(this.config, this.username);

  final ServerConfig config;
  final String username;
  late final crypto = FrogsterCryptoEngine(keyStorage: InMemoryKeyStorage(), sessionStore: InMemorySessionStore());
  late final api = ApiClient(server: config);
  late final ws = WsClient(server: config, accessToken: api.validAccessToken);
  final frames = <Envelope>[];
  final engine = _Engine();
  VoiceLink? link;
  final routes = <VoiceRoute>[];

  Future<void> register() async {
    final bundle = await crypto.initializeIdentity(oneTimePreKeyCount: 2);
    await api.register(username: username, password: 'e2e-password-${username.hashCode}', deviceName: 'e2e', keys: bundle);
    ws.envelopes.listen(frames.add);
    await ws.connect();
  }

  Future<void> talk(VoiceGrant grant, {required bool udp}) async {
    link = VoiceLink(
      cipher: VoiceCipher(tag: grant.tag, secret: grant.secret),
      engine: engine,
      openUdp: udp && grant.udpPort > 0 ? () => UdpPath.open(config.baseUri.host, grant.udpPort) : null,
      openWebSocket: () => WebSocketPath.open(config, grant.mediaPath),
      onStatus: (s) => routes.add(s.route),
    );
    await link!.start();
  }

  Future<List<VoiceRoom>> roomsIn(String chatId, bool Function(List<VoiceRoom>) match) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final f in frames.reversed) {
        if (f.type == EnvelopeType.voice && f.chatId == chatId && f.kind != 'channels') {
          final rooms = [for (final r in f.voice ?? const []) VoiceRoom.fromJson(r as Map<String, dynamic>)];
          if (match(rooms)) return rooms;
          break;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('no matching voice frame');
  }

  Future<void> dispose() async {
    await link?.stop();
    await ws.dispose();
    api.close();
  }
}

String _name(String prefix) => '${prefix}_${Random().nextInt(1 << 32).toRadixString(36)}';

/// A voiced vowel in syllables, which the engine's voice detector takes
/// for speech (as in the package's own tests).
Int16List speechLike(double seconds) {
  final n = (seconds * 48000).round();
  final out = Int16List(n);
  var phase = 0.0;
  const formants = [(700.0, 130.0), (1220.0, 70.0), (2600.0, 160.0)];
  for (var i = 0; i < n; i++) {
    final t = i / 48000;
    final f0 = 140 + 25 * sin(2 * pi * 0.7 * t);
    phase += 2 * pi * f0 / 48000;
    var v = 0.0;
    for (var h = 1; h * f0 < 4000; h++) {
      var g = 0.0;
      for (final (centre, width) in formants) {
        g += 1 / (1 + pow((h * f0 - centre) / width, 2));
      }
      v += g * sin(h * phase) / h;
    }
    out[i] = (v * 6000 * max(0.0, sin(pi * ((t * 4) % 1)))).round().clamp(-32768, 32767);
  }
  return out;
}

Future<void> eventually(bool Function() done, {Duration within = const Duration(seconds: 10)}) async {
  final deadline = DateTime.now().add(within);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('speech through the real engine, the link in its own isolate, the relay and back', () async {
    final config = ServerConfig(baseUri: Uri.parse(_server!));
    final alice = _Person(config, _name('ea'));
    final bob = _Person(config, _name('eb'));
    CallEngine? aEngine, bEngine;
    VoiceLinkIsolate? aLink, bLink;
    try {
      await alice.register();
      await bob.register();
      final group = await alice.api.createChat(type: 'group', mode: ChatMode.cloud, title: 'Эфир', members: [bob.username]);
      final channel = await alice.api.createVoiceChannel(group.id, 'Общий');
      final aGrant = await alice.api.joinVoice(group.id, channel.id);
      final bGrant = await bob.api.joinVoice(group.id, channel.id);

      aEngine = CallEngine(devices: false);
      bEngine = CallEngine(devices: false);
      final routes = <VoiceRoute>[];
      aLink = await VoiceLinkIsolate.spawn(engine: aEngine, server: config, grant: aGrant, onStatus: (s) => routes.add(s.route));
      bLink = await VoiceLinkIsolate.spawn(engine: bEngine, server: config, grant: bGrant, onStatus: (s) => routes.add(s.route));
      await eventually(() => routes.where((r) => r != VoiceRoute.connecting).length >= 2);

      // Two seconds of a voice into Alice's microphone, in real time, while
      // Bob's speakers take their 20 ms each tick.
      final voice = speechLike(2);
      final heard = <int>[];
      final clock = Stopwatch()..start();
      for (var t = 0; t < 150; t++) {
        if (t < 100) aEngine.feed(Int16List.sublistView(voice, t * 960, (t + 1) * 960));
        heard.addAll(bEngine.render(960));
        final next = Duration(milliseconds: 20 * (t + 1));
        if (clock.elapsed < next) await Future<void>.delayed(next - clock.elapsed);
      }
      final loud = heard.where((s) => s.abs() > 500).length;
      expect(loud, greaterThan(960 * 20), reason: 'most of what Alice said came out of Bob');
      expect(bEngine.peerLevel(aGrant.member), greaterThanOrEqualTo(0));
    } finally {
      await aLink?.stop();
      await bLink?.stop();
      aEngine?.close();
      bEngine?.close();
      await alice.dispose();
      await bob.dispose();
    }
  },
      skip: _server == null || Platform.environment['FROGSTER_AUDIO_LIB'] == null
          ? 'set FROGSTER_E2E_SERVER and FROGSTER_AUDIO_LIB to run'
          : false,
      timeout: const Timeout(Duration(minutes: 2)));

  test('two people in a voice channel hear each other, over UDP and over the WebSocket', () async {
    var config = ServerConfig(baseUri: Uri.parse(_server!));
    final ca = _ca;
    if (ca != null) config = await pinServerCa(config.baseUri, normalizeFingerprint(ca));

    final alice = _Person(config, _name('va'));
    final bob = _Person(config, _name('vb'));
    try {
      await alice.register();
      await bob.register();
      final group = await alice.api.createChat(
          type: 'group', mode: ChatMode.cloud, title: 'Голос', members: [bob.username]);
      final channel = await alice.api.createVoiceChannel(group.id, 'Общий');
      expect((await bob.api.voiceChannels(group.id)).single.name, 'Общий');

      final aGrant = await alice.api.joinVoice(group.id, channel.id);
      final bGrant = await bob.api.joinVoice(group.id, channel.id);
      final rooms = await bob.roomsIn(group.id, (r) => r.length == 1 && r.single.participants.length == 2);
      expect(rooms.single.participants.map((p) => p.member).toSet(), {aGrant.member, bGrant.member});

      // Alice over UDP, Bob only through the WebSocket path.
      await alice.talk(aGrant, udp: true);
      await bob.talk(bGrant, udp: false);
      await eventually(() => alice.link!.route != VoiceRoute.connecting && bob.link!.route != VoiceRoute.connecting);
      expect(alice.link!.route, aGrant.udpPort > 0 ? VoiceRoute.udp : VoiceRoute.relayed);
      expect(bob.link!.route, VoiceRoute.relayed);

      for (var i = 1; i <= 20; i++) {
        alice.engine.outgoing.add((seq: i, opus: Uint8List.fromList(utf8.encode('a$i'))));
        bob.engine.outgoing.add((seq: 100 + i, opus: Uint8List.fromList(utf8.encode('b$i'))));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await eventually(() => bob.engine.heard.length >= 18 && alice.engine.heard.length >= 18);
      expect(bob.engine.heard.every((h) => h.$1 == aGrant.member && h.$3 == 'a${h.$2}'), isTrue);
      expect(alice.engine.heard.every((h) => h.$1 == bGrant.member && h.$3 == 'b${h.$2 - 100}'), isTrue);

      // Muted: still in the channel, no longer heard.
      await alice.api.setVoiceState(muted: true, deafened: false);
      await bob.roomsIn(group.id, (r) => r.single.participants.any((p) => p.member == aGrant.member && p.muted));
      final before = bob.engine.heard.length;
      alice.engine.outgoing.add((seq: 50, opus: Uint8List.fromList(utf8.encode('a50'))));
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(bob.engine.heard.length, before);

      await alice.api.leaveVoice();
      await bob.roomsIn(group.id, (r) => r.single.participants.length == 1);
    } finally {
      await alice.dispose();
      await bob.dispose();
    }
  }, skip: _server == null ? 'set FROGSTER_E2E_SERVER to run' : false, timeout: const Timeout(Duration(minutes: 2)));
}
