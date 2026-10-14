import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/primitives.dart';
import 'package:frogster/crypto/ratchet/sender_key.dart';
import 'package:frogster/crypto/signing.dart';

String _text(Uint8List b) => utf8.decode(b);
List<int> _bytes(String s) => utf8.encode(s);

/// Distributes a sender key to a member, as the pairwise session would.
SenderKeyState _distribute(SenderKeyState sender) => acceptDistributionMessage(
      SenderKeyDistributionMessage.deserialize(
        buildDistributionMessage(sender).serialize(),
      ),
    );

void main() {
  group('group messaging', () {
    test('a member decrypts a broadcast message', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bobsView = _distribute(alice);

      final msg =
          await encryptGroupMessage(state: alice, plaintext: _bytes('hi all'));
      final out = await decryptGroupMessage(
        state: bobsView,
        message: msg,
        currentEpoch: 0,
      );

      expect(_text(out), 'hi all');
    });

    test('several members decrypt the same ciphertext', () async {
      // The point of sender keys: one encryption serves the whole group.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);
      final carol = _distribute(alice);

      final msg = await encryptGroupMessage(
        state: alice,
        plaintext: _bytes('broadcast'),
      );

      expect(
        _text(await decryptGroupMessage(
            state: bob, message: msg, currentEpoch: 0)),
        'broadcast',
      );
      expect(
        _text(await decryptGroupMessage(
            state: carol, message: msg, currentEpoch: 0)),
        'broadcast',
      );
    });

    test('a sequence of messages round trips', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      for (var i = 0; i < 20; i++) {
        final msg =
            await encryptGroupMessage(state: alice, plaintext: _bytes('m$i'));
        expect(
          _text(await decryptGroupMessage(
              state: bob, message: msg, currentEpoch: 0)),
          'm$i',
        );
      }
    });

    test('catches up after missed messages', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      // Three messages are lost.
      for (var i = 0; i < 3; i++) {
        await encryptGroupMessage(state: alice, plaintext: _bytes('lost $i'));
      }
      final delivered = await encryptGroupMessage(
        state: alice,
        plaintext: _bytes('delivered'),
      );

      expect(
        _text(await decryptGroupMessage(
            state: bob, message: delivered, currentEpoch: 0)),
        'delivered',
      );
    });
  });

  group('epoch rotation on membership change', () {
    test('a removed member cannot read the new epoch', () async {
      // The central group-security property. Mallory was a member during
      // epoch 0 and kept that sender key. After removal the chat moves to
      // epoch 1 and every remaining member issues a fresh key; Mallory's old
      // key must be useless.
      final aliceEpoch0 = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final mallory = _distribute(aliceEpoch0);

      // Mallory could read epoch 0 traffic while a member.
      final old = await encryptGroupMessage(
        state: aliceEpoch0,
        plaintext: _bytes('while a member'),
      );
      expect(
        _text(await decryptGroupMessage(
            state: mallory, message: old, currentEpoch: 0)),
        'while a member',
      );

      // Mallory is removed; the chat advances and Alice rotates her key.
      final aliceEpoch1 = await createSenderKey(
        chatId: 'chat-1',
        epoch: 1,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(aliceEpoch1);

      final fresh = await encryptGroupMessage(
        state: aliceEpoch1,
        plaintext: _bytes('after removal'),
      );

      // A remaining member reads it.
      expect(
        _text(await decryptGroupMessage(
            state: bob, message: fresh, currentEpoch: 1)),
        'after removal',
      );

      // Mallory cannot.
      expect(
        () => decryptGroupMessage(
            state: mallory, message: fresh, currentEpoch: 1),
        throwsA(isA<SenderKeyException>()),
        reason: 'a removed member must lose access at the next epoch',
      );
    });

    test('a stale-epoch message is rejected', () async {
      // Stops a removed member replaying old-epoch traffic into the group.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final msg =
          await encryptGroupMessage(state: alice, plaintext: _bytes('old'));

      expect(
        () => decryptGroupMessage(state: bob, message: msg, currentEpoch: 1),
        throwsA(isA<SenderKeyException>()),
        reason: 'the chat has moved on; epoch 0 traffic is no longer valid',
      );
    });

    test('keys from different epochs are independent', () async {
      final epoch0 = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final epoch1 = await createSenderKey(
        chatId: 'chat-1',
        epoch: 1,
        senderDeviceId: 'alice-1',
      );

      expect(epoch0.chainKey, isNot(equals(epoch1.chainKey)),
          reason: 'rotation must produce unrelated key material');
      expect(epoch0.signingPublicKey, isNot(equals(epoch1.signingPublicKey)));
    });
  });

  group('authenticity within the group', () {
    test('rejects a forged signature', () async {
      // Every member holds the same symmetric key, so AEAD alone proves only
      // that the sender is *some* member. The per-sender signature is what
      // stops one member impersonating another.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final mallory = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'mallory-1',
      );
      final bob = _distribute(alice);

      final genuine = await encryptGroupMessage(
        state: alice,
        plaintext: _bytes('from alice'),
      );

      // Mallory keeps Alice's ciphertext but signs with her own key.
      final forged = SenderKeyMessage(
        chatId: genuine.chatId,
        epoch: genuine.epoch,
        senderDeviceId: genuine.senderDeviceId,
        iteration: genuine.iteration,
        ciphertext: genuine.ciphertext,
        signature: await encryptGroupMessage(
          state: mallory,
          plaintext: _bytes('x'),
        ).then((m) => m.signature),
      );

      expect(
        () => decryptGroupMessage(
            state: bob, message: forged, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
    });

    test('rejects a tampered ciphertext', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final msg =
          await encryptGroupMessage(state: alice, plaintext: _bytes('honest'));
      final tampered = SenderKeyMessage(
        chatId: msg.chatId,
        epoch: msg.epoch,
        senderDeviceId: msg.senderDeviceId,
        iteration: msg.iteration,
        ciphertext: AeadCiphertext(
          nonce: msg.ciphertext.nonce,
          body: Uint8List.fromList(msg.ciphertext.body)..[0] ^= 0xFF,
          tag: msg.ciphertext.tag,
        ),
        signature: msg.signature,
      );

      expect(
        () => decryptGroupMessage(
            state: bob, message: tampered, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
    });

    test('a peer key cannot send', () async {
      // A distributed key carries no signing seed, so a member cannot use
      // another member's key to speak as them.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bobsView = _distribute(alice);

      expect(
        () => encryptGroupMessage(state: bobsView, plaintext: _bytes('nope')),
        throwsA(isA<SenderKeyException>()),
      );
    });
  });

  group('sender chain KDF one-way property', () {
    // Structural checks. A chain that derives the message key and the next
    // chain key from the same input still delivers messages perfectly, but any
    // leaked message key would expose the rest of the group chain. No
    // functional test can see that.

    test('message key and next chain key differ', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 42));
      final step = await advanceSenderChainForTesting(chainKey);

      expect(step.messageKey, isNot(equals(step.nextChainKey)),
          reason: 'identical outputs let one message key unlock the chain');
    });

    test('a message key does not act as the next chain key', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 7));
      final first = await advanceSenderChainForTesting(chainKey);
      final second = await advanceSenderChainForTesting(first.nextChainKey);
      final forged = await advanceSenderChainForTesting(first.messageKey);

      expect(forged.messageKey, isNot(equals(second.messageKey)));
    });

    test('neither output equals the input', () async {
      final chainKey = Uint8List.fromList(List.filled(32, 3));
      final step = await advanceSenderChainForTesting(chainKey);

      expect(step.messageKey, isNot(equals(chainKey)));
      expect(step.nextChainKey, isNot(equals(chainKey)));
    });
  });

  group('distribution message contents', () {
    test('carries exactly the expected fields', () async {
      // Pins the wire shape so an accidental addition -- a signing seed, a
      // spare copy of key material -- is noticed rather than shipped.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final skdm = buildDistributionMessage(alice);
      final json = jsonDecode(utf8.decode(skdm.serialize()))
          as Map<String, dynamic>;

      expect(
        json.keys.toSet(),
        equals({
          'chat_id',
          'epoch',
          'device_id',
          'chain_key',
          'iteration',
          'sign_pub',
        }),
        reason: 'an unexpected field in the SKDM may be leaking key material',
      );
    });
  });

  group('chain properties', () {
    test('each message uses a distinct key', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final seen = <String>{};

      for (var i = 0; i < 25; i++) {
        final msg = await encryptGroupMessage(
          state: alice,
          plaintext: _bytes('identical'),
        );
        seen.add(base64Encode(msg.ciphertext.body));
      }

      expect(seen.length, 25, reason: 'repeated ciphertext means key reuse');
    });

    test('replaying a message fails', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final msg =
          await encryptGroupMessage(state: alice, plaintext: _bytes('once'));
      expect(
        _text(await decryptGroupMessage(
            state: bob, message: msg, currentEpoch: 0)),
        'once',
      );

      // The chain has advanced past this iteration.
      expect(
        () => decryptGroupMessage(state: bob, message: msg, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
    });

    test('refuses to skip more than senderKeyMaxSkip', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final real =
          await encryptGroupMessage(state: alice, plaintext: _bytes('hi'));
      final absurd = SenderKeyMessage(
        chatId: real.chatId,
        epoch: real.epoch,
        senderDeviceId: real.senderDeviceId,
        iteration: senderKeyMaxSkip + 500,
        ciphertext: real.ciphertext,
        signature: real.signature,
      );

      Object? caught;
      try {
        await decryptGroupMessage(
            state: bob, message: absurd, currentEpoch: 0);
        fail('an absurd iteration must be refused');
      } catch (e) {
        caught = e;
      }

      expect(caught.toString(), contains('refusing to derive'),
          reason: 'must be rejected by the skip bound, not by signature or '
              'AEAD failure after deriving hundreds of keys');
    });
  });

  group('persistence', () {
    test('state survives serialization', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final first =
          await encryptGroupMessage(state: alice, plaintext: _bytes('first'));
      await decryptGroupMessage(state: bob, message: first, currentEpoch: 0);

      final aliceRestored = SenderKeyState.fromJson(alice.toJson());
      final bobRestored = SenderKeyState.fromJson(bob.toJson());

      final second = await encryptGroupMessage(
        state: aliceRestored,
        plaintext: _bytes('after restart'),
      );
      expect(
        _text(await decryptGroupMessage(
            state: bobRestored, message: second, currentEpoch: 0)),
        'after restart',
      );
    });

    test('a distributed key carries no signing seed', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final skdm = buildDistributionMessage(alice);
      final serialized = utf8.decode(skdm.serialize());

      expect(serialized.contains(base64Encode(alice.signingSeed!)), isFalse,
          reason: 'distributing the signing seed would let members forge '
              'messages from this sender');
    });

    test('message round trips through the wire format', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final msg =
          await encryptGroupMessage(state: alice, plaintext: _bytes('wire'));
      final parsed = SenderKeyMessage.deserialize(msg.serialize());

      expect(
        _text(await decryptGroupMessage(
            state: bob, message: parsed, currentEpoch: 0)),
        'wire',
      );
    });
  });

  group('ordering and robustness', () {
    test('out-of-order messages decrypt', () async {
      // The server fans group messages out per device, and an offline flush
      // can interleave with live delivery, so order is not guaranteed.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final m0 = await encryptGroupMessage(state: alice, plaintext: _bytes('0'));
      final m1 = await encryptGroupMessage(state: alice, plaintext: _bytes('1'));
      final m2 = await encryptGroupMessage(state: alice, plaintext: _bytes('2'));

      for (final m in [m2, m0, m1]) {
        expect(
          _text(await decryptGroupMessage(
              state: bob, message: m, currentEpoch: 0)),
          '${m.iteration}',
        );
      }
      expect(bob.skippedKeyCount, 0,
          reason: 'a skipped key is removed once it is used');
    });

    test('a skipped key is single use', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final m0 = await encryptGroupMessage(state: alice, plaintext: _bytes('a'));
      final m1 = await encryptGroupMessage(state: alice, plaintext: _bytes('b'));
      await decryptGroupMessage(state: bob, message: m1, currentEpoch: 0);
      await decryptGroupMessage(state: bob, message: m0, currentEpoch: 0);

      await expectLater(
        decryptGroupMessage(state: bob, message: m0, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
    });

    test('skipped keys survive serialization', () async {
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      var bob = _distribute(alice);

      final m0 = await encryptGroupMessage(state: alice, plaintext: _bytes('x'));
      final m1 = await encryptGroupMessage(state: alice, plaintext: _bytes('y'));
      await decryptGroupMessage(state: bob, message: m1, currentEpoch: 0);

      bob = SenderKeyState.fromJson(
        jsonDecode(jsonEncode(bob.toJson())) as Map<String, dynamic>,
      );
      expect(
        _text(await decryptGroupMessage(
            state: bob, message: m0, currentEpoch: 0)),
        'x',
      );
    });

    test('a member cannot swap content under the sender signature', () async {
      // Every member holds the sender's chain key, so a member can produce a
      // ciphertext that decrypts under the sender's next message key. The
      // signature must cover that ciphertext, or the member could attach the
      // sender's genuine signature to it.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final mallory = _distribute(alice);
      final carol = _distribute(alice);

      final genuine =
          await encryptGroupMessage(state: alice, plaintext: _bytes('real'));

      final messageKey =
          (await advanceSenderChainForTesting(mallory.chainKey)).messageKey;
      final substituted = SenderKeyMessage(
        chatId: genuine.chatId,
        epoch: genuine.epoch,
        senderDeviceId: genuine.senderDeviceId,
        iteration: genuine.iteration,
        ciphertext: await aeadEncrypt(
          key: messageKey,
          plaintext: _bytes('forged by mallory'),
          associatedData: genuine.signedBytes,
        ),
        signature: genuine.signature,
      );

      await expectLater(
        decryptGroupMessage(state: carol, message: substituted, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
      // Carol's chain is untouched, so the genuine message still decrypts.
      expect(
        _text(await decryptGroupMessage(
            state: carol, message: genuine, currentEpoch: 0)),
        'real',
      );
    });

    test('a message that fails to decrypt does not advance the chain',
        () async {
      // Signed by the real sender but undecryptable, as a buggy client or
      // corrupted storage would produce. It must not burn the key of the
      // message that follows.
      final alice = await createSenderKey(
        chatId: 'chat-1',
        epoch: 0,
        senderDeviceId: 'alice-1',
      );
      final bob = _distribute(alice);

      final good =
          await encryptGroupMessage(state: alice, plaintext: _bytes('good'));
      final badCiphertext = AeadCiphertext(
        nonce: good.ciphertext.nonce,
        body: Uint8List.fromList(good.ciphertext.body)..[0] ^= 0x01,
        tag: good.ciphertext.tag,
      );
      final bad = SenderKeyMessage(
        chatId: good.chatId,
        epoch: good.epoch,
        senderDeviceId: good.senderDeviceId,
        iteration: good.iteration,
        ciphertext: badCiphertext,
        signature: await sign(
          seed: alice.signingSeed!,
          message:
              SenderKeyMessage.signaturePayload(good.signedBytes, badCiphertext),
        ),
      );

      await expectLater(
        decryptGroupMessage(state: bob, message: bad, currentEpoch: 0),
        throwsA(isA<SenderKeyException>()),
      );
      expect(bob.iteration, 0);
      expect(
        _text(await decryptGroupMessage(
            state: bob, message: good, currentEpoch: 0)),
        'good',
      );
    });
  });
}
