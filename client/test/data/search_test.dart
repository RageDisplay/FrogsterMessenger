import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/local/dao/message_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/models/models.dart';

import 'migration_test.dart' show openV1;

void main() {
  late Directory dir;
  late AppDatabase db;
  late MessageDao dao;

  Message message(String id, String chatId, String body) => Message(
        id: id,
        chatId: chatId,
        senderId: 'u',
        senderDeviceId: 'd',
        body: body,
        sentAt: DateTime(2026, 1, 1, 12, int.parse(id.substring(1))),
        isOutgoing: false,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('frogster_search');
    db = await AppDatabase.open(path: '${dir.path}/f.db');
    dao = MessageDao(db.db);
    await dao.upsertChat(const Chat(id: 'a', type: 'direct', epoch: 0));
    await dao.upsertChat(const Chat(id: 'b', type: 'direct', epoch: 0));
    await dao.upsertMessage(message('m1', 'a', 'Привет из Пруда'));
    await dao.upsertMessage(message('m2', 'a', 'скидка 50% на мух'));
    await dao.upsertMessage(message('m3', 'b', 'пруд_2 и PRUD'));
  });

  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  List<String> ids(List<Message> found) => [for (final m in found) m.id];

  // SQLite folds only ASCII; Cyrillic must match whatever its case.
  test('finds words whatever their case, in any script', () async {
    expect(ids(await dao.search('пруд')), unorderedEquals(['m1', 'm3']));
    expect(ids(await dao.search('ПРИВЕТ')), ['m1']);
    expect(ids(await dao.search('prud')), ['m3']);
  });

  test('wildcards in the query are ordinary characters', () async {
    expect(ids(await dao.search('50%')), ['m2']);
    expect(ids(await dao.search('%')), ['m2']);
    expect(ids(await dao.search('_2')), ['m3']);
    expect(ids(await dao.search('д_2')), ['m3']);
  });

  test('can be limited to one chat', () async {
    expect(ids(await dao.search('пруд', chatId: 'b')), ['m3']);
  });

  test('an edit is found by its new words, not its old ones', () async {
    await dao.editMessage('m1', 'Здравствуй', DateTime(2026));
    expect(await dao.search('привет'), isEmpty);
    expect(ids(await dao.search('здравствуй')), ['m1']);
  });

  test('messages from before search existed are found after the upgrade', () async {
    final path = '${dir.path}/old.db';
    final v1 = await openV1(path);
    await v1.insert('chats', {'id': 'c', 'type': 'direct', 'epoch': 0});
    await v1.insert('messages', {
      'id': 'old',
      'chat_id': 'c',
      'sender_id': 'u',
      'sender_device_id': 'd',
      'body': 'Старое Сообщение',
      'sent_at': 1,
      'is_outgoing': 0,
      'status': 'delivered',
    });
    await v1.close();

    final upgraded = await AppDatabase.open(path: path);
    expect(ids(await MessageDao(upgraded.db).search('сообщение')), ['old']);
    await upgraded.close();
  });
}
