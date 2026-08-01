import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/crypto_engine.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/safety_number.dart';
import 'package:frogster/crypto/secure_key_storage.dart';
import 'package:frogster/crypto/stores/memory_session_store.dart';
import 'package:frogster/crypto/x3dh.dart';

/// A device with its own engine and storage, as one installation would have.
class _Endpoint {
  _Endpoint(this.userId, this.deviceId)
      : keys = InMemoryKeyStorage(),
        sessions = InMemorySessionStore();

  final String userId;
  final String deviceId;
  final InMemoryKeyStorage keys;
  final InMemorySessionStore sessions;

  late FrogsterCryptoEngine engine;
  late PublicKeyBundle published;

  PeerAddress get address =>
      PeerAddress(userId: userId, deviceId: deviceId);

  Future<void> start({
    int preKeys = 10,
    TrustPolicy trustPolicy = TrustPolicy.notifyAndReestablish,
  }) async {
    engine = FrogsterCryptoEngine(
      keyStorage: keys,
      sessionStore: sessions,
      trustPolicy: trustPolicy,
    );
    published = await engine.initializeIdentity(oneTimePreKeyCount: preKeys);
  }

  /// Builds the bundle a peer would fetch from the server for this device.
  PreKeyBundle bundleForPeer() {
    final otpEntry = published.oneTimePreKeys.entries.first;
    return PreKeyBundle(
      deviceId: deviceId,
      registrationId: published.registrationId,
      identityKey: deserializePublicKey(published.identityKey),
      identityKeyEd25519: published.identityKeyEd25519,
      signedPreKeyId: published.signedPreKeyId,
      signedPreKey: deserializePublicKey(published.signedPreKey),
      signedPreKeySignature: published.signedPreKeySignature,
      oneTimePreKeyId: otpEntry.key,
      oneTimePreKey: deserializePublicKey(otpEntry.value),
    );
  }
}

void main() {
  group('identity initialisation', () {
    test('creates a publishable bundle', () async {
      final alice = _Endpoint('alice', 'dev-1');
      await alice.start(preKeys: 5);

      expect(alice.published.identityKey.length, djbPublicKeyLength);
      expect(alice.published.identityKeyEd25519.length, 32);
      expect(alice.published.signedPreKeySignature.length, 64);
      expect(alice.published.oneTimePreKeys.length, 5);
      expect(alice.published.registrationId, greaterThan(0));
    });

    test('is stable across restarts', () async {
      final alice = _Endpoint('alice', 'dev-1');
      await alice.start(preKeys: 3);
      final firstIdentity = alice.published.identityKey;
      final firstRegistration = alice.published.registrationId;

      // Restart: same storage, new engine instance.
      alice.engine = FrogsterCryptoEngine(
        keyStorage: alice.keys,
        sessionStore: alice.sessions,
      );
      final second = await alice.engine.initializeIdentity(oneTimePreKeyCount: 3);

      expect(second.identityKey, equals(firstIdentity),
          reason: 'a new identity would orphan every existing session');
      expect(second.registrationId, firstRegistration);
    });

    test('the published bundle contains no private material', () async {
      final alice = _Endpoint('alice', 'dev-1');
      await alice.start(preKeys: 3);

      final identity = await alice.keys.loadIdentity();
      final serialized = jsonEncode(alice.published.toJson());

      expect(serialized.contains(base64Encode(identity!.dhKeyPair.privateKey)),
          isFalse,
          reason: 'the DH private key must never be uploaded');
      expect(serialized.contains(base64Encode(identity.signingKeyPair.seed)),
          isFalse,
          reason: 'the signing seed must never be uploaded');
    });

    test('one-time prekey ids do not collide within a pool', () async {
      final alice = _Endpoint('alice', 'dev-1');
      await alice.start(preKeys: 50);

      expect(alice.published.oneTimePreKeys.keys.toSet().length, 50);
    });
  });

  group('session establishment and messaging', () {
    test('alice sends, bob receives', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      final payload =
          await alice.engine.encrypt(bob.address, utf8.encode('hello bob'));

      // Bob completes his half of X3DH, then decrypts.
      await _acceptInbound(bob, alice, payload);

      final plaintext = await bob.engine.decrypt(alice.address, payload);
      expect(utf8.decode(plaintext), 'hello bob');
    });

    test('a full conversation round trips', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      final first =
          await alice.engine.encrypt(bob.address, utf8.encode('opening'));
      await _acceptInbound(bob, alice, first);
      expect(utf8.decode(await bob.engine.decrypt(alice.address, first)),
          'opening');

      for (var i = 0; i < 5; i++) {
        final fromBob =
            await bob.engine.encrypt(alice.address, utf8.encode('b$i'));
        expect(utf8.decode(await alice.engine.decrypt(bob.address, fromBob)),
            'b$i');

        final fromAlice =
            await alice.engine.encrypt(bob.address, utf8.encode('a$i'));
        expect(utf8.decode(await bob.engine.decrypt(alice.address, fromAlice)),
            'a$i');
      }
    });

    test('encrypting without a session fails', () async {
      final alice = _Endpoint('alice', 'a1');
      await alice.start();

      expect(
        () => alice.engine.encrypt(
          const PeerAddress(userId: 'nobody', deviceId: 'x'),
          utf8.encode('hi'),
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('hasSession reflects state', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      expect(await alice.engine.hasSession(bob.address), isFalse);
      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      expect(await alice.engine.hasSession(bob.address), isTrue);
    });
  });

  group('trust on first use', () {
    test('pins the peer identity on first contact', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      final pinned = await alice.sessions.loadPinnedIdentity(bob.address.key);
      expect(pinned, isNotNull);
      expect(pinned!.identityKey,
          equals(deserializePublicKey(bob.published.identityKey)));
    });

    test('strict policy blocks a changed identity key', () async {
      // The attack this exists to stop: the server substitutes a key it
      // controls. Without pinning, Alice would build a session with the
      // attacker and never know.
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start(trustPolicy: TrustPolicy.strict);
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      // Simulate a different key arriving for the same peer.
      alice.sessions.forcePinnedKey(
        bob.address.key,
        Uint8List.fromList(List.filled(32, 0x11)),
      );

      expect(
        () => alice.engine
            .establishOutboundSession(bob.address, bob.bundleForPeer()),
        throwsA(isA<IdentityChangedException>()),
        reason: 'strict mode must block sending until the user accepts',
      );
    });

    test('default policy re-establishes and reports a changed key', () async {
      // Replacing a phone produces exactly this: a new identity key under a
      // known peer. Blocking here would leave the contact unreachable, so the
      // session is rebuilt and the change is announced instead.
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      final notices = <IdentityChangeNotice>[];
      alice.engine.identityChanges.listen(notices.add);

      final stale = Uint8List.fromList(List.filled(32, 0x11));
      alice.sessions.forcePinnedKey(bob.address.key, stale);

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      // Let the broadcast stream deliver.
      await Future<void>.delayed(Duration.zero);

      expect(await alice.engine.hasSession(bob.address), isTrue,
          reason: 'the conversation must remain usable');
      expect(notices, hasLength(1), reason: 'the user has to be told');
      expect(notices.single.peer, equals(bob.address));
      expect(notices.single.previousKey, equals(stale));

      final pinned = await alice.sessions.loadPinnedIdentity(bob.address.key);
      expect(pinned!.identityKey,
          equals(deserializePublicKey(bob.published.identityKey)),
          reason: 'the new key must be pinned, not the stale one');
      expect(pinned.acceptedChange, isFalse,
          reason: 'a rebuild must not grant standing trust for future changes');
    });

    test('a peer who reinstalls can still be messaged end to end', () async {
      // The full "new phone" path: Bob's device is replaced by one with fresh
      // keys, and Alice must be able to reach it without manual intervention.
      final alice = _Endpoint('alice', 'a1');
      final bobOld = _Endpoint('bob', 'b1');
      await alice.start();
      await bobOld.start();

      await alice.engine
          .establishOutboundSession(bobOld.address, bobOld.bundleForPeer());
      await alice.engine.encrypt(bobOld.address, utf8.encode('before'));

      // Same user, same device id, brand new key material.
      final bobNew = _Endpoint('bob', 'b1');
      await bobNew.start();

      await alice.engine
          .establishOutboundSession(bobNew.address, bobNew.bundleForPeer());

      final payload =
          await alice.engine.encrypt(bobNew.address, utf8.encode('after'));
      final plaintext = await bobNew.engine.decrypt(alice.address, payload);

      expect(utf8.decode(plaintext), equals('after'));
    });

    test('accepting a change allows a new session', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      alice.sessions.forcePinnedKey(
        bob.address.key,
        Uint8List.fromList(List.filled(32, 0x11)),
      );

      await alice.engine.acceptIdentityChange(bob.address);

      // After acceptance the handshake proceeds and the old session is gone.
      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      expect(await alice.engine.hasSession(bob.address), isTrue);
    });

    test('rejects a bundle with an invalid signature', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      final genuine = bob.bundleForPeer();
      final forged = PreKeyBundle(
        deviceId: genuine.deviceId,
        registrationId: genuine.registrationId,
        identityKey: genuine.identityKey,
        identityKeyEd25519: genuine.identityKeyEd25519,
        signedPreKeyId: genuine.signedPreKeyId,
        signedPreKey: genuine.signedPreKey,
        signedPreKeySignature: Uint8List(64), // not a valid signature
      );

      expect(
        () => alice.engine.establishOutboundSession(bob.address, forged),
        throwsA(isA<X3dhVerificationException>()),
      );
    });
  });

  group('safety numbers', () {
    test('both sides compute the same number', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      await bob.engine
          .establishOutboundSession(alice.address, alice.bundleForPeer());

      final fromAlice =
          await alice.engine.safetyNumberFor(bob.address, 'alice');
      final fromBob = await bob.engine.safetyNumberFor(alice.address, 'bob');

      expect(fromAlice, equals(fromBob),
          reason: 'users compare these digits out of band; they must match');
      expect(fromAlice.length, 60);
      // Checked with a pattern rather than int.tryParse: 60 digits overflow
      // Dart's int, so parsing would return null for a perfectly valid number.
      expect(RegExp(r'^[0-9]{60}$').hasMatch(fromAlice), isTrue,
          reason: 'safety numbers are decimal digits users read aloud');
    });

    test('a different peer key gives a different number', () async {
      final alice = _Endpoint('alice', 'a1');
      final bobKey = Uint8List.fromList(List.filled(32, 1));
      final eveKey = Uint8List.fromList(List.filled(32, 2));
      await alice.start();

      final withBob = await safetyNumber(
        localUserId: 'alice',
        localIdentityKey: Uint8List.fromList(List.filled(32, 9)),
        remoteUserId: 'bob',
        remoteIdentityKey: bobKey,
      );
      final withEve = await safetyNumber(
        localUserId: 'alice',
        localIdentityKey: Uint8List.fromList(List.filled(32, 9)),
        remoteUserId: 'bob',
        remoteIdentityKey: eveKey,
      );

      expect(withBob, isNot(equals(withEve)),
          reason: 'a substituted key must change the displayed number');
    });

    test('formats into readable groups', () {
      final formatted = formatSafetyNumber('0' * 60);
      expect(formatted.replaceAll(RegExp(r'[\s\n]'), '').length, 60);
      expect(formatted, contains(' '));
    });
  });

  group('persistence', () {
    test('sessions survive an engine restart', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      final first =
          await alice.engine.encrypt(bob.address, utf8.encode('before'));
      await _acceptInbound(bob, alice, first);
      expect(utf8.decode(await bob.engine.decrypt(alice.address, first)),
          'before');

      // Restart both endpoints against the same stores.
      alice.engine = FrogsterCryptoEngine(
        keyStorage: alice.keys,
        sessionStore: alice.sessions,
      );
      bob.engine = FrogsterCryptoEngine(
        keyStorage: bob.keys,
        sessionStore: bob.sessions,
      );

      final after =
          await alice.engine.encrypt(bob.address, utf8.encode('after'));
      expect(utf8.decode(await bob.engine.decrypt(alice.address, after)),
          'after',
          reason: 'ratchet state must survive an app restart');
    });

    test('a restart before the peer replies still sends a prekey message',
        () async {
      // The initiator has to keep attaching handshake material until the peer
      // answers, because until then it cannot know the first message arrived.
      // Holding that material only in memory means a restart downgrades every
      // later message to an ordinary ratchet message -- which the peer cannot
      // decrypt and cannot build a session from.
      //
      // The failure is one-directional and therefore easy to misread: the peer
      // still reaches us, because their own messages carry their handshake, so
      // the conversation looks alive right up until you check which way it
      // actually flows.
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());

      // Alice restarts before Bob has said anything back.
      alice.engine = FrogsterCryptoEngine(
        keyStorage: alice.keys,
        sessionStore: alice.sessions,
      );

      final payload =
          await alice.engine.encrypt(bob.address, utf8.encode('hello'));

      expect(payload.isPreKeyMessage, isTrue,
          reason: 'Bob has no session yet, so the message must carry one');
      expect(payload.initiatorIdentityKey, isNotNull);
      expect(payload.initiatorEphemeralKey, isNotNull);

      // Bob, who has never heard of Alice, must be able to read it.
      await _acceptInbound(bob, alice, payload);
      expect(
        utf8.decode(await bob.engine.decrypt(alice.address, payload)),
        'hello',
      );
    });

    test('handshake material stops riding along once the peer replies',
        () async {
      // The flip side: persisting the handshake must not make it permanent.
      // A prekey message rebuilds the session on arrival, so re-sending the
      // material after the conversation is established would reset the peer's
      // ratchet mid-dialogue.
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      await alice.engine
          .establishOutboundSession(bob.address, bob.bundleForPeer());
      final opening =
          await alice.engine.encrypt(bob.address, utf8.encode('hi'));
      await _acceptInbound(bob, alice, opening);
      await bob.engine.decrypt(alice.address, opening);

      // Bob answers, which proves he completed the handshake.
      final reply = await bob.engine.encrypt(alice.address, utf8.encode('yo'));
      await alice.engine.decrypt(bob.address, reply);

      // Restarting must not resurrect the settled handshake from storage.
      alice.engine = FrogsterCryptoEngine(
        keyStorage: alice.keys,
        sessionStore: alice.sessions,
      );

      final later =
          await alice.engine.encrypt(bob.address, utf8.encode('still here'));
      expect(later.isPreKeyMessage, isFalse,
          reason: 'a settled session must not keep re-sending its handshake');
      expect(
        utf8.decode(await bob.engine.decrypt(alice.address, later)),
        'still here',
      );
    });
  });
}

/// No-op: decrypt() completes the responder's half of X3DH automatically from
/// the material carried in a prekey message. Kept as a named step so the tests
/// read like the real flow.
Future<void> _acceptInbound(
  _Endpoint receiver,
  _Endpoint sender,
  EncryptedPayload payload,
) async {}
