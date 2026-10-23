/// Playing voice messages, one at a time.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:frogster_audio/frogster_audio.dart';

/// Where decoded sound goes: the speakers, or a test.
abstract interface class VoiceOutput {
  Stream<Duration> get onPosition;
  Stream<Duration> get onDuration;
  Stream<void> get onComplete;
  Future<void> play(Int16List pcm);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration to);
  Future<void> dispose();
}

/// The speaker chosen in the settings, through the native library.
class _Speakers implements VoiceOutput {
  _Speakers(this._device);

  final String? Function() _device;
  PcmPlayer? _player;
  Timer? _poll;
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _complete = StreamController<void>.broadcast();

  @override
  Stream<Duration> get onPosition => _position.stream;
  @override
  Stream<Duration> get onDuration => _duration.stream;
  @override
  Stream<void> get onComplete => _complete.stream;

  @override
  Future<void> play(Int16List pcm) async {
    await stop();
    final player = PcmPlayer(pcm, deviceId: _device());
    _player = player;
    _duration.add(player.duration);
    player.play();
    _follow(player);
  }

  /// Reports the position while it plays, and the end when it gets there.
  void _follow(PcmPlayer player) {
    if (_poll?.isActive ?? false) return;
    _poll = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _position.add(player.position);
      if (!player.playing && player.position >= player.duration) {
        _poll?.cancel();
        _complete.add(null);
      }
    });
  }

  @override
  Future<void> pause() async => _player?.pause();

  @override
  Future<void> resume() async {
    final player = _player;
    if (player == null) return;
    player.play();
    _follow(player);
  }

  @override
  Future<void> stop() async {
    _poll?.cancel();
    _player?.close();
    _player = null;
  }

  @override
  Future<void> seek(Duration to) async => _player?.seek(to);

  @override
  Future<void> dispose() async {
    await stop();
    await _position.close();
    await _duration.close();
    await _complete.close();
  }
}

Future<Int16List> _decodeOff(Uint8List ogg) => Isolate.run(() => decodeVoice(ogg));

/// The one voice message playing, shared by every bubble: starting another
/// stops this one, as in any messenger.
class VoicePlayer extends ChangeNotifier {
  /// [speaker] names the output device each time playing starts.
  VoicePlayer({VoiceOutput? output, Future<Int16List> Function(Uint8List ogg)? decode, String? Function()? speaker})
      : _player = output ?? _Speakers(speaker ?? () => null),
        _decode = decode ?? _decodeOff {
    _subs.addAll([
      _player.onPosition.listen((p) {
        _position = p;
        notifyListeners();
      }),
      _player.onDuration.listen((d) {
        _duration = d;
        notifyListeners();
      }),
      _player.onComplete.listen((_) {
        _playing = false;
        _position = Duration.zero;
        notifyListeners();
      }),
    ]);
  }

  final VoiceOutput _player;
  final Future<Int16List> Function(Uint8List ogg) _decode;
  final _subs = <StreamSubscription<Object?>>[];

  /// Decoded messages, so replaying one does not decode it again.
  final _pcm = <String, Int16List>{};

  String? _current;
  var _playing = false;
  var _loading = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  String? get current => _current;
  bool isPlaying(String id) => _current == id && _playing;
  bool isLoading(String id) => _current == id && _loading;

  /// How far into [id], 0 to 1; 0 for any other message.
  double progressOf(String id) {
    if (_current != id || _duration == Duration.zero) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(0, 1);
  }

  Duration positionOf(String id) => _current == id ? _position : Duration.zero;

  /// Plays [id], pausing it if it is playing already. [ogg] fetches the
  /// message when it has not been played yet.
  Future<void> toggle(String id, Future<Uint8List> Function() ogg) async {
    if (_current == id && _playing) {
      await _player.pause();
      _playing = false;
      notifyListeners();
      return;
    }
    if (_current == id && !_loading && _position > Duration.zero) {
      await _player.resume();
      _playing = true;
      notifyListeners();
      return;
    }
    await _player.stop();
    _current = id;
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _loading = true;
    notifyListeners();
    try {
      final pcm = _pcm[id] ??= await _decode(await ogg());
      if (_current != id) return; // another was started meanwhile
      if (_pcm.length > 12) _pcm.remove(_pcm.keys.first);
      await _player.play(pcm);
      _playing = true;
    } finally {
      if (_current == id) _loading = false;
      notifyListeners();
    }
  }

  /// Moves within the message playing now.
  Future<void> seek(String id, double fraction) async {
    if (_current != id || _duration == Duration.zero) return;
    await _player.seek(_duration * fraction);
  }

  Future<void> stop() async {
    await _player.stop();
    _playing = false;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
