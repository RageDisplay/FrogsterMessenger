/// The local message store.
///
/// Messages are held here in plaintext so the app works offline and can render
/// history instantly. That is a deliberate trade-off: the device is the only
/// place plaintext may exist, and it is protected by the platform's
/// disk encryption and lock screen rather than by another layer of app-level
/// crypto whose key would have to live on the same device anyway.
///
/// Key material never goes in this database -- it lives in the platform
/// keychain via SecureKeyStorage, so a stolen database file alone cannot
/// decrypt anything new.
library;

import 'dart:io';

// sqflite_common_ffi re-exports the sqflite API, so one import covers both the
// mobile and the desktop backends.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens and migrates the local database.
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const int _schemaVersion = 2;

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

    final dbPath = path ?? '${await getDatabasesPath()}/frogster.db';
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

  /// Migrates an existing database forward.
  ///
  /// Dropping and recreating would be simpler but would erase the user's
  /// message history and, worse, their ratchet sessions -- after which every
  /// existing conversation would be undecryptable.
  static Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN attachment TEXT');
    }
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
        unread_count        INTEGER NOT NULL DEFAULT 0
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
        attachment       TEXT
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
  }
}
