import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/ratchet/double_ratchet.dart';
import 'package:frogster/crypto/signing.dart';
import 'package:frogster/crypto/x3dh.dart';

/// A pair of sessions that have completed X3DH, as Alice and Bob would after
/// the first handshake.
class _Pair {
  _Pair(this.alice, this.bob);
  final RatchetSession alice;
  final RatchetSession bob;
}

Future<_Pair> _establish() async {
  final aliceDh = await generateKeyPair();
  final aliceSign = await generateSigningKeyPair();
  final aliceIdentity =
      IdentityKeys(dhKeyPair: aliceDh, signingKeyPair: aliceSign);

  final bobDh = await generateKeyPair();
  final bobSign = await generateSigningKeyPair();
  final bobIdentity = IdentityKeys(dhKeyPair: bobDh, signingKeyPair: bobSign);

  final bobSpk = await generateKeyPair();
  final bobSpkSig = await sign(seed: bobSign.seed, message: bobSpk.publicKey);
  final bobOtp = await generateKeyPair();

  final bundle = PreKeyBundle(
    deviceId: 'bob-1',
    registrationId: 1,
    identityKey: bobDh.publicKey,
    identityKeyEd25519: bobSign.publicKey,
    signedPreKeyId: 1,
    signedPreKey: bobSpk.publicKey,
    signedPreKeySignature: bobSpkSig,
    oneTimePreKeyId: 1,
    oneTimePreKey: bobOtp.publicKey,
  );

  final aliceX3dh =
      await x3dhInitiate(identity: aliceIdentity, bundle: bundle);
  final bobX3dh = await x3dhRespond(
    identity: bobIdentity,
    signedPreKeyPair: bobSpk,
    initiatorIdentityKey: aliceDh.publicKey,
    initiatorEphemeralKey: aliceX3dh.ephemeralPublicKey,
    oneTimePreKeyPair: bobOtp,
  );

  final alice = await RatchetSession.initSender(
    sharedSecret: aliceX3dh.sharedSecret,
    receiverSignedPreKey: bobSpk.publicKey,
    associatedData: aliceX3dh.associatedData,
  );
  final bob = await RatchetSession.initReceiver(
    sharedSecret: bobX3dh.sharedSecret,
    signedPreKeyPair: bobSpk,
    associatedData: bobX3dh.associatedData,
  );

  return _Pair(alice, bob);
}

String _text(Uint8List bytes) => utf8.decode(bytes);
List<int> _bytes(String s) => utf8.encode(s);

void main() {
  group('basic exchange', () {
    test('single message round trip', () async {
      final p = await _establish();

      final msg = await p.alice.encrypt(_bytes('hello bob'));
      final out = await p.bob.decrypt(msg);

      expect(_text(out), 'hello bob');
    });

    test('many messages in one direction', () async {
      final p = await _establish();

      for (var i = 0; i < 20; i++) {
        final msg = await p.alice.encrypt(_bytes('message $i'));
        expect(_text(await p.bob.decrypt(msg)), 'message $i');
      }
    });

    test('conversation alternating directions', () async {
      final p = await _establish();

      for (var i = 0; i < 10; i++) {
        final fromAlice = await p.alice.encrypt(_bytes('a$i'));
        expect(_text(await p.bob.decrypt(fromAlice)), 'a$i');

        final fromBob = await p.bob.encrypt(_bytes('b$i'));
        expect(_text(await p.alice.decrypt(fromBob)), 'b$i');
      }
    });

    test('bob cannot send before receiving', () async {
      final p = await _establish();

      // Bob has no sending chain until the first DH ratchet step.
      expect(
        () => p.bob.encrypt(_bytes('too early')),
        throwsA(isA<RatchetException>()),
      );
    });
  });

  group('out-of-order delivery', () {
    test('delivers 1,2,3 in the order 3,1,2', () async {
      // The canonical reordering case: the network is not a queue.
      final p = await _establish();

      final m1 = await p.alice.encrypt(_bytes('one'));
      final m2 = await p.alice.encrypt(_bytes('two'));
      final m3 = await p.alice.encrypt(_bytes('three'));

      expect(_text(await p.bob.decrypt(m3)), 'three');
      expect(_text(await p.bob.decrypt(m1)), 'one');
      expect(_text(await p.bob.decrypt(m2)), 'two');
    });

    test('handles reordering across a direction change', () async {
      final p = await _establish();

      final a1 = await p.alice.encrypt(_bytes('a1'));
      final a2 = await p.alice.encrypt(_bytes('a2'));
      expect(_text(await p.bob.decrypt(a1)), 'a1');

      // Bob replies, starting a new chain, while a2 is still in flight.
      final b1 = await p.bob.encrypt(_bytes('b1'));
      expect(_text(await p.alice.decrypt(b1)), 'b1');

      final a3 = await p.alice.encrypt(_bytes('a3'));
      expect(_text(await p.bob.decrypt(a3)), 'a3');

      // The straggler from the previous chain must still decrypt.
      expect(_text(await p.bob.decrypt(a2)), 'a2');
    });

    test('a lost message does not block later ones', () async {
      final p = await _establish();

      await p.alice.encrypt(_bytes('lost')); // never delivered
      final m2 = await p.alice.encrypt(_bytes('arrives'));

      expect(_text(await p.bob.decrypt(m2)), 'arrives');
    });

    test('replaying an in-order message fails', () async {
      // The chain has already advanced past this key, so there is nothing to
      // decrypt with.
      final p = await _establish();

      final msg = await p.alice.encrypt(_bytes('once'));
      expect(_text(await p.bob.decrypt(msg)), 'once');

      expect(() => p.bob.decrypt(msg), throwsA(isA<RatchetException>()));
    });

    test('replaying an out-of-order message fails', () async {
      // The dangerous replay case. A message delivered out of order is
      // decrypted with a *stashed* key, and that key must be removed from the
      // store as it is consumed. If it were merely looked up, an attacker
      // could re-inject the same message indefinitely and it would decrypt
      // every time -- while ordinary in-order replay still failed, so a test
      // that only checks in-order replay would not notice.
      final p = await _establish();

      final m1 = await p.alice.encrypt(_bytes('first'));
      final m2 = await p.alice.encrypt(_bytes('second'));

      // Deliver m2 first: this stashes the key for m1.
      expect(_text(await p.bob.decrypt(m2)), 'second');
      expect(p.bob.skippedKeyCount, 1);

      // m1 arrives late and consumes the stashed key.
      expect(_text(await p.bob.decrypt(m1)), 'first');
      expect(p.bob.skippedKeyCount, 0,
          reason: 'a consumed skipped key must be removed, not just read');

      // The replay must now fail.
      expect(
        () => p.bob.decrypt(m1),
        throwsA(isA<RatchetException>()),
        reason: 'a stashed key must be single-use',
      );
    });
  });

  group('chain KDF one-way property', () {
    // These assert the KDF's structure directly rather than through a working
    // exchange. A chain KDF that derives the message key and the next chain
    // key from the same input still encrypts and decrypts perfectly -- but any
    // leaked message key would expose the whole rest of the chain. No
    // functional test can see that, so it is checked here explicitly.

    test('message key and next chain key differ', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 42));
      final step = await kdfChainKeyForTesting(chainKey);

      expect(step.messageKey, isNot(equals(step.nextChainKey)),
          reason: 'identical outputs let one message key unlock the chain');
    });

    test('neither output equals the input chain key', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 42));
      final step = await kdfChainKeyForTesting(chainKey);

      expect(step.messageKey, isNot(equals(chainKey)));
      expect(step.nextChainKey, isNot(equals(chainKey)));
    });

    test('a message key does not reveal the next message key', () async {
      // Walk two steps and confirm the attacker's view (a single message key)
      // is not enough to reproduce the following one.
      final chainKey = Uint8List.fromList(List.filled(32, 7));
      final first = await kdfChainKeyForTesting(chainKey);
      final second = await kdfChainKeyForTesting(first.nextChainKey);

      // If message and chain derivation collided, this would hold.
      final forged = await kdfChainKeyForTesting(first.messageKey);

      expect(forged.messageKey, isNot(equals(second.messageKey)),
          reason: 'a message key must not act as the next chain key');
    });

    test('is deterministic', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 1));
      final a = await kdfChainKeyForTesting(chainKey);
      final b = await kdfChainKeyForTesting(chainKey);

      expect(a.messageKey, equals(b.messageKey));
      expect(a.nextChainKey, equals(b.nextChainKey));
    });

    test('different chain keys give different outputs', () async {
      final a = await kdfChainKeyForTesting(
          Uint8List.fromList(List.filled(32, 1)));
      final b = await kdfChainKeyForTesting(
          Uint8List.fromList(List.filled(32, 2)));

      expect(a.messageKey, isNot(equals(b.messageKey)));
      expect(a.nextChainKey, isNot(equals(b.nextChainKey)));
    });
  });

  group('forward secrecy', () {
    test('every message uses a distinct key', () async {
      // Identical plaintexts must produce different ciphertexts; equality
      // would mean the key was reused.
      final p = await _establish();
      final seen = <String>{};

      for (var i = 0; i < 30; i++) {
        final msg = await p.alice.encrypt(_bytes('same text'));
        seen.add(base64Encode(msg.ciphertext.body));
      }

      expect(seen.length, 30,
          reason: 'a repeated ciphertext means a message key was reused');
    });

    test('captured state cannot decrypt earlier messages', () async {
      // The essential forward-secrecy property: compromise now must not
      // expose the past.
      final p = await _establish();

      final early = await p.alice.encrypt(_bytes('early secret'));
      expect(_text(await p.bob.decrypt(early)), 'early secret');

      for (var i = 0; i < 5; i++) {
        final m = await p.alice.encrypt(_bytes('filler $i'));
        await p.bob.decrypt(m);
      }

      // Snapshot Bob's state as an attacker would, then replay the old message.
      final stolen = await RatchetSession.fromJson(p.bob.toJson());

      expect(
        () => stolen.decrypt(early),
        throwsA(isA<RatchetException>()),
        reason: 'state captured later must not decrypt earlier traffic',
      );
    });

    test('ratchet key changes when direction changes', () async {
      final p = await _establish();

      final a1 = await p.alice.encrypt(_bytes('a1'));
      await p.bob.decrypt(a1);

      final b1 = await p.bob.encrypt(_bytes('b1'));
      await p.alice.decrypt(b1);

      final a2 = await p.alice.encrypt(_bytes('a2'));

      expect(a2.header.ratchetPublicKey, isNot(equals(a1.header.ratchetPublicKey)),
          reason: 'a DH ratchet step must install a fresh key pair');
    });
  });

  group('authentication', () {
    test('rejects a tampered ciphertext body', () async {
      final p = await _establish();
      final msg = await p.alice.encrypt(_bytes('authentic'));

      final tampered = RatchetMessage(
        header: msg.header,
        ciphertext: AeadCiphertext(
          nonce: msg.ciphertext.nonce,
          body: Uint8List.fromList(msg.ciphertext.body)..[0] ^= 0xFF,
          tag: msg.ciphertext.tag,
        ),
      );

      expect(() => p.bob.decrypt(tampered), throwsA(isA<RatchetException>()));
    });

    test('rejects a swapped header', () async {
      // The header is AEAD associated data, so moving a body under a different
      // header must fail rather than silently decrypt.
      final p = await _establish();

      final m1 = await p.alice.encrypt(_bytes('first'));
      final m2 = await p.alice.encrypt(_bytes('second'));

      final swapped =
          RatchetMessage(header: m2.header, ciphertext: m1.ciphertext);

      expect(() => p.bob.decrypt(swapped), throwsA(isA<RatchetException>()));
    });

    test('header contents are covered by the authentication tag', () async {
      // Swapping whole headers is caught even without AAD, because the message
      // number selects a different key. This checks the narrower property that
      // AAD actually exists: mutate a header field that does NOT change key
      // selection (previousChainLength) and keep everything else identical.
      // If the header were not authenticated, this would decrypt happily.
      final p = await _establish();

      final msg = await p.alice.encrypt(_bytes('bind the header'));
      final tweaked = RatchetMessage(
        header: MessageHeader(
          ratchetPublicKey: msg.header.ratchetPublicKey,
          // Only this differs; it does not affect which message key is used.
          previousChainLength: msg.header.previousChainLength + 99,
          messageNumber: msg.header.messageNumber,
        ),
        ciphertext: msg.ciphertext,
      );

      expect(
        () => p.bob.decrypt(tweaked),
        throwsA(isA<RatchetException>()),
        reason: 'the header must be bound to the ciphertext via AEAD '
            'associated data',
      );
    });

    test('a third party cannot decrypt', () async {
      final p = await _establish();
      final other = await _establish();

      final msg = await p.alice.encrypt(_bytes('private'));

      expect(() => other.bob.decrypt(msg), throwsA(isA<RatchetException>()));
    });

    test('X3DH identity binding is authenticated', () async {
      // The session's associated data is IK_A || IK_B. It stops a transcript
      // from being replayed against a different pair of identities.
      //
      // Both peers must be checked against a session that shares the ratchet
      // state but not the identity binding -- if the binding were simply
      // dropped from the AAD on both sides they would still agree, and a test
      // comparing two honest peers would notice nothing.
      final p = await _establish();

      // Same ratchet state, different claimed identities.
      final json = p.bob.toJson();
      json['ad'] = base64Encode(Uint8List.fromList(List.filled(64, 0xAB)));
      final impostor = await RatchetSession.fromJson(json);

      final msg = await p.alice.encrypt(_bytes('bound to identities'));

      expect(
        () => impostor.decrypt(msg),
        throwsA(isA<RatchetException>()),
        reason: 'the X3DH identity binding must be authenticated with every '
            'message, not just used during the handshake',
      );

      // The genuine peer still decrypts the same message.
      expect(_text(await p.bob.decrypt(msg)), 'bound to identities');
    });
  });

  group('denial of service bounds', () {
    test('refuses to skip more than maxSkip keys', () async {
      // Without this cap a peer could claim message number 2^31 and force
      // unbounded key derivation.
      //
      // Asserting only "throws" is not enough: with the bound removed the
      // call still throws, just from AEAD authentication after deriving a
      // million keys. The distinguishing signal is the error message and the
      // fact that it fails *fast* without populating the skipped-key store.
      final p = await _establish();

      final real = await p.alice.encrypt(_bytes('hi'));
      final forged = RatchetMessage(
        header: MessageHeader(
          ratchetPublicKey: real.header.ratchetPublicKey,
          previousChainLength: 0,
          messageNumber: maxSkip + 500,
        ),
        ciphertext: real.ciphertext,
      );

      Object? caught;
      try {
        await p.bob.decrypt(forged);
        fail('an absurd message number must be refused');
      } catch (e) {
        caught = e;
      }

      expect(caught, isA<RatchetException>());
      expect(
        caught.toString(),
        contains('refusing to skip'),
        reason: 'must be rejected by the maxSkip bound, not by AEAD failure '
            'after deriving hundreds of keys',
      );
      expect(
        p.bob.skippedKeyCount,
        lessThanOrEqualTo(maxSkip),
        reason: 'a rejected message must not populate the skipped-key store',
      );
    });

    test('skipped keys stay bounded', () async {
      final p = await _establish();

      // Drop 100 messages, then deliver the next one.
      for (var i = 0; i < 100; i++) {
        await p.alice.encrypt(_bytes('dropped $i'));
      }
      final delivered = await p.alice.encrypt(_bytes('delivered'));
      expect(_text(await p.bob.decrypt(delivered)), 'delivered');

      expect(p.bob.skippedKeyCount, 100);
      expect(p.bob.skippedKeyCount, lessThanOrEqualTo(maxSkippedKeysStored));
    });
  });

  group('persistence', () {
    test('a session survives serialization', () async {
      final p = await _establish();

      final m1 = await p.alice.encrypt(_bytes('before restart'));
      expect(_text(await p.bob.decrypt(m1)), 'before restart');

      // Simulate an app restart on both sides.
      final aliceRestored = await RatchetSession.fromJson(p.alice.toJson());
      final bobRestored = await RatchetSession.fromJson(p.bob.toJson());

      final m2 = await aliceRestored.encrypt(_bytes('after restart'));
      expect(_text(await bobRestored.decrypt(m2)), 'after restart');

      final reply = await bobRestored.encrypt(_bytes('reply'));
      expect(_text(await aliceRestored.decrypt(reply)), 'reply');
    });

    test('restored session keeps skipped keys usable', () async {
      final p = await _establish();

      final m1 = await p.alice.encrypt(_bytes('one'));
      final m2 = await p.alice.encrypt(_bytes('two'));

      // Deliver out of order, then restart before the straggler arrives.
      expect(_text(await p.bob.decrypt(m2)), 'two');
      final restored = await RatchetSession.fromJson(p.bob.toJson());

      expect(_text(await restored.decrypt(m1)), 'one',
          reason: 'stashed keys must survive a restart');
    });

    test('message round trips through wire serialization', () async {
      final p = await _establish();

      final msg = await p.alice.encrypt(_bytes('over the wire'));
      final parsed = RatchetMessage.deserialize(msg.serialize());

      expect(_text(await p.bob.decrypt(parsed)), 'over the wire');
    });
  });

  group('stress', () {
    test('200 messages with heavy reordering', () async {
      final p = await _establish();

      final pending = <RatchetMessage>[];
      for (var i = 0; i < 200; i++) {
        pending.add(await p.alice.encrypt(_bytes('msg $i')));
      }

      // Deliver in reverse, the worst case for skipped-key handling.
      for (var i = pending.length - 1; i >= 0; i--) {
        expect(_text(await p.bob.decrypt(pending[i])), 'msg $i');
      }
    });

    test('long alternating conversation', () async {
      final p = await _establish();

      for (var i = 0; i < 50; i++) {
        final a = await p.alice.encrypt(_bytes('a$i'));
        expect(_text(await p.bob.decrypt(a)), 'a$i');
        final b = await p.bob.encrypt(_bytes('b$i'));
        expect(_text(await p.alice.decrypt(b)), 'b$i');
      }
    });
  });
}
