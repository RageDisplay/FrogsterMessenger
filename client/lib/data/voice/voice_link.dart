/// Carrying a voice channel's sound between the engine and the server's
/// relay: sealed datagrams over UDP, or over a WebSocket where UDP does not
/// get through.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:frogster_audio/frogster_audio.dart';

import '../remote/server_config.dart';
import 'voice_models.dart';
import 'voice_wire.dart';

/// The engine as the link needs it: packets out, packets in.
abstract interface class VoiceEngine {
  List<CallPacket> takePackets();
  void push(int member, int seq, Uint8List opus);
}

class _NativeEngine implements VoiceEngine {
  _NativeEngine(this.engine);
  final CallEngine engine;
  @override
  List<CallPacket> takePackets() => engine.takePackets();
  @override
  void push(int member, int seq, Uint8List opus) => engine.push(member, seq, opus);
}

/// One way to the relay.
abstract interface class VoicePath {
  void send(Uint8List datagram);
  Stream<Uint8List> get datagrams;
  Future<void> close();
}

/// Straight to the relay's UDP port.
class UdpPath implements VoicePath {
  UdpPath._(this._socket, this._to, this._port) {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      for (var d = _socket.receive(); d != null; d = _socket.receive()) {
        // Only the relay is listened to.
        if (d.address == _to && d.port == _port) _in.add(d.data);
      }
    }, onError: (Object _) {});
  }

  static Future<UdpPath> open(String host, int port) async {
    final addresses = await InternetAddress.lookup(host);
    final to = addresses.firstWhere((a) => a.type == InternetAddressType.IPv4, orElse: () => addresses.first);
    final socket = await RawDatagramSocket.bind(
        to.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
    return UdpPath._(socket, to, port);
  }

  final RawDatagramSocket _socket;
  final InternetAddress _to;
  final int _port;
  final _in = StreamController<Uint8List>.broadcast();

  @override
  void send(Uint8List datagram) {
    try {
      _socket.send(datagram, _to, _port);
    } on SocketException {
      // The network is changing under us; the watchdog notices.
    }
  }

  @override
  Stream<Uint8List> get datagrams => _in.stream;

  @override
  Future<void> close() async {
    _socket.close();
    await _in.close();
  }
}

/// Through the server's HTTPS port, for networks that let nothing else out.
class WebSocketPath implements VoicePath {
  WebSocketPath._(this._socket) {
    _socket.listen((m) {
      if (m is List<int>) _in.add(Uint8List.fromList(m));
    }, onError: (Object _) {}, onDone: () => _in.close());
  }

  static Future<WebSocketPath> open(ServerConfig server, String path) async {
    final uri = server.baseUri.replace(scheme: server.isSecure ? 'wss' : 'ws', path: path);
    final socket = await WebSocket.connect(uri.toString(), customClient: server.httpClient())
        .timeout(const Duration(seconds: 10));
    return WebSocketPath._(socket);
  }

  final WebSocket _socket;
  final _in = StreamController<Uint8List>.broadcast();

  @override
  void send(Uint8List datagram) {
    if (_socket.readyState == WebSocket.open) _socket.add(datagram);
  }

  @override
  Stream<Uint8List> get datagrams => _in.stream;

  @override
  Future<void> close() => _socket.close();
}

/// Which way sound is going, if any.
enum VoiceRoute { connecting, udp, relayed }

/// How the link is doing.
class VoiceLinkStatus {
  const VoiceLinkStatus(this.route, {this.rtt});
  final VoiceRoute route;

  /// Round trip to the relay.
  final Duration? rtt;
}

/// Moves packets between the engine and the relay, finds a path that works
/// and keeps it working.
class VoiceLink {
  VoiceLink({
    required VoiceCipher cipher,
    required VoiceEngine engine,
    required Future<VoicePath> Function()? openUdp,
    required Future<VoicePath> Function() openWebSocket,
    void Function(VoiceLinkStatus status)? onStatus,
    this.tick = const Duration(milliseconds: 10),
    this.probe = const Duration(milliseconds: 1500),
    this.silenceLimit = const Duration(seconds: 6),
    this.pingEvery = const Duration(seconds: 1),
  })  : _cipher = cipher,
        _engine = engine,
        _openUdp = openUdp,
        _openWebSocket = openWebSocket,
        _onStatus = onStatus;

  final VoiceCipher _cipher;
  final VoiceEngine _engine;
  final Future<VoicePath> Function()? _openUdp;
  final Future<VoicePath> Function() _openWebSocket;
  final void Function(VoiceLinkStatus status)? _onStatus;

  /// How often packets are taken from the engine.
  final Duration tick;

  /// How long a path has to answer a ping before the next one is tried.
  final Duration probe;

  /// How long without a word from the relay before the path is found again.
  final Duration silenceLimit;

  /// How often the relay is pinged: keeps NAT mappings open, measures the
  /// round trip, and is what the relay answers when nobody talks.
  final Duration pingEvery;

  VoicePath? _path;
  StreamSubscription<Uint8List>? _sub;
  Timer? _pump;
  Timer? _pinger;
  var _route = VoiceRoute.connecting;
  final _watch = Stopwatch()..start();
  var _lastHeard = Duration.zero;
  Completer<void>? _answered;
  var _stopped = false;
  var _connecting = false;

  VoiceRoute get route => _route;

  /// Finds a path and starts moving sound.
  Future<void> start() async {
    _pump = Timer.periodic(tick, (_) => _send());
    _pinger = Timer.periodic(pingEvery, (_) => _ping());
    await _connect();
  }

  /// UDP first: lower delay, no head-of-line blocking. The WebSocket when
  /// UDP gets no answer.
  Future<void> _connect() async {
    if (_connecting || _stopped) return;
    _connecting = true;
    _setRoute(VoiceRoute.connecting);
    try {
      while (!_stopped) {
        if (_openUdp != null && await _tryPath(_openUdp, VoiceRoute.udp)) return;
        if (await _tryPath(_openWebSocket, VoiceRoute.relayed)) return;
        await Future<void>.delayed(probe);
      }
    } finally {
      _connecting = false;
    }
  }

  Future<bool> _tryPath(Future<VoicePath> Function() open, VoiceRoute route) async {
    VoicePath path;
    try {
      path = await open();
    } catch (_) {
      return false;
    }
    if (_stopped) {
      await path.close();
      return false;
    }
    await _usePath(path);
    _answered = Completer<void>();
    // A few pings: one lost on its way does not cost the faster path.
    for (var i = 0; i < 3 && !_answered!.isCompleted; i++) {
      _ping();
      await Future.any([_answered!.future, Future<void>.delayed(probe ~/ 3)]);
    }
    if (_answered!.isCompleted && !_stopped) {
      _setRoute(route);
      return true;
    }
    await _dropPath();
    return false;
  }

  Future<void> _usePath(VoicePath path) async {
    await _dropPath();
    _path = path;
    _sub = path.datagrams.listen(_receive, onDone: () {
      if (identical(_path, path) && !_stopped) {
        _dropPath().then((_) => _connect());
      }
    });
  }

  Future<void> _dropPath() async {
    final path = _path;
    _path = null;
    await _sub?.cancel();
    _sub = null;
    await path?.close();
  }

  void _setRoute(VoiceRoute route, {Duration? rtt}) {
    _route = route;
    _onStatus?.call(VoiceLinkStatus(route, rtt: rtt));
  }

  void _send() {
    final path = _path;
    for (final p in _engine.takePackets()) {
      // Taken even with nowhere to go: stale sound is no use later.
      path?.send(_cipher.audio(p.seq, p.opus));
    }
    if (path != null &&
        _route != VoiceRoute.connecting &&
        _watch.elapsed - _lastHeard > silenceLimit &&
        !_connecting) {
      // Nothing from the relay for a while: the network changed or the
      // path broke. Find one again.
      _lastHeard = _watch.elapsed;
      _dropPath().then((_) => _connect());
    }
  }

  void _ping() {
    final body = ByteData(8)..setUint64(0, _watch.elapsedMicroseconds);
    _path?.send(_cipher.ping(body.buffer.asUint8List()));
  }

  void _receive(Uint8List datagram) {
    final inbound = _cipher.open(datagram);
    if (inbound == null) return;
    _lastHeard = _watch.elapsed;
    switch (inbound) {
      case VoiceAudio(:final member, :final seq, :final opus):
        _engine.push(member, seq, opus);
      case VoicePong(:final body):
        final answered = _answered;
        if (answered != null && !answered.isCompleted) answered.complete();
        if (body.length == 8 && _route != VoiceRoute.connecting) {
          final sent = ByteData.sublistView(body).getUint64(0);
          _setRoute(_route, rtt: Duration(microseconds: _watch.elapsedMicroseconds - sent));
        }
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _pump?.cancel();
    _pinger?.cancel();
    await _dropPath();
  }
}

/// Runs a [VoiceLink] in an isolate of its own, so a busy interface never
/// delays sound.
class VoiceLinkIsolate {
  VoiceLinkIsolate._(this._isolate, this._commands, this._events, this._stopped);

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _events;
  final Completer<void> _stopped;

  /// Starts moving sound between [engine] and the relay of [server], with
  /// the keys in [grant]. [onStatus] hears how it goes.
  static Future<VoiceLinkIsolate> spawn({
    required CallEngine engine,
    required ServerConfig server,
    required VoiceGrant grant,
    required void Function(VoiceLinkStatus status) onStatus,
  }) async {
    final events = ReceivePort();
    final ready = Completer<SendPort>();
    final stopped = Completer<void>();
    events.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m == 'stopped') {
        if (!stopped.isCompleted) stopped.complete();
      } else if (m is List && m.length == 2) {
        onStatus(VoiceLinkStatus(VoiceRoute.values[m[0] as int],
            rtt: m[1] == null ? null : Duration(microseconds: m[1] as int)));
      }
    });
    final isolate = await Isolate.spawn(_main, {
      'events': events.sendPort,
      'engine': engine.address,
      'server': server.toJson(),
      'grant': grant.toJson(),
    }, debugName: 'voice');
    return VoiceLinkIsolate._(isolate, await ready.future, events, stopped);
  }

  static Future<void> _main(Map<String, Object?> args) async {
    final events = args['events']! as SendPort;
    final commands = ReceivePort();
    events.send(commands.sendPort);
    final engine = CallEngine.at(args['engine']! as int);
    final server = ServerConfig.fromJson((args['server']! as Map).cast<String, dynamic>());
    final grant = VoiceGrant.fromJson((args['grant']! as Map).cast<String, dynamic>());
    final link = VoiceLink(
      cipher: VoiceCipher(tag: grant.tag, secret: grant.secret),
      engine: _NativeEngine(engine),
      openUdp: grant.udpPort > 0 ? () => UdpPath.open(server.baseUri.host, grant.udpPort) : null,
      openWebSocket: () => WebSocketPath.open(server, grant.mediaPath),
      onStatus: (s) => events.send([s.route.index, s.rtt?.inMicroseconds]),
    );
    commands.listen((m) async {
      if (m == 'stop') {
        await link.stop();
        engine.close();
        commands.close();
        events.send('stopped');
      }
    });
    await link.start();
  }

  /// Stops the link. The engine stays: whoever started it frees it.
  Future<void> stop() async {
    _commands.send('stop');
    await _stopped.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    _events.close();
    _isolate.kill();
  }
}
