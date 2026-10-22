/// Key material in the local database is sealed, and what an older version
/// wrote in the clear still opens.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/crypto/ratchet/sender_key.dart';
import 'package:frogster/crypto/state_sealer.dart';
import 'package:frogster/data/local/dao/message_dao.dart';
import 'package:frogster/data/local/dao/session_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/models/models.dart';

import 'migration_test.dart' show openV1;

void main() {
  late Directory dir;
  late String path;
  final sealer = StateSealer(Uint8List.fromList(List.generate(32, (i) => i)));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('frogster_sealed');
    path = '${dir.path}/frogster.db';
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('ratchet state is unreadable in the database file', () async {
    final db = await AppDatabase.open(path: path);
    final store = SqfliteSessionStore(db.db, sealer: sealer);
    await store.saveSession('bob:dev', {'rk': 'ROOTKEYMATERIAL', 'ns': 3});

    final raw = (await db.db.query('ratchet_sessions')).single['state'] as String;
    expect(raw, isNot(contains('ROOTKEYMATERIAL')));
    expect(StateSealer.isSealed(raw), isTrue);
    expect((await store.loadSession('bob:dev'))!['rk'], 'ROOTKEYMATERIAL');
    await db.close();
  });

  test('a sealed row moved under another peer does not open', () async {
    final db = await AppDatabase.open(path: path);
    final store = SqfliteSessionStore(db.db, sealer: sealer);
    await store.saveSession('bob:dev', {'rk': 'x'});
    final raw = (await db.db.query('ratchet_sessions')).single['state'] as String;
    await db.db.insert('ratchet_sessions', {'peer_key': 'eve:dev', 'state': raw});

    expect(() => store.loadSession('eve:dev'), throwsA(anything));
    await db.close();
  });

  test('another key cannot open it', () async {
    final db = await AppDatabase.open(path: path);
    await SqfliteSessionStore(db.db, sealer: sealer).saveSession('bob:dev', {'rk': 'x'});
    final other = StateSealer(Uint8List(32));
    expect(() => SqfliteSessionStore(db.db, sealer: other).loadSession('bob:dev'),
        throwsA(anything));
    await db.close();
  });

  // Upgrading must not cost a single conversation: rows written in the
  // clear before sealing existed are read as they are and sealed on the
  // next save.
  test('state from before sealing still opens and is sealed when saved again', () async {
    final v1 = await openV1(path);
    await v1.insert('chats', {'id': 'c1', 'type': 'direct', 'epoch': 0, 'peer_username': 'bob'});
    await v1.insert('ratchet_sessions', {'peer_key': 'bob:dev', 'state': '{"rk":"old","ns":7}'});
    await v1.close();

    final db = await AppDatabase.open(path: path);
    final store = SqfliteSessionStore(db.db, sealer: sealer);
    final state = await store.loadSession('bob:dev');
    expect(state!['rk'], 'old');

    await store.saveSession('bob:dev', {...state, 'ns': 8});
    final raw = (await db.db.query('ratchet_sessions')).single['state'] as String;
    expect(StateSealer.isSealed(raw), isTrue);

    // Every chat from before cloud chats existed was end-to-end encrypted.
    expect((await MessageDao(db.db).chatById('c1'))!.mode, ChatMode.secret);
    await db.close();
  });

  test('sender keys are sealed too', () async {
    final db = await AppDatabase.open(path: path);
    final keys = SenderKeyDao(db.db, sealer: sealer);
    final state = await createSenderKey(chatId: 'g', epoch: 2, senderDeviceId: 'me');
    await keys.save(state, isOwn: true);

    final raw = (await db.db.query('sender_keys')).single['state'] as String;
    expect(StateSealer.isSealed(raw), isTrue);
    expect(raw, isNot(contains('chain_key')));
    final loaded = await keys.loadOwn(chatId: 'g', epoch: 2);
    expect(loaded!.chainKey, state.chainKey);
    await db.close();
  });

  // Saving a chat again -- every sync does -- must not take its messages
  // with it.
  test('updating a chat keeps its history', () async {
    final db = await AppDatabase.open(path: path);
    final dao = MessageDao(db.db);
    const chat = Chat(id: 'c', type: 'group', epoch: 0, mode: ChatMode.cloud);
    await dao.upsertChat(chat);
    await dao.upsertMessage(Message(
      id: 'm',
      chatId: 'c',
      senderId: 'u',
      senderDeviceId: 'd',
      body: 'hi',
      sentAt: DateTime(2026),
      isOutgoing: false,
    ));
    await dao.upsertChat(chat.copyWith(epoch: 1, title: 'renamed'));

    expect(await dao.messageById('m'), isNotNull);
    expect((await dao.chatById('c'))!.title, 'renamed');
    await db.close();
  });
}
