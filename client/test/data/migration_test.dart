import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/local/dao/message_dao.dart';
import 'package:frogster/data/local/dao/session_dao.dart';
import 'package:frogster/data/local/database.dart';
import 'package:frogster/data/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Recreates the v1 schema, as it existed before attachments were added.
Future<Database> openV1(String path) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE chats (
            id TEXT PRIMARY KEY, type TEXT NOT NULL,
            epoch INTEGER NOT NULL DEFAULT 0, title TEXT,
            peer_username TEXT, last_message_preview TEXT,
            last_message_at INTEGER, unread_count INTEGER NOT NULL DEFAULT 0)
        ''');
        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
            sender_id TEXT NOT NULL, sender_device_id TEXT NOT NULL,
            body TEXT NOT NULL, sent_at INTEGER NOT NULL,
            is_outgoing INTEGER NOT NULL, seq INTEGER,
            status TEXT NOT NULL, reply_to_id TEXT,
            reactions TEXT NOT NULL DEFAULT '{}')
        ''');
        await db.execute('''
          CREATE TABLE pinned_identities (
            peer_key TEXT PRIMARY KEY, user_id TEXT NOT NULL,
            device_id TEXT NOT NULL, identity_key TEXT NOT NULL,
            pinned_at INTEGER NOT NULL,
            accepted_change INTEGER NOT NULL DEFAULT 0)
        ''');
        await db.execute('''
          CREATE TABLE ratchet_sessions (
            peer_key TEXT PRIMARY KEY, state TEXT NOT NULL)
        ''');
        await db.execute('''
          CREATE TABLE sender_keys (
            chat_id TEXT NOT NULL, epoch INTEGER NOT NULL,
            device_id TEXT NOT NULL, state TEXT NOT NULL,
            is_own INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (chat_id, epoch, device_id))
        ''');
      },
    ),
  );
}

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('frogster_migration');
    dbPath = '${tempDir.path}/frogster.db';
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  // The upgrade must preserve ratchet state above all else. Dropping and
  // recreating the schema would be simpler, but every existing conversation
  // would become permanently undecryptable -- a silent, unrecoverable data
  // loss that no error message would explain to the user.
  test('v1 to v2 keeps messages, sessions and pinned identities', () async {
    final v1 = await openV1(dbPath);

    await v1.insert('chats', {
      'id': 'c1',
      'type': 'direct',
      'epoch': 0,
      'peer_username': 'bob',
      'unread_count': 2,
    });
    await v1.insert('messages', {
      'id': 'm1',
      'chat_id': 'c1',
      'sender_id': 'alice',
      'sender_device_id': 'dev-1',
      'body': 'message from before the upgrade',
      'sent_at': 1000,
      'is_outgoing': 0,
      'seq': 1,
      'status': 'delivered',
      'reactions': '{"👍":["bob"]}',
    });
    await v1.insert('ratchet_sessions', {
      'peer_key': 'bob:dev-1',
      'state': '{"rk":"root-key","ns":7}',
    });
    await v1.insert('pinned_identities', {
      'peer_key': 'bob:dev-1',
      'user_id': 'bob',
      'device_id': 'dev-1',
      'identity_key': 'aWRlbnRpdHk=',
      'pinned_at': 500,
      'accepted_change': 0,
    });
    await v1.close();

    // Reopening through AppDatabase runs the migration.
    final upgraded = await AppDatabase.open(path: dbPath);
    final messages = MessageDao(upgraded.db);
    final sessions = SqfliteSessionStore(upgraded.db);

    final message = await messages.messageById('m1');
    expect(message, isNotNull);
    expect(message!.body, 'message from before the upgrade');
    expect(message.reactions['👍'], contains('bob'));
    expect(message.attachment, isNull,
        reason: 'pre-existing messages have no attachment');

    final session = await sessions.loadSession('bob:dev-1');
    expect(session, isNotNull,
        reason: 'losing ratchet state would make every past conversation '
            'permanently undecryptable');
    expect(session!['rk'], 'root-key');
    expect(session['ns'], 7);

    final pinned = await sessions.loadPinnedIdentity('bob:dev-1');
    expect(pinned, isNotNull,
        reason: 'losing the pin would show a false key-change warning');
    expect(pinned!.userId, 'bob');

    final chats = await messages.chats();
    expect(chats.single.unreadCount, 2);

    await upgraded.close();
  });

  test('the upgraded schema accepts attachments', () async {
    final v1 = await openV1(dbPath);
    await v1.insert('chats', {'id': 'c1', 'type': 'direct', 'epoch': 0});
    await v1.close();

    final upgraded = await AppDatabase.open(path: dbPath);
    final messages = MessageDao(upgraded.db);

    await messages.upsertMessage(Message(
      id: 'm-new',
      chatId: 'c1',
      senderId: 'alice',
      senderDeviceId: 'dev-1',
      body: '',
      sentAt: DateTime.fromMillisecondsSinceEpoch(2000),
      isOutgoing: true,
      attachment: const AttachmentPayload(
        blobId: 'blob-1',
        key: 'a2V5',
        digest: 'ZGln',
        size: 1024,
        mimeType: 'image/png',
      ),
    ));

    final loaded = await messages.messageById('m-new');
    expect(loaded!.attachment!.blobId, 'blob-1');

    await upgraded.close();
  });

  test('migrating twice is a no-op', () async {
    final v1 = await openV1(dbPath);
    await v1.close();

    final first = await AppDatabase.open(path: dbPath);
    await first.close();

    // Reopening an already-migrated database must not fail on a duplicate
    // column.
    final second = await AppDatabase.open(path: dbPath);
    expect(second.db.isOpen, isTrue);
    await second.close();
  });
}
