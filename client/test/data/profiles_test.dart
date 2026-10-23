/// Presence, avatars and searching the server's history, through real
/// client stacks on the in-memory server.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/repositories/avatar_store.dart';
import 'package:frogster/data/repositories/presence_tracker.dart';
import 'package:image/image.dart' as img;

import 'fake_server.dart';

void main() {
  group('presence', () {
    late FakeServer server;
    late FakeDevice alice, bob;
    late PresenceTracker tracker;

    setUp(() async {
      server = FakeServer();
      alice = await server.addDevice('alice');
      bob = await server.addDevice('bob');
      server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
      await alice.repository.sync();
      tracker = PresenceTracker(
        ws: alice.ws,
        api: alice.api,
        contacts: () async => [
          for (final chat in await alice.dao.chats())
            for (final m in chat.members)
              if (m.userId != alice.user.id) m.userId,
        ],
      );
    });

    tearDown(() async {
      await tracker.dispose();
      await alice.dispose();
      await bob.dispose();
    });

    test('asks for everyone it talks to on connecting, and follows the news', () async {
      final seen = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      alice.api.presenceAnswers = {bob.user.id: Presence(PresenceStatus.offline, seen)};
      await alice.ws.connect();
      await server.settle();

      expect(alice.api.presenceAsked.single, [bob.user.id]);
      expect(tracker.of(bob.user.id).status, PresenceStatus.offline);
      expect(tracker.of(bob.user.id).lastSeen, seen);

      alice.deliver({'type': 'presence', 'sender': {'user_id': bob.user.id}, 'kind': 'online'});
      await pumpEventQueue();
      expect(tracker.of(bob.user.id).isOnline, isTrue);

      alice.deliver({'type': 'presence', 'sender': {'user_id': bob.user.id}, 'kind': 'recently'});
      await pumpEventQueue();
      expect(tracker.of(bob.user.id).status, PresenceStatus.recently);
      expect(tracker.of(bob.user.id).lastSeen, isNull);
    });

    // In the background the app keeps its connection for messages, but must
    // not look like someone reading.
    test('tells the server when the app goes to the background and back', () async {
      await alice.ws.connect();
      await server.settle();
      List<String> kinds() => [
            for (final raw in server.received)
              if ((jsonDecode(raw) as Map<String, dynamic>)['type'] == 'presence')
                (jsonDecode(raw) as Map<String, dynamic>)['kind'] as String,
          ];
      expect(kinds(), isEmpty, reason: 'a new connection counts as active');

      tracker.setActive(false);
      tracker.setActive(false);
      await server.settle();
      expect(kinds(), ['idle']);

      // Reconnecting while in the background says so again.
      alice.ws.goOffline();
      await alice.ws.connect();
      await server.settle();
      expect(kinds(), ['idle', 'idle']);

      tracker.setActive(true);
      await server.settle();
      expect(kinds(), ['idle', 'idle', 'active']);
    });
  });

  group('server search', () {
    test('finds cloud messages this device never loaded, and keeps none', () async {
      final server = FakeServer();
      final alice = await server.addDevice('alice');
      final bob = await server.addDevice('bob');
      final chat = server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
      for (final d in [alice, bob]) {
        await d.ws.connect();
      }
      await server.settle();
      await alice.repository.send(chatId: chat.id, body: 'Пароль от роутера: квакква');
      await alice.repository.send(chatId: chat.id, body: 'что-то другое');
      await server.settle();

      // A new phone of bob's: nothing local yet but the chat itself.
      final phone = await server.addDevice('bob');
      final local = chat.rows.length;
      await phone.dao.upsertChat(
        (await phone.api.getChat(chat.id)).toChat(bob.user.id),
      );
      final found = await phone.repository.searchServer('ПАРОЛЬ');
      expect(found.map((m) => m.body), ['Пароль от роутера: квакква']);
      expect(found.single.chatId, chat.id);
      expect(await phone.messages(chat.id), isEmpty, reason: 'a lone old message would hide a gap');
      expect(chat.rows.length, local);

      await alice.dispose();
      await bob.dispose();
      await phone.dispose();
    });
  });

  group('avatars', () {
    late Directory dir;
    late Map<String, Uint8List> remote;
    late List<String> fetched;
    late AvatarStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('frogster-avatars');
      remote = {'user_u1': Uint8List.fromList([1, 2, 3])};
      fetched = [];
      store = AvatarStore(
        fetch: (owner, id) async {
          fetched.add('${owner.name}_$id');
          return remote['${owner.name}_$id'];
        },
        cacheDir: dir,
      );
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<Uint8List?> settled(AvatarOwner owner, String id, int version, [AvatarStore? s]) async {
      final value = (s ?? store).watch(owner, id, version);
      for (var i = 0; i < 50 && value.value == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return value.value;
    }

    test('one fetch per version, then from disk', () async {
      expect(await settled(AvatarOwner.user, 'u1', 1), [1, 2, 3]);
      expect(await settled(AvatarOwner.user, 'u1', 1), [1, 2, 3]);
      expect(fetched, ['user_u1']);

      final restarted = AvatarStore(fetch: (_, _) async => fail('the disk copy was ignored'), cacheDir: dir);
      expect(await settled(AvatarOwner.user, 'u1', 1, restarted), [1, 2, 3]);
    });

    test('a new version replaces the old picture, a removed one goes', () async {
      await settled(AvatarOwner.user, 'u1', 1);
      remote['user_u1'] = Uint8List.fromList([9]);
      expect(await settled(AvatarOwner.user, 'u1', 2), [9]);
      expect(dir.listSync().map((f) => f.uri.pathSegments.last), ['user_u1_2']);

      expect(store.watch(AvatarOwner.user, 'u1', -3).value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(dir.listSync(), isEmpty);
    });

    test('nothing is fetched for someone without a picture', () async {
      expect(store.watch(AvatarOwner.chat, 'c1', 0).value, isNull);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(fetched, isEmpty);
    });

    test('an uploaded picture shows at once', () async {
      await store.put(AvatarOwner.user, 'me', 4, Uint8List.fromList([7, 7]));
      expect(store.watch(AvatarOwner.user, 'me', 4).value, [7, 7]);
      expect(fetched, isEmpty);
    });

    test('an id from the server never names a path outside the cache', () async {
      remote['user_../../x'] = Uint8List.fromList([1]);
      await settled(AvatarOwner.user, '../../x', 1);
      expect(File('${dir.parent.path}/x_1').existsSync(), isFalse);
      expect(dir.existsSync() ? dir.listSync() : const [], isEmpty);
    });

    test('any photo becomes a small upright square', () async {
      final photo = img.Image(width: 1200, height: 800);
      img.fill(photo, color: img.ColorRgb8(91, 43, 209));
      final avatar = await prepareAvatar(Uint8List.fromList(img.encodePng(photo)));
      final decoded = img.decodeJpg(avatar)!;
      expect((decoded.width, decoded.height), (avatarPixels, avatarPixels));
      expect(avatar.length, lessThan(100 * 1024));
      await expectLater(prepareAvatar(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    });
  });
}
