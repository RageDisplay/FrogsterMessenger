import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/notifications/notification_service.dart';

import 'fake_server.dart';

const _texts = NotificationTexts(
  newMessage: 'Новое сообщение',
  photo: 'Фото',
  file: 'Файл',
  voice: 'Голосовое сообщение',
  appName: 'Frogster',
);

Message _msg({bool outgoing = false, String body = 'привет', AttachmentPayload? attachment}) => Message(
      id: 'm',
      chatId: 'c',
      senderId: 'anya',
      senderDeviceId: 'd',
      body: body,
      sentAt: DateTime(2026),
      isOutgoing: outgoing,
      attachment: attachment,
    );

const _chat = Chat(
  id: 'c',
  type: 'group',
  epoch: 0,
  title: 'Пруд',
  members: [ChatMember(userId: 'anya', username: 'anya', displayName: 'Аня')],
);

void main() {
  group('when to notify', () {
    bool decide({Message? message, Chat? chat = _chat, bool enabled = true, bool front = false, String? open}) =>
        shouldNotify(
          message: message ?? _msg(),
          chat: chat,
          enabled: enabled,
          appInFront: front,
          openChatId: open,
        );

    test('a new message from someone else, app in the background', () => expect(decide(), isTrue));
    test('not when turned off', () => expect(decide(enabled: false), isFalse));
    test('not for our own message from another device', () => expect(decide(message: _msg(outgoing: true)), isFalse));
    test('not in a muted chat', () => expect(decide(chat: _chat.copyWith(muted: true)), isFalse));
    test('not for the chat on screen', () => expect(decide(front: true, open: 'c'), isFalse));
    test('yes for another chat while one is open', () => expect(decide(front: true, open: 'other'), isTrue));
    test('yes for the open chat when the window is hidden', () => expect(decide(front: false, open: 'c'), isTrue));
  });

  group('what it says', () {
    test('a group names the sender and the group', () {
      final c = notificationContent(message: _msg(), chat: _chat, showPreview: true, texts: _texts);
      expect(c.title, 'Аня · Пруд');
      expect(c.body, 'привет');
    });

    test('without preview: no name, no words', () {
      final c = notificationContent(message: _msg(), chat: _chat, showPreview: false, texts: _texts);
      expect(c.title, 'Frogster');
      expect(c.body, 'Новое сообщение');
    });

    test('a photo or a voice message says what it is', () {
      const photo = AttachmentPayload(blobId: 'b', key: 'k', digest: 'd', size: 1, mimeType: 'image/png');
      const voice = AttachmentPayload(blobId: 'b', key: 'k', digest: 'd', size: 1, mimeType: 'audio/mp4');
      expect(notificationContent(message: _msg(body: '', attachment: photo), chat: _chat, showPreview: true, texts: _texts).body, 'Фото');
      expect(notificationContent(message: _msg(body: '', attachment: voice), chat: _chat, showPreview: true, texts: _texts).body, 'Голосовое сообщение');
    });

    test('one notification per chat, the same on every run', () {
      expect(notificationIdFor('chat-1'), notificationIdFor('chat-1'));
      expect(notificationIdFor('chat-1'), isNot(notificationIdFor('chat-2')));
      expect(notificationIdFor('chat-1'), greaterThanOrEqualTo(0));
    });
  });

  // Only messages as they arrive notify: our own from another device do
  // not, and neither does history a sync brings in.
  test('arrivals are new messages from others only', () async {
    final server = FakeServer();
    final alice = await server.addDevice('alice');
    final bob = await server.addDevice('bob');
    final bobLaptop = await server.addDevice('bob');
    final chat = server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
    for (final d in [alice, bob, bobLaptop]) {
      await d.ws.connect();
    }
    await server.settle();

    final arrived = <String>[];
    final sub = bobLaptop.repository.arrivals.listen((m) => arrived.add(m.body));

    await alice.repository.send(chatId: chat.id, body: 'от алисы');
    await bob.repository.send(chatId: chat.id, body: 'от бобa с телефона');
    await server.settle();
    expect(arrived, ['от алисы']);

    // A brand-new device syncing history: nothing to announce.
    final fresh = await server.addDevice('bob');
    final freshArrived = <String>[];
    final freshSub = fresh.repository.arrivals.listen((m) => freshArrived.add(m.body));
    await fresh.ws.connect();
    await server.settle();
    expect(await fresh.messages(chat.id), hasLength(2));
    expect(freshArrived, isEmpty);

    await sub.cancel();
    await freshSub.cancel();
    for (final d in [alice, bob, bobLaptop, fresh]) {
      await d.dispose();
    }
  });
}
