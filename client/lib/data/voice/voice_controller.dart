/// Voice channels as the app sees them: which channels each group has, who
/// is in them, and the one this device is talking in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:frogster_audio/frogster_audio.dart';

import '../audio/audio_platform.dart';
import '../local/preferences.dart';
import '../remote/api_client.dart';
import '../remote/server_config.dart';
import '../remote/ws_client.dart';
import 'voice_link.dart';
import 'voice_models.dart';

/// What the controller asks of the server. [ApiClient] is one.
abstract interface class VoiceApi {
  Future<List<VoiceChannel>> voiceChannels(String chatId);
  Future<VoiceChannel> createVoiceChannel(String chatId, String name);
  Future<void> renameVoiceChannel(String chatId, String channelId, String name);
  Future<void> deleteVoiceChannel(String chatId, String channelId);
  Future<VoiceGrant> joinVoice(String chatId, String channelId);
  Future<void> leaveVoice();
  Future<void> setVoiceState({required bool muted, required bool deafened});
  Future<Map<String, List<VoiceRoom>>> activeVoice();
}

/// The sound of one call: the engine and the link to the relay.
abstract interface class VoiceCall {
  /// False when no microphone opened: the call is listen-only.
  bool get hasMicrophone;
  void configure({required bool muted, required bool deafened, required bool denoise, required bool autoGain});
  double get micLevel;
  bool get transmitting;
  double peerLevel(int member);
  void removePeer(int member);
  Stream<VoiceLinkStatus> get status;
  Future<void> close();
}

/// Starts the sound for a channel just joined.
typedef VoiceCallFactory = Future<VoiceCall> Function(VoiceGrant grant, AppPreferences prefs);

/// Why joining did not work.
enum VoiceJoinProblem { full, gone, failed }

class VoiceJoinException implements Exception {
  const VoiceJoinException(this.problem);
  final VoiceJoinProblem problem;
  @override
  String toString() => 'VoiceJoinException(${problem.name})';
}

/// The channel this device is in.
class VoiceSession {
  VoiceSession({
    required this.chatId,
    required this.chatTitle,
    required this.channel,
    required this.grant,
    required this.call,
  });

  final String chatId;
  final String chatTitle;
  final VoiceChannel channel;
  final VoiceGrant grant;
  final VoiceCall call;
  var route = VoiceRoute.connecting;
  Duration? rtt;
  var muted = false;
  var deafened = false;
}

class VoiceController extends ChangeNotifier {
  VoiceController({
    required VoiceApi api,
    required Stream<Envelope> frames,
    required Stream<SocketState> connection,
    required AppPreferences preferences,
    required this.selfUserId,
    required VoiceCallFactory startCall,
    AudioPlatform platform = const NativeAudioPlatform(),
    Duration levelsEvery = const Duration(milliseconds: 100),
  })  : _api = api,
        _prefs = preferences,
        _startCall = startCall,
        _platform = platform {
    _frameSub = frames.listen(_onFrame);
    _connectionSub = connection.listen((s) {
      if (s == SocketState.connected) unawaited(_loadActive());
    });
    _prefs.addListener(_applyPreferences);
    _levels = Timer.periodic(levelsEvery, (_) => _pollLevels());
  }

  final VoiceApi _api;
  final AppPreferences _prefs;
  final VoiceCallFactory _startCall;
  final AudioPlatform _platform;
  final String selfUserId;
  late final StreamSubscription<Envelope> _frameSub;
  late final StreamSubscription<SocketState> _connectionSub;
  StreamSubscription<VoiceLinkStatus>? _statusSub;
  late final Timer _levels;

  final _channels = <String, List<VoiceChannel>>{};
  final _loading = <String>{};
  final _rooms = <String, List<VoiceRoom>>{};
  VoiceSession? _current;
  var _speaking = <String>{};
  var _joining = false;
  var _disposed = false;

  VoiceSession? get current => _current;

  /// Whether a join is under way.
  bool get joining => _joining;

  /// A group's channels with who is in each, fetched the first time asked.
  List<VoiceChannel>? channels(String chatId) {
    final list = _channels[chatId];
    if (list == null) {
      unawaited(refresh(chatId));
      return null;
    }
    final rooms = {for (final r in _rooms[chatId] ?? const <VoiceRoom>[]) r.channelId: r.participants};
    return [for (final c in list) c.withParticipants(rooms[c.id] ?? const [])];
  }

  /// How many people are in a group's channels, for the chat list.
  int peopleIn(String chatId) =>
      (_rooms[chatId] ?? const <VoiceRoom>[]).fold(0, (n, r) => n + r.participants.length);

  /// Whether [userId] is talking right now, in the channel this device is
  /// in; for ourselves, whether the microphone is sending.
  bool isSpeaking(String userId) => _speaking.contains(userId);

  Future<void> refresh(String chatId) async {
    if (!_loading.add(chatId)) return;
    try {
      final list = await _api.voiceChannels(chatId);
      _channels[chatId] = list;
      _rooms[chatId] = [
        for (final c in list)
          if (c.participants.isNotEmpty) VoiceRoom(channelId: c.id, participants: c.participants),
      ];
      _notify();
    } catch (_) {
      // Shown as no channels; the next frame or visit tries again.
      _channels.putIfAbsent(chatId, () => const []);
      _notify();
    } finally {
      _loading.remove(chatId);
    }
  }

  Future<void> _loadActive() async {
    try {
      final active = await _api.activeVoice();
      _rooms
        ..clear()
        ..addAll(active);
      _checkStillIn();
      _notify();
    } catch (_) {
      // The next connection asks again.
    }
  }

  void _onFrame(Envelope e) {
    if (e.type != EnvelopeType.voice) return;
    final chatId = e.chatId;
    if (chatId == null) return;
    if (e.kind == 'channels') {
      if (_channels.containsKey(chatId)) unawaited(refresh(chatId));
      return;
    }
    _rooms[chatId] = [
      for (final r in e.voice ?? const []) VoiceRoom.fromJson(r as Map<String, dynamic>),
    ];
    _checkStillIn();
    _notify();
  }

  /// The server dropped this device -- timed out, removed from the group,
  /// the channel deleted -- or someone left: their buffers go.
  void _checkStillIn() {
    final session = _current;
    if (session == null) return;
    final rooms = _rooms[session.chatId] ?? const <VoiceRoom>[];
    final room = rooms.where((r) => r.channelId == session.channel.id).firstOrNull;
    final members = {for (final p in room?.participants ?? const <VoiceParticipant>[]) p.member};
    if (!members.contains(session.grant.member) && session.route != VoiceRoute.connecting) {
      unawaited(_end(tellServer: false));
      return;
    }
    for (final gone in _known.difference(members)) {
      session.call.removePeer(gone);
    }
    _known = members;
  }

  var _known = <int>{};

  /// Joins [channel] of the group [chatId], leaving any other first.
  Future<void> join(String chatId, VoiceChannel channel, {required String chatTitle}) async {
    if (_joining || _current?.channel.id == channel.id) return;
    _joining = true;
    _notify();
    try {
      if (_current != null) await _end(tellServer: false);
      // Listen-only without the microphone rather than not at all.
      await _platform.requestMicrophone();
      final VoiceGrant grant;
      try {
        grant = await _api.joinVoice(chatId, channel.id);
      } on ApiException catch (e) {
        throw VoiceJoinException(switch (e.statusCode) {
          409 => VoiceJoinProblem.full,
          404 => VoiceJoinProblem.gone,
          _ => VoiceJoinProblem.failed,
        });
      }
      final VoiceCall call;
      try {
        call = await _startCall(grant, _prefs);
      } catch (_) {
        unawaited(_api.leaveVoice().catchError((Object _) {}));
        throw const VoiceJoinException(VoiceJoinProblem.failed);
      }
      final session = VoiceSession(chatId: chatId, chatTitle: chatTitle, channel: channel, grant: grant, call: call)
        ..muted = !call.hasMicrophone;
      _current = session;
      _known = {};
      _applyPreferences();
      _statusSub = call.status.listen((s) {
        if (!identical(_current, session)) return;
        session
          ..route = s.route
          ..rtt = s.rtt ?? session.rtt;
        _notify();
      });
      if (session.muted) unawaited(_api.setVoiceState(muted: true, deafened: false).catchError((Object _) {}));
      unawaited(_platform.callStarted(title: channel.name, text: chatTitle).catchError((Object _) {}));
    } finally {
      _joining = false;
      _notify();
    }
  }

  Future<void> leave() => _end(tellServer: true);

  Future<void> _end({required bool tellServer}) async {
    final session = _current;
    if (session == null) return;
    _current = null;
    _speaking = {};
    _known = {};
    // Off the screen at once; the sound winds down behind it.
    _notify();
    final status = _statusSub;
    _statusSub = null;
    await status?.cancel();
    await session.call.close();
    unawaited(_platform.callEnded().catchError((Object _) {}));
    if (tellServer) {
      try {
        await _api.leaveVoice();
      } catch (_) {
        // The server drops a silent member by itself soon enough.
      }
    }
  }

  Future<void> setMuted(bool muted) async {
    final session = _current;
    if (session == null || (!muted && !session.call.hasMicrophone)) return;
    session.muted = muted;
    if (!muted) session.deafened = false;
    await _changed(session);
  }

  Future<void> setDeafened(bool deafened) async {
    final session = _current;
    if (session == null) return;
    session.deafened = deafened;
    // Hearing again brings the microphone back only if it was on before.
    if (deafened) session.muted = true;
    if (!deafened && session.call.hasMicrophone) session.muted = false;
    await _changed(session);
  }

  Future<void> _changed(VoiceSession session) async {
    _applyPreferences();
    _notify();
    try {
      await _api.setVoiceState(muted: session.muted, deafened: session.deafened);
    } catch (_) {
      // The sound already follows; others see it after the next change.
    }
  }

  void _applyPreferences() {
    final session = _current;
    session?.call.configure(
      muted: session.muted,
      deafened: session.deafened,
      denoise: _prefs.noiseSuppression,
      autoGain: _prefs.autoGain,
    );
  }

  void _pollLevels() {
    final session = _current;
    if (session == null) return;
    final rooms = _rooms[session.chatId] ?? const <VoiceRoom>[];
    final room = rooms.where((r) => r.channelId == session.channel.id).firstOrNull;
    final speaking = <String>{
      if (session.call.transmitting) selfUserId,
      for (final p in room?.participants ?? const <VoiceParticipant>[])
        if (p.member != session.grant.member && session.call.peerLevel(p.member) > 0.02) p.userId,
    };
    if (!setEquals(speaking, _speaking)) {
      _speaking = speaking;
      _notify();
    }
  }

  Future<VoiceChannel> createChannel(String chatId, String name) async {
    final channel = await _api.createVoiceChannel(chatId, name);
    await refresh(chatId);
    return channel;
  }

  Future<void> renameChannel(String chatId, String channelId, String name) async {
    await _api.renameVoiceChannel(chatId, channelId, name);
    await refresh(chatId);
  }

  Future<void> deleteChannel(String chatId, String channelId) async {
    await _api.deleteVoiceChannel(chatId, channelId);
    if (_current?.channel.id == channelId) await _end(tellServer: false);
    await refresh(chatId);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _levels.cancel();
    _prefs.removeListener(_applyPreferences);
    unawaited(_frameSub.cancel());
    unawaited(_connectionSub.cancel());
    unawaited(_end(tellServer: true));
    super.dispose();
  }
}

/// The real thing: the native engine on the chosen devices, and the link
/// in an isolate of its own.
class NativeVoiceCall implements VoiceCall {
  NativeVoiceCall._(this._engine);

  static Future<VoiceCall> start(ServerConfig server, VoiceGrant grant, AppPreferences prefs) async {
    final engine = CallEngine(microphone: prefs.microphone, speaker: prefs.speaker);
    final call = NativeVoiceCall._(engine);
    try {
      call._link = await VoiceLinkIsolate.spawn(
        engine: engine,
        server: server,
        grant: grant,
        onStatus: call._status.add,
      );
    } catch (_) {
      engine.close();
      rethrow;
    }
    return call;
  }

  final CallEngine _engine;
  VoiceLinkIsolate? _link;
  final _status = StreamController<VoiceLinkStatus>.broadcast();

  @override
  bool get hasMicrophone => _engine.hasMicrophone;

  @override
  void configure({required bool muted, required bool deafened, required bool denoise, required bool autoGain}) =>
      _engine.configure(muted: muted, deafened: deafened, denoise: denoise, autoGain: autoGain);

  @override
  double get micLevel => _engine.micLevel;

  @override
  bool get transmitting => _engine.transmitting;

  @override
  double peerLevel(int member) => _engine.peerLevel(member);

  @override
  void removePeer(int member) => _engine.removePeer(member);

  @override
  Stream<VoiceLinkStatus> get status => _status.stream;

  @override
  Future<void> close() async {
    await _link?.stop();
    _engine.close();
    await _status.close();
  }
}
