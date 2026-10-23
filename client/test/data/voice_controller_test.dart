/// The voice channels as the app keeps them: channels, who is where, and
/// the call this device is in.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/audio/audio_platform.dart';
import 'package:frogster/data/local/account_store.dart';
import 'package:frogster/data/local/preferences.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/data/voice/voice_controller.dart';
import 'package:frogster/data/voice/voice_link.dart';
import 'package:frogster/data/voice/voice_models.dart';
import 'package:frogster_audio/frogster_audio.dart' show AudioDevice;

class FakeVoiceApi implements VoiceApi {
  final channels = <String, List<VoiceChannel>>{};
  final active = <String, List<VoiceRoom>>{};
  final calls = <String>[];
  ApiException? joinError;
  var nextMember = 10;
  var fetches = 0;

  @override
  Future<List<VoiceChannel>> voiceChannels(String chatId) async {
    fetches++;
    return channels[chatId] ?? const [];
  }

  @override
  Future<VoiceChannel> createVoiceChannel(String chatId, String name) async {
    calls.add('create $name');
    final c = VoiceChannel(id: 'new', name: name);
    channels[chatId] = [...?channels[chatId], c];
    return c;
  }

  @override
  Future<void> renameVoiceChannel(String chatId, String channelId, String name) async => calls.add('rename $name');

  @override
  Future<void> deleteVoiceChannel(String chatId, String channelId) async => calls.add('delete $channelId');

  @override
  Future<VoiceGrant> joinVoice(String chatId, String channelId) async {
    calls.add('join $channelId');
    if (joinError != null) throw joinError!;
    return VoiceGrant(
      channelId: channelId,
      member: nextMember,
      tag: Uint8List(8),
      secret: Uint8List(32),
      udpPort: 7882,
      mediaPath: '/v1/voice/media',
    );
  }

  @override
  Future<void> leaveVoice() async => calls.add('leave');

  @override
  Future<void> setVoiceState({required bool muted, required bool deafened}) async =>
      calls.add('state muted=$muted deafened=$deafened');

  @override
  Future<Map<String, List<VoiceRoom>>> activeVoice() async => active;
}

class FakeCall implements VoiceCall {
  FakeCall({this.hasMicrophone = true});

  @override
  final bool hasMicrophone;
  final configured = <String>[];
  final removed = <int>[];
  final levels = <int, double>{};
  final statuses = StreamController<VoiceLinkStatus>.broadcast(sync: true);
  var closed = false;
  @override
  var transmitting = false;

  @override
  void configure({required bool muted, required bool deafened, required bool denoise, required bool autoGain}) =>
      configured.add('muted=$muted deafened=$deafened denoise=$denoise agc=$autoGain');

  @override
  double get micLevel => 0;

  @override
  double peerLevel(int member) => levels[member] ?? 0;

  @override
  void removePeer(int member) => removed.add(member);

  @override
  Stream<VoiceLinkStatus> get status => statuses.stream;

  @override
  Future<void> close() async => closed = true;
}

class FakePlatform implements AudioPlatform {
  final calls = <String>[];
  var micAllowed = true;

  @override
  Future<void> callEnded() async => calls.add('ended');

  @override
  Future<void> callStarted({required String title, required String text}) async => calls.add('started $title / $text');

  @override
  Future<List<AudioDevice>> devices({required bool capture}) async => const [];

  @override
  Future<bool> requestMicrophone() async {
    calls.add('mic');
    return micAllowed;
  }
}

Envelope roomsFrame(String chatId, Map<String, List<(int, String)>> rooms) => Envelope(
      type: EnvelopeType.voice,
      chatId: chatId,
      voice: [
        for (final MapEntry(key: channel, value: people) in rooms.entries)
          {
            'channel_id': channel,
            'participants': [
              for (final (member, user) in people) {'member': member, 'user_id': user, 'device_id': 'd$member'},
            ],
          },
      ],
    );

void main() {
  late FakeVoiceApi api;
  late StreamController<Envelope> frames;
  late StreamController<SocketState> connection;
  late AppPreferences prefs;
  late FakePlatform platform;
  late List<FakeCall> calls;
  late VoiceController voice;
  var micInCall = true;

  const general = VoiceChannel(id: 'ch1', name: 'Общий');

  setUp(() {
    api = FakeVoiceApi()..channels['g1'] = [general, const VoiceChannel(id: 'ch2', name: 'Тихий')];
    frames = StreamController<Envelope>.broadcast(sync: true);
    connection = StreamController<SocketState>.broadcast(sync: true);
    prefs = AppPreferences(MemorySecureValues());
    platform = FakePlatform();
    calls = [];
    micInCall = true;
    voice = VoiceController(
      api: api,
      frames: frames.stream,
      connection: connection.stream,
      preferences: prefs,
      selfUserId: 'me',
      platform: platform,
      levelsEvery: const Duration(milliseconds: 5),
      startCall: (grant, prefs) async {
        final call = FakeCall(hasMicrophone: micInCall);
        calls.add(call);
        return call;
      },
    );
  });

  tearDown(() async {
    voice.dispose();
    await frames.close();
    await connection.close();
  });

  Future<void> joinGeneral() async {
    await voice.join('g1', general, chatTitle: 'Пруд');
    // The link found its way.
    calls.last.statuses.add(const VoiceLinkStatus(VoiceRoute.udp, rtt: Duration(milliseconds: 40)));
    frames.add(roomsFrame('g1', {'ch1': [(10, 'me'), (11, 'bob')]}));
  }

  test('channels are fetched once and show who is in them', () async {
    expect(voice.channels('g1'), isNull, reason: 'not fetched yet');
    await Future<void>.delayed(Duration.zero);
    expect(voice.channels('g1')!.map((c) => c.name), ['Общий', 'Тихий']);
    expect(voice.peopleIn('g1'), 0);

    frames.add(roomsFrame('g1', {'ch2': [(3, 'bob'), (4, 'cat')]}));
    final quiet = voice.channels('g1')!.firstWhere((c) => c.id == 'ch2');
    expect(quiet.participants.map((p) => p.userId), ['bob', 'cat']);
    expect(voice.peopleIn('g1'), 2);
    expect(api.fetches, 1);

    // The channels themselves changed: fetched again.
    frames.add(const Envelope(type: EnvelopeType.voice, chatId: 'g1', kind: 'channels'));
    await Future<void>.delayed(Duration.zero);
    expect(api.fetches, 2);
  });

  test('joining starts the call with the settings, and tells the platform', () async {
    await prefs.setNoiseSuppression(false);
    await joinGeneral();
    final session = voice.current!;
    expect(session.channel.id, 'ch1');
    expect(session.route, VoiceRoute.udp);
    expect(session.rtt, const Duration(milliseconds: 40));
    expect(api.calls, ['join ch1']);
    expect(platform.calls, ['mic', 'started Общий / Пруд']);
    expect(calls.single.configured.last, 'muted=false deafened=false denoise=false agc=true');

    await prefs.setAutoGain(false);
    expect(calls.single.configured.last, 'muted=false deafened=false denoise=false agc=false',
        reason: 'settings apply at once, mid-call');
  });

  test('a full channel or a failed start is reported, and leaves nothing behind', () async {
    api.joinError = const ApiException(409, 'the channel is full');
    await expectLater(voice.join('g1', general, chatTitle: 'Пруд'),
        throwsA(isA<VoiceJoinException>().having((e) => e.problem, 'problem', VoiceJoinProblem.full)));
    expect(voice.current, isNull);
    expect(voice.joining, isFalse);

    api.joinError = null;
    final failing = VoiceController(
      api: api,
      frames: frames.stream,
      connection: connection.stream,
      preferences: prefs,
      selfUserId: 'me',
      platform: platform,
      startCall: (_, _) async => throw StateError('no audio'),
    );
    await expectLater(failing.join('g1', general, chatTitle: 'Пруд'), throwsA(isA<VoiceJoinException>()));
    await Future<void>.delayed(Duration.zero);
    expect(api.calls.last, 'leave', reason: 'the server is told, not left holding a place');
    expect(failing.current, isNull);
    failing.dispose();
  });

  test('mute and deafen: the call follows at once, the server is told', () async {
    await joinGeneral();
    final call = calls.single;
    await voice.setMuted(true);
    expect(call.configured.last, startsWith('muted=true deafened=false'));
    expect(api.calls.last, 'state muted=true deafened=false');

    await voice.setDeafened(true);
    expect(call.configured.last, startsWith('muted=true deafened=true'));
    await voice.setDeafened(false);
    expect(call.configured.last, startsWith('muted=false deafened=false'), reason: 'hearing again brings the mic back');
    expect(api.calls.last, 'state muted=false deafened=false');
  });

  test('turning the sound off turns the microphone off too', () async {
    await joinGeneral();
    await voice.setDeafened(true);
    expect(voice.current!.muted, isTrue);
    expect(api.calls.last, 'state muted=true deafened=true');
  });

  test('a frame from before the join does not end the call that is still connecting', () async {
    await voice.join('g1', general, chatTitle: 'Пруд');
    // Who was in the channel a moment ago, without us yet.
    frames.add(roomsFrame('g1', {'ch1': [(11, 'bob')]}));
    await Future<void>.delayed(Duration.zero);
    expect(voice.current, isNotNull);
    expect(calls.single.closed, isFalse);
  });

  test('without a microphone the call is listen-only', () async {
    micInCall = false;
    await joinGeneral();
    expect(voice.current!.muted, isTrue);
    expect(api.calls, contains('state muted=true deafened=false'));
    await voice.setMuted(false);
    expect(voice.current!.muted, isTrue);
  });

  test('who is talking: our microphone, and others by their sound', () async {
    await joinGeneral();
    final call = calls.single;
    call.levels[11] = 0.3;
    call.transmitting = true;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(voice.isSpeaking('bob'), isTrue);
    expect(voice.isSpeaking('me'), isTrue);
    call.levels[11] = 0;
    call.transmitting = false;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(voice.isSpeaking('bob'), isFalse);
    expect(voice.isSpeaking('me'), isFalse);
  });

  test('someone leaving is forgotten by the call', () async {
    await joinGeneral();
    frames.add(roomsFrame('g1', {'ch1': [(10, 'me')]}));
    expect(calls.single.removed, [11]);
    expect(voice.current, isNotNull);
  });

  test('dropped by the server, the call ends', () async {
    await joinGeneral();
    frames.add(roomsFrame('g1', {'ch1': [(11, 'bob')]}));
    await Future<void>.delayed(Duration.zero);
    expect(voice.current, isNull);
    expect(calls.single.closed, isTrue);
    expect(platform.calls.last, 'ended');
    expect(api.calls, isNot(contains('leave')), reason: 'the server already knows');
  });

  test('leaving ends the call and tells everyone', () async {
    await joinGeneral();
    await voice.leave();
    expect(voice.current, isNull);
    expect(calls.single.closed, isTrue);
    expect(api.calls.last, 'leave');
    expect(platform.calls.last, 'ended');
  });

  test('joining another channel moves the call', () async {
    await joinGeneral();
    await voice.join('g1', const VoiceChannel(id: 'ch2', name: 'Тихий'), chatTitle: 'Пруд');
    expect(calls.first.closed, isTrue);
    expect(calls.length, 2);
    expect(voice.current!.channel.id, 'ch2');
  });

  test('after reconnecting, who is where is asked for again', () async {
    api.active['g2'] = [const VoiceRoom(channelId: 'x', participants: [VoiceParticipant(member: 1, userId: 'bob', deviceId: 'd')])];
    connection.add(SocketState.connected);
    await Future<void>.delayed(Duration.zero);
    expect(voice.peopleIn('g2'), 1);
  });

  test('deleting the channel we are in ends the call', () async {
    await joinGeneral();
    await voice.deleteChannel('g1', 'ch1');
    expect(voice.current, isNull);
    expect(api.calls, contains('delete ch1'));
  });
}
