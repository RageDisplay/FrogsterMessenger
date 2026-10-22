/// Reads and writes local chats and messages.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/models.dart';

class MessageDao {
  const MessageDao(this._db);

  final Database _db;

  /// Sorts acknowledged messages by server sequence and anything still
  /// awaiting an ack after them, by local time -- which is where an
  /// optimistically rendered outgoing message belongs.
  static const _newestFirst =
      'COALESCE(seq, 9223372036854775807) DESC, sent_at DESC';

  /// Inserts or replaces a message.
  ///
  /// Replacing on conflict makes redelivery idempotent: the server may hand
  /// the same message to a device twice after a reconnect, and that must not
  /// produce a duplicate in the history.
  Future<void> upsertMessage(Message message) async {
    await _db.insert(
      'messages',
      _toRow(message),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Loads a page of a chat's history, oldest first: the [limit] newest
  /// messages, or the newest ones before seq [beforeSeq].
  Future<List<Message>> messagesForChat(
    String chatId, {
    int? beforeSeq,
    int limit = 50,
  }) async {
    final rows = await _db.query(
      'messages',
      where: beforeSeq == null ? 'chat_id = ?' : 'chat_id = ? AND seq < ?',
      whereArgs: [chatId, ?beforeSeq],
      orderBy: _newestFirst,
      limit: limit,
    );
    return rows.reversed.map(_fromRow).toList();
  }

  Future<Message?> messageById(String id) async {
    final rows = await _db.query('messages', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// The newest seq stored for a chat, 0 when it has none.
  Future<int> maxSeq(String chatId) async {
    final rows = await _db.rawQuery(
      'SELECT MAX(seq) AS seq FROM messages WHERE chat_id = ?',
      [chatId],
    );
    return (rows.first['seq'] as int?) ?? 0;
  }

  Future<void> updateStatus(String id, MessageStatus status, {int? seq}) async {
    await _db.update(
      'messages',
      {'status': status.name, 'seq': ?seq},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Turns our messages up to [seq] read. Never touches a failed or
  /// unacknowledged one: those have not reached anybody.
  Future<int> markOutgoingRead(String chatId, int seq) => _db.rawUpdate(
    "UPDATE messages SET status = 'read' "
    'WHERE chat_id = ? AND is_outgoing = 1 AND seq IS NOT NULL AND seq <= ? '
    "AND status IN ('sent', 'delivered')",
    [chatId, seq],
  );

  /// Replaces a message's text after its author edited it.
  Future<void> editMessage(String id, String body, DateTime editedAt) async {
    await _db.update(
      'messages',
      {'body': body, 'edited_at': editedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Removes a message deleted for everyone. The row goes, not just a flag:
  /// a deletion that left the plaintext on disk would not be one.
  Future<void> deleteMessage(String id) async {
    await _db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  /// Applies a reaction, which lives inside the encrypted payload rather than
  /// on the envelope so the server never learns who reacted with what.
  Future<void> applyReaction({
    required String targetId,
    required String emoji,
    required String userId,
    required bool remove,
  }) async {
    final message = await messageById(targetId);
    if (message == null) return;

    final reactions = {
      for (final entry in message.reactions.entries)
        entry.key: Set<String>.from(entry.value),
    };

    if (remove) {
      reactions[emoji]?.remove(userId);
      if (reactions[emoji]?.isEmpty ?? false) reactions.remove(emoji);
    } else {
      reactions.putIfAbsent(emoji, () => <String>{}).add(userId);
    }

    await _db.update(
      'messages',
      {'reactions': _encodeReactions(reactions)},
      where: 'id = ?',
      whereArgs: [targetId],
    );
  }

  /// Inserts a chat or updates the one already there.
  ///
  /// Never INSERT OR REPLACE: SQLite carries out a replace by deleting the
  /// old row first, and the cascade on messages.chat_id would take the whole
  /// history with it -- on every sync.
  Future<void> upsertChat(Chat chat) async {
    final row = <String, Object?>{
      'id': chat.id,
      'type': chat.type,
      'epoch': chat.epoch,
      'mode': chat.mode.name,
      'title': chat.title,
      'peer_username': chat.peerUsername,
      'peer_display_name': chat.peerDisplayName,
      'last_message_preview': chat.lastMessagePreview,
      'last_message_at': chat.lastMessageAt?.millisecondsSinceEpoch,
      'unread_count': chat.unreadCount,
      'members': jsonEncode(chat.members.map((m) => m.toJson()).toList()),
      'role': chat.role,
      'peer_read_seq': chat.peerReadSeq,
      'synced_seq': chat.syncedSeq,
    };
    final updated = await _db.update(
      'chats',
      row,
      where: 'id = ?',
      whereArgs: [chat.id],
    );
    if (updated == 0) {
      await _db.insert(
        'chats',
        row,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
  }

  /// Chats for the list screen, most recently active first.
  Future<List<Chat>> chats() async {
    final rows = await _db.query(
      'chats',
      orderBy: 'COALESCE(last_message_at, 0) DESC',
    );
    return rows.map(_chatFromRow).toList();
  }

  Future<Chat?> chatById(String id) async {
    final rows = await _db.query('chats', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _chatFromRow(rows.first);
  }

  /// Removes a chat and its history, for a group the user left or was
  /// removed from.
  Future<void> deleteChat(String id) async {
    await _db.delete('chats', where: 'id = ?', whereArgs: [id]);
  }

  /// Updates the preview shown in the chat list.
  Future<void> touchChat(
    String chatId,
    String preview,
    DateTime at, {
    bool incrementUnread = false,
  }) async {
    await _db.rawUpdate(
      'UPDATE chats SET last_message_preview = ?, last_message_at = ?, '
      'unread_count = unread_count + ? WHERE id = ?',
      [preview, at.millisecondsSinceEpoch, incrementUnread ? 1 : 0, chatId],
    );
  }

  /// Recomputes the preview from the newest stored message, after the one
  /// it showed was edited or deleted.
  Future<void> refreshPreview(
    String chatId,
    String Function(Message) preview,
  ) async {
    final latest = await messagesForChat(chatId, limit: 1);
    await _db.update(
      'chats',
      {'last_message_preview': latest.isEmpty ? '' : preview(latest.first)},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> clearUnread(String chatId) => setUnread(chatId, 0);

  Future<void> setUnread(String chatId, int count) async {
    await _db.update(
      'chats',
      {'unread_count': count},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  /// Moves the furthest-read position of the other members forward.
  Future<void> raisePeerReadSeq(String chatId, int seq) => _db.rawUpdate(
    'UPDATE chats SET peer_read_seq = MAX(peer_read_seq, ?) WHERE id = ?',
    [seq, chatId],
  );

  Future<void> setSyncedSeq(String chatId, int seq) async {
    await _db.update(
      'chats',
      {'synced_seq': seq},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Future<void> setTitle(String chatId, String title) async {
    await _db.update(
      'chats',
      {'title': title},
      where: 'id = ?',
      whereArgs: [chatId],
    );
  }

  Chat _chatFromRow(Map<String, Object?> r) => Chat(
    id: r['id'] as String,
    type: r['type'] as String,
    epoch: r['epoch'] as int,
    mode: ChatMode.parse(r['mode'] as String?),
    title: r['title'] as String?,
    peerUsername: r['peer_username'] as String?,
    peerDisplayName: r['peer_display_name'] as String?,
    lastMessagePreview: r['last_message_preview'] as String?,
    lastMessageAt: r['last_message_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['last_message_at'] as int),
    unreadCount: r['unread_count'] as int,
    members: (jsonDecode(r['members'] as String? ?? '[]') as List<dynamic>)
        .map((m) => ChatMember.fromJson(m as Map<String, dynamic>))
        .toList(),
    role: r['role'] as String? ?? 'member',
    peerReadSeq: r['peer_read_seq'] as int? ?? 0,
    syncedSeq: r['synced_seq'] as int? ?? 0,
  );

  Map<String, Object?> _toRow(Message m) => {
    'id': m.id,
    'chat_id': m.chatId,
    'sender_id': m.senderId,
    'sender_device_id': m.senderDeviceId,
    'body': m.body,
    'sent_at': m.sentAt.millisecondsSinceEpoch,
    'is_outgoing': m.isOutgoing ? 1 : 0,
    'seq': m.seq,
    'status': m.status.name,
    'reply_to_id': m.replyToId,
    'reactions': _encodeReactions(m.reactions),
    'attachment': m.attachment == null
        ? null
        : jsonEncode(m.attachment!.toJson()),
    'edited_at': m.editedAt?.millisecondsSinceEpoch,
  };

  Message _fromRow(Map<String, Object?> r) => Message(
    id: r['id'] as String,
    chatId: r['chat_id'] as String,
    senderId: r['sender_id'] as String,
    senderDeviceId: r['sender_device_id'] as String,
    body: r['body'] as String,
    sentAt: DateTime.fromMillisecondsSinceEpoch(r['sent_at'] as int),
    isOutgoing: (r['is_outgoing'] as int) == 1,
    seq: r['seq'] as int?,
    status: MessageStatus.values.byName(r['status'] as String),
    replyToId: r['reply_to_id'] as String?,
    reactions: _decodeReactions(r['reactions'] as String),
    attachment: r['attachment'] == null
        ? null
        : AttachmentPayload.fromJson(
            jsonDecode(r['attachment'] as String) as Map<String, dynamic>,
          ),
    editedAt: r['edited_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['edited_at'] as int),
  );

  String _encodeReactions(Map<String, Set<String>> reactions) => jsonEncode(
    reactions.map((emoji, users) => MapEntry(emoji, users.toList())),
  );

  Map<String, Set<String>> _decodeReactions(String raw) {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (emoji, users) =>
          MapEntry(emoji, (users as List<dynamic>).cast<String>().toSet()),
    );
  }
}

/// Frames that must reach the server, kept until it acknowledges them.
class OutboxDao {
  const OutboxDao(this._db);

  final Database _db;

  Future<void> add(String id, String chatId, Map<String, dynamic> frame) async {
    await _db.insert('outbox', {
      'id': id,
      'chat_id': chatId,
      'frame': jsonEncode(frame),
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> remove(String id) async {
    await _db.delete('outbox', where: 'id = ?', whereArgs: [id]);
  }

  /// Everything waiting, oldest first, so a replay keeps the original order.
  Future<List<({String id, String chatId, Map<String, dynamic> frame})>>
  pending() async {
    final rows = await _db.query(
      'outbox',
      orderBy: 'created_at ASC, rowid ASC',
    );
    return [
      for (final r in rows)
        (
          id: r['id'] as String,
          chatId: r['chat_id'] as String,
          frame: jsonDecode(r['frame'] as String) as Map<String, dynamic>,
        ),
    ];
  }
}
