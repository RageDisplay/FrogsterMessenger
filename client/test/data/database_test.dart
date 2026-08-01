import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/ratchet/sender_key.dart';
import 'package:frogster/crypto/safety_number.dart';
import 'package:frogster/data/local/dao/message_dao.dart';
import 'package:frogster/data/local/dao/session_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/models/models.dart';

void main() {
  late AppDatabase database;
  late MessageDao messages;
  late SqfliteSessionStore sessions;
  late SenderKeyDao senderKeys;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    messages = MessageDao(database.db);
    sessions = SqfliteSessionStore(database.db);
    senderKeys = SenderKeyDao(database.db);
  });

  tearDown(() async => database.close());

  Message sample({
    String id = 'm1',
    String chatId = 'c1',
    int? seq,
    MessageStatus status = MessageStatus.sent,
    bool outgoing = false,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: 'alice',
        senderDeviceId: 'dev-1',
        body: 'hello',
        sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
        isOutgoing: outgoing,
        seq: seq,
        status: status,
      );

  Future<void> seedChat([String id = 'c1']) => messages.upsertChat(
        Chat(id: id, type: 'direct', epoch: 0, peerUsername: 'bob'),
      );

  group('messages', () {
    test('round trips', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      final loaded = await messages.messageById('m1');
      expect(loaded, isNotNull);
      expect(loaded!.body, 'hello');
      expect(loaded.seq, 1);
      expect(loaded.status, MessageStatus.sent);
    });

    test('redelivery does not duplicate history', () async {
      // The server may hand a device the same message twice after a
      // reconnect; that must not show up twice in the chat.
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));
      await messages.upsertMessage(sample(seq: 1));

      final all = await messages.messagesForChat('c1');
      expect(all.length, 1);
    });

    test('orders acknowledged messages before pending ones', () async {
      // A message awaiting its ack has no seq yet. It belongs at the end,
      // where the user just typed it, not at the top of the history.
      await seedChat();
      await messages.upsertMessage(sample(id: 'm2', seq: 2));
      await messages.upsertMessage(sample(id: 'm1', seq: 1));
      await messages.upsertMessage(
        sample(id: 'm3', status: MessageStatus.pending, outgoing: true),
      );

      final ordered = await messages.messagesForChat('c1');
      expect(ordered.map((m) => m.id).toList(), ['m1', 'm2', 'm3']);
    });

    test('status update attaches the server sequence', () async {
      await seedChat();
      await messages.upsertMessage(
        sample(id: 'm1', status: MessageStatus.pending, outgoing: true),
      );

      await messages.updateStatus('m1', MessageStatus.sent, seq: 42);

      final updated = await messages.messageById('m1');
      expect(updated!.status, MessageStatus.sent);
      expect(updated.seq, 42);
    });

    test('deleting a chat removes its messages', () async {
      // Relies on PRAGMA foreign_keys being on; SQLite ignores cascades
      // without it, which would silently orphan rows.
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      await database.db.delete('chats', where: 'id = ?', whereArgs: ['c1']);

      final remaining = await messages.messagesForChat('c1');
      expect(remaining, isEmpty);
    });
  });

  group('reactions', () {
    test('adds and removes', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      await messages.applyReaction(
        targetId: 'm1',
        emoji: '👍',
        userId: 'bob',
        remove: false,
      );
      var loaded = await messages.messageById('m1');
      expect(loaded!.reactions['👍'], contains('bob'));

      await messages.applyReaction(
        targetId: 'm1',
        emoji: '👍',
        userId: 'bob',
        remove: true,
      );
      loaded = await messages.messageById('m1');
      expect(loaded!.reactions.containsKey('👍'), isFalse);
    });

    test('several users on one emoji', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      for (final user in ['bob', 'carol']) {
        await messages.applyReaction(
          targetId: 'm1',
          emoji: '🎉',
          userId: user,
          remove: false,
        );
      }

      final loaded = await messages.messageById('m1');
      expect(loaded!.reactions['🎉'], {'bob', 'carol'});
    });

    test('reacting twice is idempotent', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      for (var i = 0; i < 3; i++) {
        await messages.applyReaction(
          targetId: 'm1',
          emoji: '👍',
          userId: 'bob',
          remove: false,
        );
      }

      final loaded = await messages.messageById('m1');
      expect(loaded!.reactions['👍']!.length, 1);
    });
  });

  group('chat list', () {
    test('sorts by most recent activity', () async {
      await messages.upsertChat(
        Chat(id: 'old', type: 'direct', epoch: 0, peerUsername: 'a'),
      );
      await messages.upsertChat(
        Chat(id: 'new', type: 'direct', epoch: 0, peerUsername: 'b'),
      );

      await messages.touchChat(
          'old', 'older', DateTime.fromMillisecondsSinceEpoch(1000));
      await messages.touchChat(
          'new', 'newer', DateTime.fromMillisecondsSinceEpoch(5000));

      final list = await messages.chats();
      expect(list.first.id, 'new');
      expect(list.first.lastMessagePreview, 'newer');
    });

    test('tracks unread counts', () async {
      await seedChat();

      for (var i = 0; i < 3; i++) {
        await messages.touchChat('c1', 'msg', DateTime.now(),
            incrementUnread: true);
      }
      var list = await messages.chats();
      expect(list.first.unreadCount, 3);

      await messages.clearUnread('c1');
      list = await messages.chats();
      expect(list.first.unreadCount, 0);
    });
  });

  group('ratchet session store', () {
    test('round trips session state', () async {
      await sessions.saveSession('alice:dev-1', {'rk': 'abc', 'ns': 5});

      final loaded = await sessions.loadSession('alice:dev-1');
      expect(loaded, {'rk': 'abc', 'ns': 5});
    });

    test('overwrites on save', () async {
      // Every message advances the ratchet, so saves are frequent and must
      // replace rather than accumulate.
      await sessions.saveSession('alice:dev-1', {'ns': 1});
      await sessions.saveSession('alice:dev-1', {'ns': 2});

      final loaded = await sessions.loadSession('alice:dev-1');
      expect(loaded!['ns'], 2);
    });

    test('delete removes the session', () async {
      await sessions.saveSession('alice:dev-1', {'ns': 1});
      await sessions.deleteSession('alice:dev-1');

      expect(await sessions.loadSession('alice:dev-1'), isNull);
    });
  });

  group('pinned identities', () {
    test('round trips', () async {
      final key = Uint8List.fromList(List.filled(32, 7));
      await sessions.savePinnedIdentity(PinnedIdentity(
        userId: 'bob',
        deviceId: 'dev-1',
        identityKey: key,
        pinnedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      ));

      final loaded = await sessions.loadPinnedIdentity('bob:dev-1');
      expect(loaded!.identityKey, equals(key));
      expect(loaded.acceptedChange, isFalse);
    });

    test('records an accepted key change', () async {
      final key = Uint8List.fromList(List.filled(32, 7));
      await sessions.savePinnedIdentity(PinnedIdentity(
        userId: 'bob',
        deviceId: 'dev-1',
        identityKey: key,
        pinnedAt: DateTime.now(),
        acceptedChange: true,
      ));

      final loaded = await sessions.loadPinnedIdentity('bob:dev-1');
      expect(loaded!.acceptedChange, isTrue);
    });
  });

  group('sender keys', () {
    test('round trips own and peer keys', () async {
      final own = await createSenderKey(
        chatId: 'g1',
        epoch: 0,
        senderDeviceId: 'my-dev',
      );
      await senderKeys.save(own, isOwn: true);

      final loaded = await senderKeys.loadOwn(chatId: 'g1', epoch: 0);
      expect(loaded, isNotNull);
      expect(loaded!.senderDeviceId, 'my-dev');
      expect(loaded.signingSeed, isNotNull,
          reason: 'our own key must keep its signing seed so we can send');
    });

    test('purges keys from earlier epochs', () async {
      // When a member leaves, the chat advances; keys from the old epoch are
      // known to them and must not linger where they could be reused.
      final epoch0 = await createSenderKey(
        chatId: 'g1',
        epoch: 0,
        senderDeviceId: 'dev-a',
      );
      final epoch1 = await createSenderKey(
        chatId: 'g1',
        epoch: 1,
        senderDeviceId: 'dev-a',
      );
      await senderKeys.save(epoch0, isOwn: false);
      await senderKeys.save(epoch1, isOwn: false);

      await senderKeys.purgeStaleEpochs(chatId: 'g1', currentEpoch: 1);

      expect(
        await senderKeys.load(chatId: 'g1', epoch: 0, deviceId: 'dev-a'),
        isNull,
        reason: 'stale-epoch sender keys must be deleted on rotation',
      );
      expect(
        await senderKeys.load(chatId: 'g1', epoch: 1, deviceId: 'dev-a'),
        isNotNull,
      );
    });

    test('keys from different senders coexist in one epoch', () async {
      for (final dev in ['dev-a', 'dev-b']) {
        await senderKeys.save(
          await createSenderKey(chatId: 'g1', epoch: 0, senderDeviceId: dev),
          isOwn: false,
        );
      }

      expect(
        await senderKeys.load(chatId: 'g1', epoch: 0, deviceId: 'dev-a'),
        isNotNull,
      );
      expect(
        await senderKeys.load(chatId: 'g1', epoch: 0, deviceId: 'dev-b'),
        isNotNull,
      );
    });
  });

  group('wipe', () {
    test('removes everything on logout', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));
      await sessions.saveSession('alice:dev-1', {'ns': 1});

      await database.wipe();

      expect(await messages.chats(), isEmpty);
      expect(await messages.messagesForChat('c1'), isEmpty);
      expect(await sessions.loadSession('alice:dev-1'), isNull);
    });
  });

  group('attachments', () {
    test('round trip through the messages table', () async {
      await seedChat();
      await messages.upsertMessage(Message(
        id: 'm-file',
        chatId: 'c1',
        senderId: 'alice',
        senderDeviceId: 'dev-1',
        body: 'see attached',
        sentAt: DateTime.fromMillisecondsSinceEpoch(1000),
        isOutgoing: false,
        seq: 1,
        attachment: const AttachmentPayload(
          blobId: 'blob-1',
          key: 'a2V5',
          digest: 'ZGln',
          size: 4096,
          mimeType: 'image/png',
          fileName: 'photo.png',
        ),
      ));

      final loaded = await messages.messageById('m-file');
      expect(loaded!.hasAttachment, isTrue);
      expect(loaded.attachment!.blobId, 'blob-1');
      expect(loaded.attachment!.key, 'a2V5',
          reason: 'the key must survive: without it the blob is unreadable');
      expect(loaded.attachment!.mimeType, 'image/png');
    });

    test('a message without an attachment stays null', () async {
      await seedChat();
      await messages.upsertMessage(sample(seq: 1));

      final loaded = await messages.messageById('m1');
      expect(loaded!.hasAttachment, isFalse);
      expect(loaded.attachment, isNull);
    });
  });
}
