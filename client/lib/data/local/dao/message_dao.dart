/// Reads and writes local chats and messages.
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../models/models.dart';

class MessageDao {
  const MessageDao(this._db);

  final Database _db;

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

  /// Loads a chat's history, oldest first.
  ///
  /// Ordering puts acknowledged messages in server sequence, then anything
  /// still awaiting an ack at the end by local time -- which is where an
  /// optimistically rendered outgoing message belongs.
  Future<List<Message>> messagesForChat(String chatId, {int limit = 200}) async {
    final rows = await _db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'COALESCE(seq, 9223372036854775807) ASC, sent_at ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  Future<Message?> messageById(String id) async {
    final rows = await _db.query('messages', where: 'id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  Future<void> updateStatus(String id, MessageStatus status, {int? seq}) async {
    await _db.update(
      'messages',
      {
        'status': status.name,
        'seq': ?seq,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
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

  Future<void> upsertChat(Chat chat) async {
    await _db.insert(
      'chats',
      {
        'id': chat.id,
        'type': chat.type,
        'epoch': chat.epoch,
        'title': chat.title,
        'peer_username': chat.peerUsername,
        'last_message_preview': chat.lastMessagePreview,
        'last_message_at': chat.lastMessageAt?.millisecondsSinceEpoch,
        'unread_count': chat.unreadCount,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Chats for the list screen, most recently active first.
  Future<List<Chat>> chats() async {
    final rows = await _db.query(
      'chats',
      orderBy: 'COALESCE(last_message_at, 0) DESC',
    );
    return rows
        .map((r) => Chat(
              id: r['id'] as String,
              type: r['type'] as String,
              epoch: r['epoch'] as int,
              title: r['title'] as String?,
              peerUsername: r['peer_username'] as String?,
              lastMessagePreview: r['last_message_preview'] as String?,
              lastMessageAt: r['last_message_at'] == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      r['last_message_at'] as int),
              unreadCount: r['unread_count'] as int,
            ))
        .toList();
  }

  Future<Chat?> chatById(String id) async {
    final rows = await _db.query('chats', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    final all = await chats();
    return all.where((c) => c.id == id).firstOrNull;
  }

  /// Updates the preview shown in the chat list.
  Future<void> touchChat(String chatId, String preview, DateTime at,
      {bool incrementUnread = false}) async {
    await _db.rawUpdate(
      'UPDATE chats SET last_message_preview = ?, last_message_at = ?, '
      'unread_count = unread_count + ? WHERE id = ?',
      [preview, at.millisecondsSinceEpoch, incrementUnread ? 1 : 0, chatId],
    );
  }

  Future<void> clearUnread(String chatId) async {
    await _db.update('chats', {'unread_count': 0},
        where: 'id = ?', whereArgs: [chatId]);
  }

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
        'attachment':
            m.attachment == null ? null : jsonEncode(m.attachment!.toJson()),
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
                jsonDecode(r['attachment'] as String) as Map<String, dynamic>),
      );

  String _encodeReactions(Map<String, Set<String>> reactions) => jsonEncode(
        reactions.map((emoji, users) => MapEntry(emoji, users.toList())),
      );

  Map<String, Set<String>> _decodeReactions(String raw) {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return decoded.map(
      (emoji, users) => MapEntry(
        emoji,
        (users as List<dynamic>).cast<String>().toSet(),
      ),
    );
  }
}
