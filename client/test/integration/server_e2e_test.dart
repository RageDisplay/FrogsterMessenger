/// End-to-end check against a running server, through the real network
/// stack: TLS with a pinned private CA, REST, WebSocket and gRPC.
///
/// Skipped unless pointed at a server:
///
///   FROGSTER_E2E_SERVER=https://localhost
///   FROGSTER_E2E_CA=XXXX-...   (`frogster fingerprint`; private CA only)
///   flutter test --no-pub test/integration/server_e2e_test.dart
///
/// It registers two throwaway accounts, so it spends two of the server's
/// registrations-per-hour for this address.
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
import 'package:frogster/data/remote/file_client.dart';
import 'package:frogster/data/remote/server_config.dart';
import 'package:frogster/data/remote/ws_client.dart';

final _server = Platform.environment['FROGSTER_E2E_SERVER'];
final _ca = Platform.environment['FROGSTER_E2E_CA'];

class _Device {
  _Device(this.config, this.username);

  final ServerConfig config;
  final String username;
  final keys = InMemoryKeyStorage();
  late final crypto = FrogsterCryptoEngine(
    keyStorage: keys,
    sessionStore: InMemorySessionStore(),
  );
  late final api = ApiClient(server: config);
  late final ws = WsClient(server: config, accessToken: api.validAccessToken);
  late final files = FileClient(server: config)..accessToken = api.validAccessToken;
  late AuthTokens tokens;

  final frames = <Envelope>[];
  StreamSubscription<Envelope>? _sub;

  Future<void> register() async {
    final bundle = await crypto.initializeIdentity(oneTimePreKeyCount: 10);
    tokens = await api.register(
      username: username,
      password: 'e2e-password-${username.hashCode}',
      deviceName: 'e2e',
      keys: bundle,
    );
  }

  Future<void> connect() async {
    _sub = ws.envelopes.listen(frames.add);
    await ws.connect();
  }

  Future<Envelope> waitFor(bool Function(Envelope) match) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      for (final f in frames) {
        if (match(f)) return f;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw TimeoutException('no matching frame; got ${frames.map((f) => f.type)}');
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await ws.dispose();
    await files.shutdown();
    api.close();
  }
}

String _name(String prefix) =>
    '${prefix}_${Random().nextInt(1 << 32).toRadixString(36)}';

void main() {
  test('a full exchange through the deployed stack', () async {
    final base = parseServerAddress(_server!).baseUri;
    final ca = _ca;
    final config = ca == null
        ? ServerConfig(baseUri: base)
        : await pinServerCa(base, normalizeFingerprint(ca));
    await probeServer(config);

    final alice = _Device(config, _name('alice'));
    final bob = _Device(config, _name('bob'));
    addTearDown(alice.dispose);
    addTearDown(bob.dispose);

    await alice.register();
    await bob.register();
    await bob.connect();
    await alice.connect();

    // --- an end-to-end encrypted message --------------------------------
    final chat = await alice.api.createChat(
        type: 'direct', mode: ChatMode.secret, peer: bob.username);
    final directory = await alice.api.fetchKeys(bob.username);
    final payloads = <DevicePayloadWire>[];
    for (final bundle in directory.bundles) {
      final peer = PeerAddress(userId: directory.userId, deviceId: bundle.deviceId);
      await alice.crypto.establishOutboundSession(peer, bundle);
      final sealed = await alice.crypto.encrypt(peer, utf8.encode('hello over TLS'));
      payloads.add(DevicePayloadWire(
        userId: directory.userId,
        deviceId: bundle.deviceId,
        cipherType: sealed.cipherType,
        ciphertext: base64Encode(utf8.encode(jsonEncode(sealed.toJson()))),
      ));
    }
    const messageId = 'e2e-msg-1';
    alice.ws.send(Envelope(
      type: EnvelopeType.message,
      id: messageId,
      chatId: chat.id,
      payloads: payloads,
      timestamp: DateTime.now().millisecondsSinceEpoch,
    ));

    final ack = await alice.waitFor((f) => f.type == EnvelopeType.ack);
    expect(ack.id, messageId);

    final received = await bob.waitFor((f) => f.type == EnvelopeType.message);
    expect(received.id, messageId,
        reason: 'recipients must see the id the sender chose');
    final sealed = EncryptedPayload.fromJson(
      jsonDecode(utf8.decode(base64Decode(received.ciphertext!)))
          as Map<String, dynamic>,
    );
    final plain = await bob.crypto.decrypt(
      PeerAddress(userId: alice.tokens.userId, deviceId: alice.tokens.deviceId),
      sealed,
    );
    expect(utf8.decode(plain), 'hello over TLS');
    bob.ws.send(const Envelope(type: EnvelopeType.delivered, ids: [messageId]));

    // --- an attachment over gRPC ------------------------------------------
    final bytes = Uint8List.fromList(List.generate(200 * 1024, (i) => i % 251));
    final key = await alice.files.upload(plaintext: bytes, mimeType: 'application/octet-stream');
    final downloaded = await bob.files.download(key);
    expect(downloaded, bytes);

    // --- token refresh ----------------------------------------------------
    final before = alice.api.refreshToken;
    final refreshed = await alice.api.refresh();
    expect(refreshed.refreshToken, isNot(before), reason: 'refresh tokens rotate');
    expect((await alice.api.preKeyCount()).available, greaterThan(0));

    // --- signed prekey rotation -------------------------------------------
    final upload =
        await bob.crypto.prepareSignedPreKeyRotation(maxAge: Duration.zero);
    await bob.api.rotateSignedPreKey(upload!);
    await bob.crypto.commitSignedPreKeyRotation(upload);
    final rotated = await alice.api.fetchKeys(bob.username);
    expect(rotated.bundles.single.signedPreKeyId, upload.keyId);

    // --- logout ends the session ------------------------------------------
    // Bob's client may have rotated his token on the way here; whatever it
    // holds now must stop working once he signs out.
    final bobToken = bob.api.refreshToken;
    await bob.api.logout();
    bob.api.refreshToken = bobToken;
    await expectLater(bob.api.refresh(), throwsA(isA<ApiException>()));
  }, skip: _server == null ? 'set FROGSTER_E2E_SERVER to run' : false,
      timeout: const Timeout(Duration(minutes: 2)));
}
