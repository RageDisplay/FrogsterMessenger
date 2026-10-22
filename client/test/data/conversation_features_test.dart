/// Replies, forwards, typing, drafts and this device's own arrangement of
/// the chat list, through real client stacks on the in-memory server.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/repositories/message_repository.dart';

import 'fake_server.dart';

void main() {
  late FakeServer server;
  late FakeDevice alice, bob;
  late FakeChat cloud, secret;
  final opened = <FakeDevice>[];

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

  setUp(() async {
    server = FakeServer();
    alice = await device('alice');
    bob = await device('bob');
    cloud = server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
    secret = server.createChat(type: 'direct', mode: ChatMode.secret, creator: alice.user, members: [bob.user]);
    await online([alice, bob]);
  });

  tearDown(() async {
    for (final d in opened) {
      await d.dispose();
    }
    opened.clear();
  });

  test('a reply names the message it answers, in both kinds of chat', () async {
    for (final chat in [cloud, secret]) {
      final original = await alice.repository.send(chatId: chat.id, body: 'вопрос');
      await server.settle();
      await bob.repository.send(chatId: chat.id, body: 'ответ', replyToId: original.id);
      await server.settle();

      final reply = (await alice.messages(chat.id)).last;
      expect(reply.body, 'ответ');
      expect(reply.replyToId, original.id);
    }
  });

  // A forwarded secret message lands in the cloud chat as a new message:
  // its author's name goes with it, and the copy is readable where it went.
  test('a forward carries the original author', () async {
    await bob.repository.send(chatId: secret.id, body: 'тайный факт');
    await server.settle();
    final received = (await alice.messages(secret.id)).single;

    await alice.repository.forward(received, cloud.id, authorName: 'bob');
    await server.settle();

    final copy = (await bob.messages(cloud.id)).single;
    expect(copy.body, 'тайный факт');
    expect(copy.forwardedFrom, 'bob');
    expect(copy.id, isNot(received.id));
  });

  test('typing reaches the other side, and only now and then', () async {
    final seen = <TypingNotice>[];
    final sub = bob.repository.typing.listen(seen.add);
    for (var i = 0; i < 5; i++) {
      alice.repository.typingIn(cloud.id);
    }
    await server.settle();
    await sub.cancel();

    expect(seen.length, 1, reason: 'five keystrokes, one notice');
    expect(seen.single.userId, alice.user.id);
  });

  test('a sync leaves the draft, pin, mute and archive alone', () async {
    await alice.repository.saveDraft(cloud.id, 'недописанное');
    await alice.repository.setPinned(cloud.id, true);
    await alice.repository.setMuted(cloud.id, true);
    await alice.repository.setArchived(cloud.id, true);

    await alice.repository.sync();
    final chat = (await alice.dao.chatById(cloud.id))!;
    expect(chat.draft, 'недописанное');
    expect(chat.pinned && chat.muted && chat.archived, isTrue);

    await alice.repository.send(chatId: cloud.id, body: 'дописал');
    expect((await alice.dao.chatById(cloud.id))!.draft, isEmpty,
        reason: 'sending clears the draft');
  });

  test('pinned chats come first', () async {
    await alice.repository.send(chatId: cloud.id, body: 'новее');
    await server.settle();
    await alice.repository.setPinned(secret.id, true);
    final order = [for (final c in await alice.dao.chats()) c.id];
    expect(order.first, secret.id);
  });

  // Deleting a cloud chat clears it for us on the server too, or the next
  // sync would bring the history straight back.
  test('a deleted cloud chat stays deleted until someone writes again', () async {
    await bob.repository.send(chatId: cloud.id, body: 'старое');
    await server.settle();

    await alice.repository.deleteDirectChat(cloud.id);
    await alice.repository.sync();
    expect(await alice.messages(cloud.id), isEmpty);
    expect((await alice.dao.chatById(cloud.id))!.hidden, isTrue);

    final laptop = await device('alice');
    await online([laptop]);
    expect(await laptop.messages(cloud.id), isEmpty, reason: 'cleared on every device');

    await bob.repository.send(chatId: cloud.id, body: 'новое');
    await server.settle();
    expect(bodies(await alice.messages(cloud.id)), ['новое']);
    expect((await alice.dao.chatById(cloud.id))!.hidden, isFalse);

    // Bob's history is his own.
    expect(bodies(await bob.messages(cloud.id)), ['старое', 'новое']);
  });

  test('a deleted secret chat loses its history here only', () async {
    await bob.repository.send(chatId: secret.id, body: 'было');
    await server.settle();
    await alice.repository.deleteDirectChat(secret.id);
    expect(await alice.messages(secret.id), isEmpty);
    expect(bodies(await bob.messages(secret.id)), ['было']);
  });

  test('typing notices are not mixed up between chats', () async {
    final completer = Completer<TypingNotice>();
    final sub = bob.repository.typing.listen(completer.complete);
    alice.repository.typingIn(secret.id);
    final notice = await completer.future.timeout(const Duration(seconds: 5));
    await sub.cancel();
    expect(notice.chatId, secret.id);
  });
}
