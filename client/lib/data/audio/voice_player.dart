/// Playing voice messages, one at a time.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:frogster_audio/frogster_audio.dart';

/// Where decoded sound goes: the speakers, or a test.
abstract interface class VoiceOutput {
  Stream<Duration> get onPosition;
  Stream<Duration> get onDuration;
  Stream<void> get onComplete;
  Future<void> play(Uint8List wav);
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration to);
  Future<void> dispose();
}

class _Speakers implements VoiceOutput {
  final _player = AudioPlayer();

  @override
  Stream<Duration> get onPosition => _player.onPositionChanged;
  @override
  Stream<Duration> get onDuration => _player.onDurationChanged;
  @override
  Stream<void> get onComplete => _player.onPlayerComplete;
  @override
  Future<void> play(Uint8List wav) => _player.play(BytesSource(wav, mimeType: 'audio/wav'));
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> resume() => _player.resume();
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration to) => _player.seek(to);
  @override
  Future<void> dispose() => _player.dispose();
}

/// The one voice message playing, shared by every bubble: starting another
/// stops this one, as in any messenger.
class VoicePlayer extends ChangeNotifier {
  VoicePlayer({VoiceOutput? output, Future<Uint8List> Function(Uint8List ogg)? decode})
      : _player = output ?? _Speakers(),
        _decode = decode ?? voiceToWav {
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
  final Future<Uint8List> Function(Uint8List ogg) _decode;
  final _subs = <StreamSubscription<Object?>>[];

  /// Decoded messages, so replaying one does not decode it again.
  final _wav = <String, Uint8List>{};

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
      final wav = _wav[id] ??= await _decode(await ogg());
      if (_current != id) return; // another was started meanwhile
      if (_wav.length > 12) _wav.remove(_wav.keys.first);
      await _player.play(wav);
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
