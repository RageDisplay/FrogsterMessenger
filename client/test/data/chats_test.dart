/// Cloud and secret chats, direct and group, driven end to end through real
/// client stacks talking to an in-memory server.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  final opened = <FakeDevice>[];

  setUp(() => server = FakeServer());
  tearDown(() async {
    for (final d in opened) {
      await d.dispose();
    }
    opened.clear();
  });

  Future<FakeDevice> device(String username) async {
    final d = await server.addDevice(username);
    opened.add(d);
    return d;
  }

  Future<void> online(Iterable<FakeDevice> devices) async {
    for (final d in devices) {
      await d.ws.connect();
    }
    await server.settle();
  }

  group('secret group', () {
    late FakeDevice alice, bob, carol;
    late FakeChat chat;

    setUp(() async {
      alice = await device('alice');
      bob = await device('bob');
      carol = await device('carol');
      chat = server.createChat(
        type: 'group',
        mode: ChatMode.secret,
        creator: alice.user,
        members: [bob.user, carol.user],
      );
      await online([alice, bob, carol]);
    });

    test('every member reads it, the server reads nothing', () async {
      await alice.repository.send(chatId: chat.id, body: 'привет, пруд');
      await server.settle();
      await bob.repository.send(chatId: chat.id, body: 'ответ боба');
      await server.settle();

      expect(bodies(await bob.messages(chat.id)), ['привет, пруд', 'ответ боба']);
      expect(bodies(await carol.messages(chat.id)), ['привет, пруд', 'ответ боба']);
      expect(bodies(await alice.messages(chat.id)), ['привет, пруд', 'ответ боба']);
      expect(serverSaw(server, 'привет, пруд'), isFalse);
      expect(serverSaw(server, 'ответ боба'), isFalse);
    });

    // The point of epochs. Even a server that keeps handing the removed
    // member the group's traffic gives them nothing they can read.
    test('a removed member cannot read what follows', () async {
      await alice.repository.send(chatId: chat.id, body: 'до');
      await server.settle();

      server.removeMember(chat, carol.user);
      server.leakTo.add(carol.id);
      await server.settle();

      await alice.repository.send(chatId: chat.id, body: 'после удаления');
      await server.settle();

      expect(bodies(await bob.messages(chat.id)), ['до', 'после удаления']);
      expect(bodies(await carol.messages(chat.id)), isNot(contains('после удаления')));
    });

    test('a sender caught out by a membership change sends again under the new epoch', () async {
      await alice.repository.send(chatId: chat.id, body: 'раз');
      await server.settle();

      // The group moves on without telling alice: her next message is for
      // an epoch the server has left.
      server.removeMember(chat, carol.user, notify: false);
      await alice.repository.send(chatId: chat.id, body: 'два');
      await server.settle();

      expect(bodies(await bob.messages(chat.id)), ['раз', 'два']);
      final mine = await alice.messages(chat.id);
      expect(mine.last.status, MessageStatus.sent);
    });

    test('a new member reads from when they joined, never before', () async {
      await alice.repository.send(chatId: chat.id, body: 'тайна до вступления');
      await server.settle();

      final dave = await device('dave');
      await online([dave]);
      server.addMember(chat, dave.user);
      await server.settle();

      await alice.repository.send(chatId: chat.id, body: 'добро пожаловать');
      await server.settle();

      expect(bodies(await dave.messages(chat.id)), ['добро пожаловать']);
    });

    test('the name travels end to end and only an admin sets it', () async {
      await alice.repository.renameSecretGroup(chat.id, 'Болото');
      await server.settle();
      expect((await bob.dao.chatById(chat.id))!.title, 'Болото');
      expect(serverSaw(server, 'Болото'), isFalse);

      await carol.repository.renameSecretGroup(chat.id, 'Захват');
      await server.settle();
      expect((await bob.dao.chatById(chat.id))!.title, 'Болото',
          reason: 'a plain member renamed the group');
    });
  });

  group('cloud chat', () {
    late FakeDevice alice, bob;
    late FakeChat chat;

    setUp(() async {
      alice = await device('alice');
      bob = await device('bob');
      chat = server.createChat(
        type: 'direct',
        mode: ChatMode.cloud,
        creator: alice.user,
        members: [bob.user],
      );
      await online([alice, bob]);
    });

    test('edits and deletions reach the other side; only the author edits', () async {
      final sent = await alice.repository.send(chatId: chat.id, body: 'черновик');
      await server.settle();
      final stored = (await alice.dao.messageById(sent.id))!;

      await alice.repository.edit(stored, 'чистовик');
      await server.settle();
      final atBob = (await bob.messages(chat.id)).single;
      expect(atBob.body, 'чистовик');
      expect(atBob.isEdited, isTrue);

      // Bob trying to edit alice's message changes nothing anywhere.
      final fake = atBob.copyWith();
      await bob.repository.edit(
        Message(
          id: fake.id,
          chatId: chat.id,
          senderId: bob.user.id,
          senderDeviceId: bob.id,
          body: fake.body,
          sentAt: fake.sentAt,
          isOutgoing: true,
          seq: fake.seq,
        ),
        'подделка',
      );
      await server.settle();
      expect((await alice.messages(chat.id)).single.body, 'чистовик');

      await alice.repository.delete((await alice.dao.messageById(sent.id))!);
      await server.settle();
      expect(await bob.messages(chat.id), isEmpty);
    });

    test('history follows the user to a new device; reactions and edits included', () async {
      final first = await alice.repository.send(chatId: chat.id, body: 'один');
      await server.settle();
      await bob.repository.react(chatId: chat.id, targetId: first.id, emoji: '🐸');
      await alice.repository.send(chatId: chat.id, body: 'два');
      await server.settle();

      final laptop = await device('bob');
      await online([laptop]);

      final history = await laptop.messages(chat.id);
      expect(bodies(history), ['один', 'два']);
      expect(history.every((m) => !m.isOutgoing), isTrue);
    });

    test('a device that was away catches up on what it missed', () async {
      bob.ws.goOffline();
      await alice.repository.send(chatId: chat.id, body: 'пока тебя не было');
      await server.settle();
      final sent = (await alice.messages(chat.id)).single;
      await alice.repository.edit(sent, 'пока тебя не было (исправлено)');
      await server.settle();

      await online([bob]);
      expect(bodies(await bob.messages(chat.id)), ['пока тебя не было (исправлено)']);
    });

    test('read ticks follow the reader', () async {
      final sent = await alice.repository.send(chatId: chat.id, body: 'прочти');
      await server.settle();
      await bob.repository.markRead(chat.id);
      await server.settle();

      expect((await alice.dao.messageById(sent.id))!.status, MessageStatus.read);
    });
  });

  group('secret direct chat', () {
    late FakeDevice alice, bob;
    late FakeChat chat;

    setUp(() async {
      alice = await device('alice');
      bob = await device('bob');
      chat = server.createChat(
        type: 'direct',
        mode: ChatMode.secret,
        creator: alice.user,
        members: [bob.user],
      );
      await online([alice, bob]);
      await alice.repository.sync();
    });

    test('works as before and keeps no history for new devices', () async {
      await alice.repository.send(chatId: chat.id, body: 'только для тебя');
      await server.settle();
      expect(bodies(await bob.messages(chat.id)), ['только для тебя']);
      expect(serverSaw(server, 'только для тебя'), isFalse);

      final laptop = await device('bob');
      await online([laptop]);
      expect(await laptop.messages(chat.id), isEmpty);
    });

    // A server that slips a plaintext message into a secret chat must not
    // get it shown as if it had been end-to-end encrypted.
    test('a plaintext message injected into it is refused', () async {
      bob.deliver({
        'type': 'msg',
        'id': 'injected',
        'chat_id': chat.id,
        'sender': {'user_id': alice.user.id, 'device_id': alice.id},
        'ct_type': 0,
        'ciphertext': base64Encode(utf8.encode(jsonEncode({'body': 'подброшено'}))),
        'seq': 99,
      });
      await server.settle();
      expect(await bob.dao.messageById('injected'), isNull);
    });

    test('a message written offline goes out when the connection returns', () async {
      alice.ws.goOffline();
      await alice.repository.send(chatId: chat.id, body: 'в самолёте');
      expect((await alice.outbox.pending()).length, 1);

      await online([alice]);
      expect(bodies(await bob.messages(chat.id)), ['в самолёте']);
      expect(await alice.outbox.pending(), isEmpty);
      expect((await alice.messages(chat.id)).single.status, MessageStatus.sent);
    });
  });
}
