/// A voice channel's sound, as the native engine handles it.
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'devices.dart';
import 'native.dart';

final _new = audioLibrary.lookupFunction<Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
    Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, int)>('fa_call_new');
final _devices =
    audioLibrary.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('fa_call_devices');
final _set = audioLibrary.lookupFunction<Void Function(Pointer<Void>, Int32, Int32, Int32, Int32),
    void Function(Pointer<Void>, int, int, int, int)>('fa_call_set');
final _pop = audioLibrary.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Uint8>, Int32, Pointer<Uint16>),
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint16>)>('fa_call_pop');
final _push = audioLibrary.lookupFunction<Void Function(Pointer<Void>, Uint32, Uint16, Pointer<Uint8>, Int32),
    void Function(Pointer<Void>, int, int, Pointer<Uint8>, int)>('fa_call_push');
final _removePeer = audioLibrary
    .lookupFunction<Void Function(Pointer<Void>, Uint32), void Function(Pointer<Void>, int)>('fa_call_remove_peer');
final _setVolume = audioLibrary.lookupFunction<Void Function(Pointer<Void>, Uint32, Float),
    void Function(Pointer<Void>, int, double)>('fa_call_set_volume');
final _micLevel =
    audioLibrary.lookupFunction<Float Function(Pointer<Void>), double Function(Pointer<Void>)>('fa_call_mic_level');
final _peerLevel = audioLibrary.lookupFunction<Float Function(Pointer<Void>, Uint32),
    double Function(Pointer<Void>, int)>('fa_call_peer_level');
final _transmitting =
    audioLibrary.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('fa_call_transmitting');
final _feed = audioLibrary.lookupFunction<Void Function(Pointer<Void>, Pointer<Int16>, Int32),
    void Function(Pointer<Void>, Pointer<Int16>, int)>('fa_call_feed');
final _render = audioLibrary.lookupFunction<Void Function(Pointer<Void>, Pointer<Int16>, Int32),
    void Function(Pointer<Void>, Pointer<Int16>, int)>('fa_call_render');
final _free = audioLibrary.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('fa_call_free');

/// One 20 ms packet of the microphone, numbered.
typedef CallPacket = ({int seq, Uint8List opus});

/// The microphone cleaned, gated on speech and encoded; everyone else
/// decoded, buffered against the network's jitter, and mixed.
///
/// The engine lives in native memory and runs on audio threads of its own;
/// [address] lets another isolate drive the same one through [CallEngine.at].
class CallEngine {
  /// Starts on the given devices (null: the defaults). [devices] false
  /// opens none, for tests that [feed] and [render] by hand.
  factory CallEngine({String? microphone, String? speaker, bool devices = true}) {
    if (!openAudio()) throw const AudioDeviceException('no audio on this device');
    final mic = microphone == null || microphone.isEmpty ? nullptr : microphone.toNativeUtf8();
    final out = speaker == null || speaker.isEmpty ? nullptr : speaker.toNativeUtf8();
    try {
      final state = _new(mic, out, devices ? 1 : 0);
      if (state == nullptr) throw const AudioDeviceException('neither the microphone nor the speaker opened');
      return CallEngine._(state, true);
    } finally {
      if (mic != nullptr) malloc.free(mic);
      if (out != nullptr) malloc.free(out);
    }
  }

  /// The engine another isolate started, by its [address].
  CallEngine.at(int address) : this._(Pointer<Void>.fromAddress(address), false);

  CallEngine._(this._state, this._owner);

  final Pointer<Void> _state;
  final bool _owner;
  final Pointer<Uint8> _packet = malloc<Uint8>(_maxPacket);
  final Pointer<Uint16> _seq = malloc<Uint16>();
  var _closed = false;

  static const _maxPacket = 512;

  int get address => _state.address;

  /// Whether the microphone opened: without it, the channel is listen-only.
  bool get hasMicrophone => _devices(_state) & 1 != 0;
  bool get hasSpeaker => _devices(_state) & 2 != 0;

  /// What the microphone does: off ([muted]), off along with everyone else
  /// ([deafened]), and how it is cleaned.
  void configure({bool muted = false, bool deafened = false, bool denoise = true, bool autoGain = true}) {
    if (_closed) return;
    _set(_state, muted ? 1 : 0, deafened ? 1 : 0, denoise ? 1 : 0, autoGain ? 1 : 0);
  }

  /// The packets ready to go, oldest first.
  List<CallPacket> takePackets() {
    final out = <CallPacket>[];
    if (_closed) return out;
    while (true) {
      final n = _pop(_state, _packet, _maxPacket, _seq);
      if (n <= 0) return out;
      out.add((seq: _seq.value, opus: Uint8List.fromList(_packet.asTypedList(n))));
    }
  }

  /// A packet someone else in the channel sent.
  void push(int member, int seq, Uint8List opus) {
    if (_closed || opus.isEmpty || opus.length > _maxPacket) return;
    _packet.asTypedList(opus.length).setAll(0, opus);
    _push(_state, member, seq & 0xffff, _packet, opus.length);
  }

  /// Someone left: their buffers go.
  void removePeer(int member) {
    if (!_closed) _removePeer(_state, member);
  }

  /// 0 to 2: how loud someone is, here only.
  void setVolume(int member, double volume) {
    if (!_closed) _setVolume(_state, member, volume);
  }

  /// 0 to 1.
  double get micLevel => _closed ? 0 : _micLevel(_state);
  double peerLevel(int member) => _closed ? 0 : _peerLevel(_state, member);

  /// Whether speech is being sent right now.
  bool get transmitting => !_closed && _transmitting(_state) != 0;

  /// For tests: samples as if from the microphone.
  void feed(Int16List pcm) {
    final buffer = malloc<Int16>(pcm.length);
    try {
      buffer.asTypedList(pcm.length).setAll(0, pcm);
      _feed(_state, buffer, pcm.length);
    } finally {
      malloc.free(buffer);
    }
  }

  /// For tests: what the speakers would play next.
  Int16List render(int samples) {
    final buffer = malloc<Int16>(samples);
    try {
      _render(_state, buffer, samples);
      return Int16List.fromList(buffer.asTypedList(samples));
    } finally {
      malloc.free(buffer);
    }
  }

  /// Frees what this handle holds; the engine itself only from the isolate
  /// that started it.
  void close() {
    if (_closed) return;
    _closed = true;
    malloc.free(_packet);
    malloc.free(_seq);
    if (_owner) _free(_state);
  }
}
