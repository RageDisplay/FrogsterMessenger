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
  PreKeyBundle bundleForPeer({bool withOneTimePreKey = true}) {
    final otpEntry = published.oneTimePreKeys.entries.first;
    return PreKeyBundle(
      deviceId: deviceId,
      registrationId: published.registrationId,
      identityKey: deserializePublicKey(published.identityKey),
      identityKeyEd25519: published.identityKeyEd25519,
      signedPreKeyId: published.signedPreKeyId,
      signedPreKey: deserializePublicKey(published.signedPreKey),
      signedPreKeySignature: published.signedPreKeySignature,
      oneTimePreKeyId: withOneTimePreKey ? otpEntry.key : null,
      oneTimePreKey:
          withOneTimePreKey ? deserializePublicKey(otpEntry.value) : null,
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

  group('concurrency', () {
    // The ratchet awaits between reading a chain key and storing its
    // successor. Overlapping calls on one session -- a burst from an offline
    // flush, or a send racing a receive -- must still behave as if serial.

    test('a burst of concurrent decrypts all succeed', () async {
      final p = await _conversation();

      final burst = <EncryptedPayload>[];
      for (var i = 0; i < 8; i++) {
        burst.add(await p.alice.engine.encrypt(p.bob.address, utf8.encode('m$i')));
      }

      final out = await Future.wait(
        burst.map((m) => p.bob.engine.decrypt(p.alice.address, m)),
      );
      expect(out.map(utf8.decode), [for (var i = 0; i < 8; i++) 'm$i']);
    });

    test('concurrent encrypts produce decryptable messages', () async {
      final p = await _conversation();

      final sent = await Future.wait([
        for (var i = 0; i < 8; i++)
          p.alice.engine.encrypt(p.bob.address, utf8.encode('c$i')),
      ]);
      for (var i = 0; i < 8; i++) {
        expect(
          utf8.decode(await p.bob.engine.decrypt(p.alice.address, sent[i])),
          'c$i',
        );
      }
    });
  });

  group('prekey messages are authenticated before they change state', () {
    // A prekey message carries an identity key and handshake material that
    // nobody has vouched for until its ratchet message decrypts. Anyone who
    // can inject a frame -- the server included -- can claim to be any peer.

    test('a forged handshake does not replace a working session', () async {
      final p = await _conversation();
      final mallory = _Endpoint('mallory', 'm1');
      await mallory.start();

      final notices = <IdentityChangeNotice>[];
      final sub = p.bob.engine.identityChanges.listen(notices.add);

      // Mallory builds a real prekey message to Bob and the server delivers
      // it as if it came from Alice's device.
      // No one-time prekey: Alice already consumed the one bundleForPeer
      // hands out, and an unknown prekey id would be rejected before the
      // handshake gets anywhere near the state this test is about.
      await mallory.engine.establishOutboundSession(
        p.bob.address,
        p.bob.bundleForPeer(withOneTimePreKey: false),
      );
      final forged =
          await mallory.engine.encrypt(p.bob.address, utf8.encode('evil'));

      // A prekey message that decrypts under a new identity is
      // indistinguishable from Alice reinstalling, and the default policy
      // accepts it with a notice. The forgery that must change nothing is one
      // that does not decrypt.
      final broken = EncryptedPayload(
        cipherType: forged.cipherType,
        body: _corrupt(forged.body),
        initiatorIdentityKey: forged.initiatorIdentityKey,
        initiatorEphemeralKey: forged.initiatorEphemeralKey,
        oneTimePreKeyId: forged.oneTimePreKeyId,
        signedPreKeyId: forged.signedPreKeyId,
      );
      final pinnedBefore =
          await p.bob.sessions.loadPinnedIdentity(p.alice.address.key);

      await expectLater(
        p.bob.engine.decrypt(p.alice.address, broken),
        throwsA(anything),
      );

      final pinnedAfter =
          await p.bob.sessions.loadPinnedIdentity(p.alice.address.key);
      expect(pinnedAfter!.identityKey, equals(pinnedBefore!.identityKey),
          reason: 'an unauthenticated handshake must not re-pin the peer');
      await Future<void>.delayed(Duration.zero);
      expect(notices, isEmpty,
          reason: 'no identity change may be announced for a forgery');

      // Alice's session with Bob is unharmed in both directions.
      final a = await p.alice.engine.encrypt(p.bob.address, utf8.encode('ok'));
      expect(utf8.decode(await p.bob.engine.decrypt(p.alice.address, a)), 'ok');
      final b = await p.bob.engine.encrypt(p.alice.address, utf8.encode('ok2'));
      expect(
          utf8.decode(await p.alice.engine.decrypt(p.bob.address, b)), 'ok2');
      await sub.cancel();
    });

    test('a failed handshake does not burn the one-time prekey', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      final bundle = bob.bundleForPeer();
      await alice.engine.establishOutboundSession(bob.address, bundle);
      final genuine =
          await alice.engine.encrypt(bob.address, utf8.encode('first'));
      final broken = EncryptedPayload(
        cipherType: genuine.cipherType,
        body: _corrupt(genuine.body),
        initiatorIdentityKey: genuine.initiatorIdentityKey,
        initiatorEphemeralKey: genuine.initiatorEphemeralKey,
        oneTimePreKeyId: genuine.oneTimePreKeyId,
        signedPreKeyId: genuine.signedPreKeyId,
      );

      await expectLater(
        bob.engine.decrypt(alice.address, broken),
        throwsA(anything),
      );
      expect(await bob.keys.loadOneTimePreKey(bundle.oneTimePreKeyId!),
          isNotNull,
          reason: 'the prekey is destroyed only by a handshake that worked');
      expect(await bob.engine.hasSession(alice.address), isFalse);

      // The genuine copy still establishes the session afterwards.
      expect(utf8.decode(await bob.engine.decrypt(alice.address, genuine)),
          'first');
      expect(await bob.keys.loadOneTimePreKey(bundle.oneTimePreKeyId!), isNull);
    });
  });

  group('signed prekey rotation', () {
    test('nothing rotates while the key is fresh', () async {
      final bob = _Endpoint('bob', 'b1');
      await bob.start();
      expect(await bob.engine.prepareSignedPreKeyRotation(), isNull);
    });

    test('a message built on the previous key still decrypts', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      // Alice fetched Bob's bundle, then Bob rotated before her message
      // arrived -- the normal case for a recipient who was offline.
      final staleBundle = bob.bundleForPeer();
      final upload =
          await bob.engine.prepareSignedPreKeyRotation(maxAge: Duration.zero);
      expect(upload, isNotNull);
      expect(upload!.keyId, isNot(staleBundle.signedPreKeyId));
      await bob.engine.commitSignedPreKeyRotation(upload);

      await alice.engine.establishOutboundSession(bob.address, staleBundle);
      final msg = await alice.engine.encrypt(bob.address, utf8.encode('late'));
      expect(msg.signedPreKeyId, staleBundle.signedPreKeyId);
      expect(utf8.decode(await bob.engine.decrypt(alice.address, msg)), 'late');
    });

    test('a message built on the new key decrypts', () async {
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      final upload =
          await bob.engine.prepareSignedPreKeyRotation(maxAge: Duration.zero);
      await bob.engine.commitSignedPreKeyRotation(upload!);

      final fresh = PreKeyBundle(
        deviceId: bob.deviceId,
        registrationId: bob.published.registrationId,
        identityKey: deserializePublicKey(bob.published.identityKey),
        identityKeyEd25519: bob.published.identityKeyEd25519,
        signedPreKeyId: upload.keyId,
        signedPreKey: deserializePublicKey(upload.publicKey),
        signedPreKeySignature: upload.signature,
      );
      await alice.engine.establishOutboundSession(bob.address, fresh);
      final msg = await alice.engine.encrypt(bob.address, utf8.encode('new'));
      expect(utf8.decode(await bob.engine.decrypt(alice.address, msg)), 'new');
    });

    test('a key two rotations old is gone', () async {
      // Keeping every old signed prekey would quietly undo the forward
      // secrecy rotation exists to provide.
      final alice = _Endpoint('alice', 'a1');
      final bob = _Endpoint('bob', 'b1');
      await alice.start();
      await bob.start();

      final ancient = bob.bundleForPeer();
      for (var i = 0; i < 2; i++) {
        final upload =
            await bob.engine.prepareSignedPreKeyRotation(maxAge: Duration.zero);
        await bob.engine.commitSignedPreKeyRotation(upload!);
      }

      await alice.engine.establishOutboundSession(bob.address, ancient);
      final msg = await alice.engine.encrypt(bob.address, utf8.encode('x'));
      await expectLater(
        bob.engine.decrypt(alice.address, msg),
        throwsA(anything),
      );
    });
  });

  group('one-time prekey ids', () {
    test('successive pools never reuse an id', () async {
      // A reused id makes the device overwrite a private key the server may
      // still hand out, breaking every session built from the old public key.
      final bob = _Endpoint('bob', 'b1');
      await bob.start(preKeys: 100);

      final seen = bob.published.oneTimePreKeys.keys.toSet();
      var lastMax = seen.reduce((a, b) => a > b ? a : b);
      for (var i = 0; i < 20; i++) {
        final batch = await bob.engine.generateOneTimePreKeys(100);
        expect(seen.intersection(batch.keys.toSet()), isEmpty);
        // Ids continue from a persisted counter. A random base per pool would
        // pass the overlap check above most of the time and collide rarely,
        // which is the failure mode this guards against.
        final ids = batch.keys.toList()..sort();
        expect(ids.first, lastMax + 1);
        lastMax = ids.last;
        seen.addAll(batch.keys);
      }
    });
  });
}

class _Conversation {
  _Conversation(this.alice, this.bob);
  final _Endpoint alice;
  final _Endpoint bob;
}

/// Alice and Bob with a settled session: both have sent and received.
Future<_Conversation> _conversation() async {
  final alice = _Endpoint('alice', 'a1');
  final bob = _Endpoint('bob', 'b1');
  await alice.start();
  await bob.start();

  await alice.engine.establishOutboundSession(bob.address, bob.bundleForPeer());
  final first = await alice.engine.encrypt(bob.address, utf8.encode('hi'));
  await bob.engine.decrypt(alice.address, first);
  final reply = await bob.engine.encrypt(alice.address, utf8.encode('hey'));
  await alice.engine.decrypt(bob.address, reply);
  return _Conversation(alice, bob);
}

/// Flips a bit inside the AEAD ciphertext of a serialized ratchet message.
Uint8List _corrupt(Uint8List body) {
  final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
  final ct = base64Decode(json['c'] as String);
  ct[ct.length - 1] ^= 0x01;
  json['c'] = base64Encode(ct);
  return Uint8List.fromList(utf8.encode(jsonEncode(json)));
}

/// No-op: decrypt() completes the responder's half of X3DH automatically from
/// the material carried in a prekey message. Kept as a named step so the tests
/// read like the real flow.
Future<void> _acceptInbound(
  _Endpoint receiver,
  _Endpoint sender,
  EncryptedPayload payload,
) async {}
