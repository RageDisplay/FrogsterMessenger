import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/crypto/x3dh.dart';
import 'package:frogster/data/models/models.dart';

/// Reproduces a real two-person conversation at the crypto-engine level,
/// including the exact wire encoding the repository uses.
///
/// The bug this was written to chase: messages were accepted by the server and
/// delivered, but never appeared on the recipient's screen -- the failure was
/// swallowed by a catch in the repository, so nothing pointed at the cause.
void main() {
  group('end-to-end conversation', () {
    late FrogsterCryptoEngine aliceEngine;
    late FrogsterCryptoEngine bobEngine;
    late PublicKeyBundle alicePublished;
    late PublicKeyBundle bobPublished;

    late PeerAddress aliceAddr;
    late PeerAddress bobAddr;

    setUp(() async {
      final aliceKeys = InMemoryKeyStorage();
      final bobKeys = InMemoryKeyStorage();

      aliceEngine = FrogsterCryptoEngine(
        keyStorage: aliceKeys,
        sessionStore: InMemorySessionStore(),
      );
      bobEngine = FrogsterCryptoEngine(
        keyStorage: bobKeys,
        sessionStore: InMemorySessionStore(),
      );

      alicePublished = await aliceEngine.initializeIdentity(
        oneTimePreKeyCount: 5,
      );
      bobPublished = await bobEngine.initializeIdentity(oneTimePreKeyCount: 5);

      aliceAddr = const PeerAddress(userId: 'alice-id', deviceId: 'alice-dev');
      bobAddr = const PeerAddress(userId: 'bob-id', deviceId: 'bob-dev');
    });

    /// Builds the bundle a peer fetches from GET /v1/keys, exactly as
    /// ApiClient would construct it.
    PreKeyBundle bundleFrom(PublicKeyBundle published, String deviceId) {
      final otp = published.oneTimePreKeys.entries.first;
      return PreKeyBundle(
        deviceId: deviceId,
        registrationId: published.registrationId,
        identityKey: deserializePublicKey(published.identityKey),
        identityKeyEd25519: published.identityKeyEd25519,
        signedPreKeyId: published.signedPreKeyId,
        signedPreKey: deserializePublicKey(published.signedPreKey),
        signedPreKeySignature: published.signedPreKeySignature,
        oneTimePreKeyId: otp.key,
        oneTimePreKey: deserializePublicKey(otp.value),
      );
    }

    /// The exact encoding the repository puts on the wire.
    String toWire(EncryptedPayload payload) =>
        base64Encode(utf8.encode(jsonEncode(payload.toJson())));

    EncryptedPayload fromWire(String wire) => EncryptedPayload.fromJson(
          jsonDecode(utf8.decode(base64Decode(wire))) as Map<String, dynamic>,
        );

    test('alice sends, bob receives, bob replies, alice receives', () async {
      // 1. Alice opens the chat and sends the first message. This is a prekey
      //    message: Bob has no session yet.
      await aliceEngine.establishOutboundSession(
        bobAddr,
        bundleFrom(bobPublished, 'bob-dev'),
      );

      final firstPlain = MessagePayload(body: 'hi bob', sentAt: DateTime.now());
      final first = await aliceEngine.encrypt(bobAddr, firstPlain.encode());

      expect(first.cipherType, cipherTypePreKey,
          reason: 'the first message of a session must be a prekey message');

      // 2. It travels through the wire encoding and back.
      final firstReceived = fromWire(toWire(first));

      // 3. Bob decrypts. This completes his half of X3DH.
      final bobGot = await bobEngine.decrypt(aliceAddr, firstReceived);
      expect(MessagePayload.decode(bobGot).body, 'hi bob');

      // 4. Bob replies. Now he has a session, so this is an ordinary message.
      final replyPlain =
          MessagePayload(body: 'hi alice', sentAt: DateTime.now());
      final reply = await bobEngine.encrypt(aliceAddr, replyPlain.encode());

      final replyReceived = fromWire(toWire(reply));
      final aliceGot = await aliceEngine.decrypt(bobAddr, replyReceived);

      expect(MessagePayload.decode(aliceGot).body, 'hi alice',
          reason: 'the reply must decrypt on the original sender');
    });

    test('a conversation continues past the first exchange', () async {
      await aliceEngine.establishOutboundSession(
        bobAddr,
        bundleFrom(bobPublished, 'bob-dev'),
      );

      // Open the session.
      final opening = await aliceEngine.encrypt(
        bobAddr,
        MessagePayload(body: 'opening').encode(),
      );
      await bobEngine.decrypt(aliceAddr, fromWire(toWire(opening)));

      // Several turns each way.
      for (var i = 0; i < 5; i++) {
        final fromBob = await bobEngine.encrypt(
          aliceAddr,
          MessagePayload(body: 'bob $i').encode(),
        );
        final atAlice =
            await aliceEngine.decrypt(bobAddr, fromWire(toWire(fromBob)));
        expect(MessagePayload.decode(atAlice).body, 'bob $i');

        final fromAlice = await aliceEngine.encrypt(
          bobAddr,
          MessagePayload(body: 'alice $i').encode(),
        );
        final atBob =
            await bobEngine.decrypt(aliceAddr, fromWire(toWire(fromAlice)));
        expect(MessagePayload.decode(atBob).body, 'alice $i');
      }
    });

    test('both sides opening a session independently still converge',
        () async {
      // What happens in the app when each user taps "new chat" before the
      // other's first message arrives: both run establishOutboundSession, so
      // there are two competing initial sessions.
      await aliceEngine.establishOutboundSession(
        bobAddr,
        bundleFrom(bobPublished, 'bob-dev'),
      );
      await bobEngine.establishOutboundSession(
        aliceAddr,
        bundleFrom(alicePublished, 'alice-dev'),
      );

      final fromAlice = await aliceEngine.encrypt(
        bobAddr,
        MessagePayload(body: 'from alice').encode(),
      );

      // Bob already has his own outbound session, so his engine does not treat
      // this as a fresh handshake -- which is exactly where a real client can
      // end up unable to decrypt.
      final decrypted = await bobEngine.decrypt(
        aliceAddr,
        fromWire(toWire(fromAlice)),
      );
      expect(MessagePayload.decode(decrypted).body, 'from alice');
    });
  });
}
