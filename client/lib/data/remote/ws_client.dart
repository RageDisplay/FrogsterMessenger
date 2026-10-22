/// Realtime WebSocket transport.
///
/// Frames carry ciphertext only; this layer never sees plaintext. It owns
/// connection lifetime, reconnection with backoff, and the outbound queue that
/// makes a send survive a dropped connection.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'server_config.dart';

/// Envelope types, mirroring the server's `internal/ws/envelope.go`.
class EnvelopeType {
  static const message = 'msg';
  static const ack = 'ack';
  static const receipt = 'receipt';
  static const typing = 'typing';
  static const senderKey = 'skdm';
  static const deviceAdded = 'device_added';
  static const keyChange = 'key_change';
  static const error = 'error';
  static const syncDone = 'sync_done';

  /// Sent by us once inbound messages are stored, so the server stops
  /// keeping them queued for this device.
  static const delivered = 'delivered';

  /// A read position: ours going out, another member's (or another of our
  /// devices') coming in.
  static const read = 'read';

  /// A chat's metadata or membership changed; refetch it.
  static const chatUpdated = 'chat_updated';
}

/// Errors the server reports in a way the client can act on, mirroring
/// `internal/delivery/frames.go`.
class ServerErrors {
  /// The group moved to a new epoch under the sender: make a new sender key
  /// and send again.
  static const staleEpoch = 'stale epoch';
  static const forbidden = 'forbidden';
  static const notFound = 'not found';
  static const rejected = 'rejected';
}

/// Cipher types on the wire.
class CipherTypes {
  /// A cloud chat's payload, readable by the server.
  static const cloud = 0;
  static const senderKey = 3;
}

/// Ciphertext addressed to one specific device.
///
/// A direct message needs one of these per recipient device: every device runs
/// its own ratchet session, so a single shared ciphertext would be
/// undecryptable for all but one of them.
class DevicePayloadWire {
  const DevicePayloadWire({
    required this.userId,
    required this.deviceId,
    required this.cipherType,
    required this.ciphertext,
  });

  final String userId;
  final String deviceId;
  final int cipherType;

  /// Base64 of the encrypted payload.
  final String ciphertext;

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'device_id': deviceId,
        'ct_type': cipherType,
        'ciphertext': ciphertext,
      };
}

/// A frame on the wire.
class Envelope {
  const Envelope({
    required this.type,
    this.version = 1,
    this.id,
    this.chatId,
    this.senderUserId,
    this.senderDeviceId,
    this.recipientUserId,
    this.recipientDeviceId,
    this.cipherType,
    this.ciphertext,
    this.payloads,
    this.contentHint,
    this.timestamp,
    this.seq,
    this.error,
    this.ids,
    this.epoch,
    this.kind,
    this.targetId,
    this.emoji,
  });

  final int version;
  final String type;
  final String? id;
  final String? chatId;
  final String? senderUserId;
  final String? senderDeviceId;
  final String? recipientUserId;
  final String? recipientDeviceId;
  final int? cipherType;

  /// Opaque encrypted payload, base64 on the wire. Used for group messages and
  /// for frames the server routes back to a single device.
  final String? ciphertext;

  /// One ciphertext per recipient device, for direct messages. Takes
  /// precedence over [ciphertext] when present.
  final List<DevicePayloadWire>? payloads;

  final String? contentHint;
  final int? timestamp;
  final int? seq;
  final String? error;

  /// Message ids, for frames about several messages at once.
  final List<String>? ids;

  /// The group epoch a secret-group message or sender key belongs to.
  final int? epoch;

  /// Cloud events only: what the message does to [targetId]. Secret chats
  /// keep this inside the ciphertext.
  final String? kind;
  final String? targetId;
  final String? emoji;

  Map<String, dynamic> toJson() => {
        'v': version,
        'type': type,
        if (id != null) 'id': id,
        if (chatId != null) 'chat_id': chatId,
        if (recipientUserId != null)
          'recipient': {
            'user_id': recipientUserId,
            'device_id': recipientDeviceId,
          },
        if (cipherType != null) 'ct_type': cipherType,
        if (ciphertext != null) 'ciphertext': ciphertext,
        if (payloads != null)
          'payloads': payloads!.map((p) => p.toJson()).toList(),
        if (contentHint != null) 'content_hint': contentHint,
        if (timestamp != null) 'ts': timestamp,
        if (ids != null) 'ids': ids,
        if (seq != null) 'seq': seq,
        if (epoch != null) 'epoch': epoch,
        if (kind != null && kind!.isNotEmpty) 'kind': kind,
        if (targetId != null) 'target_id': targetId,
        if (emoji != null) 'emoji': emoji,
      };

  static Envelope fromJson(Map<String, dynamic> json) {
    final sender = json['sender'] as Map<String, dynamic>?;
    final recipient = json['recipient'] as Map<String, dynamic>?;

    return Envelope(
      version: json['v'] as int? ?? 1,
      type: json['type'] as String,
      id: json['id'] as String?,
      chatId: json['chat_id'] as String?,
      senderUserId: sender?['user_id'] as String?,
      senderDeviceId: sender?['device_id'] as String?,
      recipientUserId: recipient?['user_id'] as String?,
      recipientDeviceId: recipient?['device_id'] as String?,
      cipherType: json['ct_type'] as int?,
      ciphertext: json['ciphertext'] as String?,
      contentHint: json['content_hint'] as String?,
      timestamp: json['ts'] as int?,
      seq: json['seq'] as int?,
      error: json['error'] as String?,
      epoch: json['epoch'] as int?,
      kind: json['kind'] as String?,
      targetId: json['target_id'] as String?,
      emoji: json['emoji'] as String?,
    );
  }
}

/// Connection state, surfaced so the UI can show a banner.
///
/// Named SocketState rather than ConnectionState because Flutter already
/// exports a ConnectionState from its async widgets, and a collision in every
/// UI file that shows connectivity is not worth the shorter name.
enum SocketState { disconnected, connecting, connected }

/// Manages the WebSocket connection.
class WsClient {
  WsClient({
    required this.server,
    required Future<String> Function() accessToken,
    Duration? maxBackoff,
  })  : _accessToken = accessToken,
        _maxBackoff = maxBackoff ?? const Duration(seconds: 30);

  final ServerConfig server;

  /// Supplies a current access token for each connection attempt. Access
  /// tokens live a quarter of an hour; reusing the first one would make
  /// every reconnect after that fail forever.
  final Future<String> Function() _accessToken;
  final Duration _maxBackoff;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;

  final _envelopes = StreamController<Envelope>.broadcast();
  final _connection = StreamController<SocketState>.broadcast();

  /// Frames queued while offline, replayed on reconnect.
  ///
  /// Bounded: an app left offline for a long time must not grow this without
  /// limit. The messages are already persisted locally, so dropping the oldest
  /// queued frame loses a send attempt, not the message.
  final _outbox = <Envelope>[];
  static const _maxOutbox = 500;

  var _state = SocketState.disconnected;
  var _attempt = 0;
  var _closedByUser = false;

  Stream<Envelope> get envelopes => _envelopes.stream;
  Stream<SocketState> get connectionState => _connection.stream;
  SocketState get state => _state;

  /// Opens the connection and keeps it open until [close] is called.
  Future<void> connect() async {
    _closedByUser = false;
    await _open();
  }

  Future<void> _open() async {
    if (_state == SocketState.connecting) return;
    _setState(SocketState.connecting);

    try {
      final token = await _accessToken();

      // The token travels as a subprotocol rather than a query parameter: a
      // query string would be recorded in server access logs and proxy
      // history. The custom client carries the pinned CA, if any.
      final channel = IOWebSocketChannel.connect(
        server.webSocketUri,
        protocols: ['frogster.bearer.$token'],
        customClient: server.httpClient(),
        pingInterval: const Duration(seconds: 25),
      );
      await channel.ready;

      _channel = channel;
      _attempt = 0;
      _setState(SocketState.connected);

      _subscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) => _onDisconnected(),
        onDone: _onDisconnected,
        cancelOnError: true,
      );

      _flushOutbox();
    } catch (_) {
      _onDisconnected();
    }
  }

  void _onFrame(dynamic raw) {
    try {
      final json = jsonDecode(raw as String) as Map<String, dynamic>;
      _envelopes.add(Envelope.fromJson(json));
    } catch (_) {
      // A frame we cannot parse is dropped rather than allowed to kill the
      // subscription and take the whole connection down with it.
    }
  }

  void _onDisconnected() {
    _subscription?.cancel();
    _subscription = null;
    _channel = null;

    if (_closedByUser) {
      _setState(SocketState.disconnected);
      return;
    }

    _setState(SocketState.disconnected);
    _scheduleReconnect();
  }

  /// Reconnects with exponential backoff plus jitter.
  ///
  /// Jitter matters: without it every client disconnected by a server restart
  /// would retry in lockstep and repeatedly knock the server over.
  void _scheduleReconnect() {
    _reconnectTimer?.cancel();

    final exponential = Duration(milliseconds: 500 * (1 << _attempt.clamp(0, 6)));
    final capped = exponential > _maxBackoff ? _maxBackoff : exponential;
    final jitter = Random().nextInt(1000);
    final delay = capped + Duration(milliseconds: jitter);

    _attempt++;
    _reconnectTimer = Timer(delay, () {
      if (!_closedByUser) _open();
    });
  }

  /// Sends a frame, queueing it when offline.
  void send(Envelope envelope) {
    final channel = _channel;
    if (channel == null || _state != SocketState.connected) {
      _enqueue(envelope);
      return;
    }
    try {
      channel.sink.add(jsonEncode(envelope.toJson()));
    } catch (_) {
      _enqueue(envelope);
    }
  }

  /// Sends a frame if connected, without queueing it otherwise. For frames
  /// the caller keeps itself and replays on reconnect: queueing them here as
  /// well would send them twice.
  bool trySend(Envelope envelope) => trySendJson(envelope.toJson());

  /// [trySend] for a frame already in wire form, as the outbox keeps it.
  bool trySendJson(Map<String, dynamic> frame) {
    final channel = _channel;
    if (channel == null || _state != SocketState.connected) return false;
    try {
      channel.sink.add(jsonEncode(frame));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _enqueue(Envelope envelope) {
    if (_outbox.length >= _maxOutbox) _outbox.removeAt(0);
    _outbox.add(envelope);
  }

  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    final pending = List<Envelope>.from(_outbox);
    _outbox.clear();
    for (final envelope in pending) {
      send(envelope);
    }
  }

  void _setState(SocketState state) {
    if (_state == state) return;
    _state = state;
    _connection.add(state);
  }

  /// Closes the connection and stops reconnecting.
  Future<void> close() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    _setState(SocketState.disconnected);
  }

  Future<void> dispose() async {
    await close();
    await _envelopes.close();
    await _connection.close();
  }

  /// Number of frames waiting for a connection, for tests and diagnostics.
  int get queuedCount => _outbox.length;
}
