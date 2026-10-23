/// The local message store.
///
/// Messages are held here in plaintext so the app works offline and can render
/// history instantly. That is a deliberate trade-off: the device is the only
/// place plaintext may exist, and it is protected by the platform's
/// disk encryption and lock screen rather than by another layer of app-level
/// crypto whose key would have to live on the same device anyway.
///
/// Long-term keys never go in this database -- they live in the platform
/// keychain via SecureKeyStorage. Ratchet and sender-key state does, because
/// it is large and changes on every message, but sealed with a key from the
/// keychain (StateSealer), so a stolen database file alone yields no keys.
library;

import 'dart:io';

// sqflite_common_ffi re-exports the sqflite API, so one import covers both the
// mobile and the desktop backends.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens and migrates the local database.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int _schemaVersion = 6;

  /// Opens the database, initialising the desktop FFI backend when needed.
  ///
  /// sqflite ships a native implementation for Android and iOS only; on
  /// Windows, Linux and macOS it needs sqflite_common_ffi to be installed as
  /// the database factory first. Skipping this is the classic first-desktop-run
  /// failure.
  static Future<AppDatabase> open({String? path}) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = path ?? await _defaultDatabasePath();
    final database = await openDatabase(
      dbPath,
      version: _schemaVersion,
      onConfigure: (db) async {
        // Off by default in SQLite; without it the cascades below do nothing.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
    return AppDatabase._(database);
  }

  /// Opens an in-memory database for tests.
  static Future<AppDatabase> openInMemory() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final database = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _schemaVersion,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return AppDatabase._(database);
  }

  /// Where the database lives.
  ///
  /// On desktop sqflite_ffi defaults to `.dart_tool/` under the *working
  /// directory*, which moves depending on how the app was started -- so the
  /// same install can end up with several databases, and deleting "the"
  /// database does not necessarily remove the one in use. A fixed per-user
  /// location avoids that.
  static Future<String> _defaultDatabasePath() async =>
      '${(await dataDirectory()).path}/frogster.db';

  /// The app's private data directory, which holds the database.
  static Future<Directory> dataDirectory() async {
    if (Platform.isAndroid || Platform.isIOS) {
      return Directory(await getDatabasesPath());
    }

    final home = Platform.environment['APPDATA'] ??
        Platform.environment['XDG_DATA_HOME'] ??
        Platform.environment['HOME'] ??
        '.';

    final dir = Directory('$home/Frogster');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Where fetched attachments are kept, still encrypted.
  static Future<Directory> attachmentCacheDirectory() async =>
      Directory('${(await dataDirectory()).path}/blobs');

  /// Migrates an existing database forward.
  ///
  /// Dropping and recreating would be simpler but would erase the user's
  /// message history and, worse, their ratchet sessions -- after which every
  /// existing conversation would be undecryptable.
  static Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN attachment TEXT');
    }
    if (from < 3) {
      // Every chat from before cloud chats existed was end-to-end encrypted.
      for (final column in const [
        "mode TEXT NOT NULL DEFAULT 'secret'",
        'peer_display_name TEXT',
        "members TEXT NOT NULL DEFAULT '[]'",
        "role TEXT NOT NULL DEFAULT 'member'",
        'peer_read_seq INTEGER NOT NULL DEFAULT 0',
        'synced_seq INTEGER NOT NULL DEFAULT 0',
      ]) {
        await db.execute('ALTER TABLE chats ADD COLUMN $column');
      }
      await db.execute('ALTER TABLE messages ADD COLUMN edited_at INTEGER');
      await _createV3Tables(db);
    }
    if (from < 4) await _addV4Columns(db);
    if (from < 5) await _addSearchColumn(db, backfill: true);
    if (from < 6) await _addV6Columns(db);
  }

  /// A group's avatar version and whether it hides its past from newcomers.
  static Future<void> _addV6Columns(Database db) async {
    await db.execute('ALTER TABLE chats ADD COLUMN avatar_version INTEGER NOT NULL DEFAULT 0');
    await db.execute('ALTER TABLE chats ADD COLUMN hide_history INTEGER NOT NULL DEFAULT 0');
  }

  /// Message text folded to lower case for search.
  ///
  /// SQLite's LIKE and lower() fold ASCII only, so "Привет" would never be
  /// found by "привет". Dart folds every script; the folded copy is kept
  /// next to the text and searched instead.
  static Future<void> _addSearchColumn(Database db, {required bool backfill}) async {
    await db.execute("ALTER TABLE messages ADD COLUMN search_text TEXT NOT NULL DEFAULT ''");
    if (!backfill) return;
    final rows = await db.query('messages', columns: ['id', 'body']);
    final batch = db.batch();
    for (final r in rows) {
      batch.update(
        'messages',
        {'search_text': (r['body'] as String).toLowerCase()},
        where: 'id = ?',
        whereArgs: [r['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  /// This device's own arrangement of the chat list, and forwarded copies.
  static Future<void> _addV4Columns(Database db) async {
    for (final column in const [
      "draft TEXT NOT NULL DEFAULT ''",
      'pinned INTEGER NOT NULL DEFAULT 0',
      'muted INTEGER NOT NULL DEFAULT 0',
      'archived INTEGER NOT NULL DEFAULT 0',
      'hidden INTEGER NOT NULL DEFAULT 0',
    ]) {
      await db.execute('ALTER TABLE chats ADD COLUMN $column');
    }
    await db.execute('ALTER TABLE messages ADD COLUMN forwarded_from TEXT');
  }

  /// Tables added in version 3, shared by fresh installs and upgrades.
  static Future<void> _createV3Tables(Database db) async {
    // Frames waiting for the server's acknowledgement. Persisted so a send
    // survives the app being closed before the network came back: the frame
    // is replayed on the next connection, and the server deduplicates it by
    // id if it did arrive after all. Holds ciphertext for secret chats; for
    // cloud chats the same plaintext the messages table already holds.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        id         TEXT PRIMARY KEY,
        chat_id    TEXT NOT NULL,
        frame      TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');

    // Which devices have our sender key for a secret group's epoch, so a key
    // goes to each device once, and to a newly added device as soon as it
    // appears.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sender_key_shares (
        chat_id   TEXT NOT NULL,
        epoch     INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        PRIMARY KEY (chat_id, epoch, device_id)
      )
    ''');
  }

  static Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      CREATE TABLE chats (
        id                  TEXT PRIMARY KEY,
        type                TEXT NOT NULL,
        epoch               INTEGER NOT NULL DEFAULT 0,
        title               TEXT,
        peer_username       TEXT,
        last_message_preview TEXT,
        last_message_at     INTEGER,
        unread_count        INTEGER NOT NULL DEFAULT 0,
        mode                TEXT NOT NULL DEFAULT 'secret',
        peer_display_name   TEXT,
        members             TEXT NOT NULL DEFAULT '[]',
        role                TEXT NOT NULL DEFAULT 'member',
        peer_read_seq       INTEGER NOT NULL DEFAULT 0,
        synced_seq          INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id               TEXT PRIMARY KEY,
        chat_id          TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
        sender_id        TEXT NOT NULL,
        sender_device_id TEXT NOT NULL,
        body             TEXT NOT NULL,
        sent_at          INTEGER NOT NULL,
        is_outgoing      INTEGER NOT NULL,
        seq              INTEGER,
        status           TEXT NOT NULL,
        reply_to_id      TEXT,
        reactions        TEXT NOT NULL DEFAULT '{}',
        attachment       TEXT,
        edited_at        INTEGER
      )
    ''');

    // History is read newest-first per chat; seq orders within a chat and
    // sent_at covers messages not yet acknowledged.
    await db.execute(
      'CREATE INDEX idx_messages_chat ON messages(chat_id, seq, sent_at)',
    );

    // Peer identity keys pinned on first use. Stored here rather than in the
    // keychain because these are public keys: losing them costs a re-pin
    // prompt, not confidentiality.
    await db.execute('''
      CREATE TABLE pinned_identities (
        peer_key        TEXT PRIMARY KEY,
        user_id         TEXT NOT NULL,
        device_id       TEXT NOT NULL,
        identity_key    TEXT NOT NULL,
        pinned_at       INTEGER NOT NULL,
        accepted_change INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Serialized Double Ratchet state, one row per peer device.
    await db.execute('''
      CREATE TABLE ratchet_sessions (
        peer_key TEXT PRIMARY KEY,
        state    TEXT NOT NULL
      )
    ''');

    // Sender keys for group chats, scoped to a chat epoch so a rotation
    // cannot silently reuse an old one.
    await db.execute('''
      CREATE TABLE sender_keys (
        chat_id   TEXT NOT NULL,
        epoch     INTEGER NOT NULL,
        device_id TEXT NOT NULL,
        state     TEXT NOT NULL,
        is_own    INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (chat_id, epoch, device_id)
      )
    ''');

    await _createV3Tables(db);
    await _addV4Columns(db);
    await _addSearchColumn(db, backfill: false);
    await _addV6Columns(db);
  }

  Future<void> close() => db.close();

  /// Deletes everything. Used on logout: leaving decrypted history behind
  /// after the keys are wiped would be the worst of both worlds.
  Future<void> wipe() async {
    await db.delete('messages');
    await db.delete('chats');
    await db.delete('pinned_identities');
    await db.delete('ratchet_sessions');
    await db.delete('sender_keys');
    await db.delete('sender_key_shares');
    await db.delete('outbox');
  }
}
