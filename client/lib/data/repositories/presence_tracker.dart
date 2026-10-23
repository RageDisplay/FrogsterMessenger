/// Who of the people we talk to is around, and telling the server whether
/// we are.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../remote/api_client.dart';
import '../remote/ws_client.dart';

class PresenceTracker {
  PresenceTracker({
    required WsClient ws,
    required ApiClient api,
    required Future<Iterable<String>> Function() contacts,
  })  : _ws = ws,
        _api = api,
        _contacts = contacts {
    _envelopeSub = _ws.envelopes.listen(_onEnvelope);
    _stateSub = _ws.connectionState.listen((state) {
      if (state == SocketState.connected) unawaited(_onConnected());
    });
  }

  final WsClient _ws;
  final ApiClient _api;
  final Future<Iterable<String>> Function() _contacts;
  late final StreamSubscription<Envelope> _envelopeSub;
  late final StreamSubscription<SocketState> _stateSub;

  /// Everyone's presence as last heard, by user id. Rebuilt on each change,
  /// so listeners can compare old and new.
  final statuses = ValueNotifier<Map<String, Presence>>(const {});

  var _active = true;

  /// What we may see of [userId] right now.
  Presence of(String userId) => statuses.value[userId] ?? Presence.unknown;

  /// The app came to the foreground, or went away from it. In the
  /// background we still get messages, but nobody should see us "online".
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _report();
  }

  void _report() {
    _ws.trySendJson({'v': 1, 'type': EnvelopeType.presence, 'kind': _active ? 'active' : 'idle'});
  }

  Future<void> _onConnected() async {
    // The server takes a new connection for an active one.
    if (!_active) _report();
    await refresh();
  }

  /// Asks for everyone's presence at once: after connecting, nothing has
  /// been heard yet, and while away the announcements were missed.
  Future<void> refresh() async {
    try {
      final ids = (await _contacts()).toSet().toList();
      final fetched = <String, Presence>{};
      // A batch per request, as the server allows.
      for (var i = 0; i < ids.length; i += 200) {
        fetched.addAll(await _api.presence(ids.sublist(i, (i + 200).clamp(0, ids.length))));
      }
      statuses.value = {...statuses.value, ...fetched};
    } catch (_) {
      // Presence is a nicety; the next connection tries again.
    }
  }

  void _onEnvelope(Envelope envelope) {
    if (envelope.type != EnvelopeType.presence) return;
    final userId = envelope.senderUserId;
    if (userId == null) return;
    final timestamp = envelope.timestamp;
    statuses.value = {
      ...statuses.value,
      userId: Presence(
        PresenceStatus.parse(envelope.kind),
        timestamp == null ? null : DateTime.fromMillisecondsSinceEpoch(timestamp),
      ),
    };
  }

  Future<void> dispose() async {
    await _envelopeSub.cancel();
    await _stateSub.cancel();
    statuses.dispose();
  }
}
