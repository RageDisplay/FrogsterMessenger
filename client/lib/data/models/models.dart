/// Domain models shared by the local store, the network layer and the UI.
///
/// These carry plaintext: they exist only after decryption, on the device that
/// owns the keys. Nothing here is ever sent to the server as-is.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Delivery state of an outgoing message, shown as ticks in the UI.
enum MessageStatus { pending, sent, delivered, read, failed }

/// How a chat is protected.
///
/// A secret chat is end-to-end encrypted: only its members' devices can read
/// it, and its history exists nowhere else. A cloud chat is protected in
/// transit by TLS and on the server by its storage key; the server can read
/// it, which is what lets its history follow the user to a new device.
enum ChatMode {
  cloud,
  secret;

  static ChatMode parse(String? value) =>
      value == 'cloud' ? ChatMode.cloud : ChatMode.secret;
}

/// Someone in a chat.
class ChatMember {
  const ChatMember({
    required this.userId,
    required this.username,
    this.displayName = '',
    this.role = 'member',
  });

  final String userId;
  final String username;
  final String displayName;
  final String role;

  bool get isAdmin => role == 'admin';

  /// What the UI calls this person.
  String get name => displayName.isNotEmpty ? displayName : username;

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'username': username,
        if (displayName.isNotEmpty) 'display_name': displayName,
        'role': role,
      };

  static ChatMember fromJson(Map<String, dynamic> json) => ChatMember(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String? ?? '',
        role: json['role'] as String? ?? 'member',
      );
}

/// A chat, direct or group, cloud or secret.
class Chat {
  const Chat({
    required this.id,
    required this.type,
    required this.epoch,
    this.mode = ChatMode.secret,
    this.title,
    this.peerUsername,
    this.peerDisplayName,
    this.lastMessagePreview,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.members = const [],
    this.role = 'member',
    this.peerReadSeq = 0,
    this.syncedSeq = 0,
    this.draft = '',
    this.pinned = false,
    this.muted = false,
    this.archived = false,
    this.hidden = false,
  });

  final String id;
  final String type; // 'direct' | 'group'
  final int epoch;
  final ChatMode mode;

  /// Group title. A cloud group's comes from the server; a secret group's
  /// arrives end to end, from its members. Direct chats show the peer.
  final String? title;
  final String? peerUsername;
  final String? peerDisplayName;

  final String? lastMessagePreview;
  final DateTime? lastMessageAt;
  final int unreadCount;

  /// Current members, the signed-in user included.
  final List<ChatMember> members;

  /// The signed-in user's role.
  final String role;

  /// The furthest any other member has read: our messages up to here show
  /// as read.
  final int peerReadSeq;

  /// For cloud chats, the newest seq this device has caught up to. Secret
  /// chats are delivered by the queue and do not use it.
  final int syncedSeq;

  // What follows is this device's own arrangement of the list; the server
  // never hears about it.

  /// Text typed but not sent.
  final String draft;
  final bool pinned;

  /// No badge colour and, later, no notifications.
  final bool muted;

  /// Kept out of the main list until opened from the archive.
  final bool archived;

  /// Deleted from the list; comes back when a new message arrives.
  final bool hidden;

  bool get isGroup => type == 'group';
  bool get isSecret => mode == ChatMode.secret;
  bool get isCloud => mode == ChatMode.cloud;
  bool get isAdmin => role == 'admin';

  /// What the chat list shows as the chat's name.
  String get displayName {
    if (isGroup) return title ?? 'Group';
    final name = peerDisplayName;
    if (name != null && name.isNotEmpty) return name;
    return peerUsername ?? id;
  }

  /// The member behind a user id, if known.
  ChatMember? member(String userId) =>
      members.where((m) => m.userId == userId).firstOrNull;

  Chat copyWith({
    String? title,
    String? peerUsername,
    String? peerDisplayName,
    String? lastMessagePreview,
    DateTime? lastMessageAt,
    int? unreadCount,
    int? epoch,
    ChatMode? mode,
    List<ChatMember>? members,
    String? role,
    int? peerReadSeq,
    int? syncedSeq,
    String? draft,
    bool? pinned,
    bool? muted,
    bool? archived,
    bool? hidden,
  }) =>
      Chat(
        id: id,
        type: type,
        epoch: epoch ?? this.epoch,
        mode: mode ?? this.mode,
        title: title ?? this.title,
        peerUsername: peerUsername ?? this.peerUsername,
        peerDisplayName: peerDisplayName ?? this.peerDisplayName,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        unreadCount: unreadCount ?? this.unreadCount,
        members: members ?? this.members,
        role: role ?? this.role,
        peerReadSeq: peerReadSeq ?? this.peerReadSeq,
        syncedSeq: syncedSeq ?? this.syncedSeq,
        draft: draft ?? this.draft,
        pinned: pinned ?? this.pinned,
        muted: muted ?? this.muted,
        archived: archived ?? this.archived,
        hidden: hidden ?? this.hidden,
      );
}

/// A decrypted message as stored locally and rendered in the UI.
class Message {
  const Message({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.senderDeviceId,
    required this.body,
    required this.sentAt,
    required this.isOutgoing,
    this.seq,
    this.status = MessageStatus.pending,
    this.replyToId,
    this.reactions = const {},
    this.attachment,
    this.editedAt,
    this.forwardedFrom,
  });

  final String id;
  final String chatId;
  final String senderId;
  final String senderDeviceId;

  /// Plaintext. Present only on this device, after decryption.
  final String body;

  final DateTime sentAt;
  final bool isOutgoing;

  /// Server-assigned per-chat sequence, null until acknowledged.
  final int? seq;

  final MessageStatus status;
  final String? replyToId;

  /// Emoji to the user ids that reacted with it.
  final Map<String, Set<String>> reactions;

  /// Present when the message carries a file.
  final AttachmentPayload? attachment;

  /// When the author last changed the text; null if never edited.
  final DateTime? editedAt;

  /// Who wrote the original of a forwarded message.
  final String? forwardedFrom;

  bool get hasAttachment => attachment != null;
  bool get isEdited => editedAt != null;

  Message copyWith({
    int? seq,
    MessageStatus? status,
    Map<String, Set<String>>? reactions,
    AttachmentPayload? attachment,
    String? body,
    DateTime? editedAt,
  }) =>
      Message(
        id: id,
        chatId: chatId,
        senderId: senderId,
        senderDeviceId: senderDeviceId,
        body: body ?? this.body,
        sentAt: sentAt,
        isOutgoing: isOutgoing,
        seq: seq ?? this.seq,
        status: status ?? this.status,
        replyToId: replyToId,
        reactions: reactions ?? this.reactions,
        attachment: attachment ?? this.attachment,
        editedAt: editedAt ?? this.editedAt,
        forwardedFrom: forwardedFrom,
      );
}

/// What a payload does.
///
/// Older clients sent no kind: an ordinary message, or a reaction when the
/// reaction field was set. Both still parse.
enum PayloadKind {
  message('msg'),
  reaction('react'),
  edit('edit'),
  delete('delete'),

  /// Group metadata sent end to end: a secret group's title.
  meta('meta');

  const PayloadKind(this.wire);
  final String wire;

  static PayloadKind parse(String? wire) =>
      values.where((k) => k.wire == wire).firstOrNull ?? PayloadKind.message;
}

/// The plaintext payload that travels inside the encrypted envelope.
///
/// Reactions and attachment keys live in here rather than in the envelope, so
/// the server cannot learn who reacted with what, or what a file contains.
class MessagePayload {
  const MessagePayload({
    this.body = '',
    this.replyToId,
    this.reaction,
    this.attachment,
    this.sentAt,
    PayloadKind? kind,
    this.targetId,
    this.title,
    this.forwardedFrom,
  }) : _kind = kind;

  /// Format version, so a later change can be told apart from this one.
  static const version = 2;

  final String body;
  final String? replyToId;
  final ReactionPayload? reaction;

  /// Everything needed to fetch and open an attachment: blob id, key, digest
  /// and the real MIME type.
  ///
  /// It lives in here rather than on the envelope because the key is the whole
  /// secret: on the envelope the server would be able to decrypt every file it
  /// stores.
  final AttachmentPayload? attachment;

  final DateTime? sentAt;

  final PayloadKind? _kind;

  /// The message an edit or deletion applies to.
  final String? targetId;

  /// A secret group's title, for [PayloadKind.meta].
  final String? title;

  /// The original author's name, when this is a forwarded copy.
  final String? forwardedFrom;

  PayloadKind get kind =>
      _kind ?? (reaction != null ? PayloadKind.reaction : PayloadKind.message);

  bool get isReaction => kind == PayloadKind.reaction && reaction != null;
  bool get hasAttachment => attachment != null;

  Map<String, dynamic> toJson() => {
        'v': version,
        if (kind != PayloadKind.message) 'kind': kind.wire,
        if (body.isNotEmpty) 'body': body,
        if (replyToId != null) 'reply_to': replyToId,
        if (reaction != null) 'reaction': reaction!.toJson(),
        if (attachment != null) 'attachment': attachment!.toJson(),
        if (targetId != null) 'target_id': targetId,
        if (title != null) 'title': title,
        if (forwardedFrom != null) 'fwd': forwardedFrom,
        'sent_at': (sentAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  static MessagePayload fromJson(Map<String, dynamic> json) => MessagePayload(
        kind: json['kind'] == null
            ? null
            : PayloadKind.parse(json['kind'] as String),
        body: json['body'] as String? ?? '',
        replyToId: json['reply_to'] as String?,
        reaction: json['reaction'] == null
            ? null
            : ReactionPayload.fromJson(
                json['reaction'] as Map<String, dynamic>),
        attachment: json['attachment'] == null
            ? null
            : AttachmentPayload.fromJson(
                json['attachment'] as Map<String, dynamic>),
        targetId: json['target_id'] as String?,
        title: json['title'] as String?,
        forwardedFrom: json['fwd'] as String?,
        sentAt: json['sent_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(json['sent_at'] as int),
      );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static MessagePayload decode(Uint8List bytes) =>
      fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}

/// An attachment reference, carried inside the encrypted payload.
///
/// Mirrors [AttachmentKey] from the crypto layer. Duplicated as a plain model
/// so the data layer does not force every consumer to depend on crypto types.
class AttachmentPayload {
  const AttachmentPayload({
    required this.blobId,
    required this.key,
    required this.digest,
    required this.size,
    required this.mimeType,
    this.fileName,
  });

  final String blobId;

  /// Base64 of the AES-256 key. Never leaves the encrypted payload.
  final String key;

  /// Base64 of the ciphertext's SHA-256.
  final String digest;

  final int size;

  /// The true MIME type. The upload declares only a generic hint.
  final String mimeType;

  final String? fileName;

  bool get isImage => mimeType.startsWith('image/');

  /// A human-readable size for the UI.
  String get displaySize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(0)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Map<String, dynamic> toJson() => {
        'blob_id': blobId,
        'key': key,
        'digest': digest,
        'size': size,
        'mime': mimeType,
        if (fileName != null) 'name': fileName,
      };

  static AttachmentPayload fromJson(Map<String, dynamic> json) =>
      AttachmentPayload(
        blobId: json['blob_id'] as String,
        key: json['key'] as String,
        digest: json['digest'] as String,
        size: json['size'] as int,
        mimeType: json['mime'] as String,
        fileName: json['name'] as String?,
      );
}

/// An emoji reaction, carried inside the encrypted payload.
class ReactionPayload {
  const ReactionPayload({
    required this.targetId,
    required this.emoji,
    this.remove = false,
  });

  final String targetId;
  final String emoji;
  final bool remove;

  Map<String, dynamic> toJson() => {
        'target_id': targetId,
        'emoji': emoji,
        if (remove) 'remove': true,
      };

  static ReactionPayload fromJson(Map<String, dynamic> json) => ReactionPayload(
        targetId: json['target_id'] as String,
        emoji: json['emoji'] as String,
        remove: json['remove'] as bool? ?? false,
      );
}

/// A device belonging to the signed-in user, shown on the sessions screen.
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.deviceId,
    required this.userAgent,
    required this.lastUsedAt,
    required this.isCurrent,
  });

  final String id;
  final String deviceId;
  final String userAgent;
  final DateTime lastUsedAt;
  final bool isCurrent;
}

/// Someone found by a user search.
class UserProfile {
  const UserProfile({
    required this.userId,
    required this.username,
    this.displayName = '',
    this.bio = '',
  });

  final String userId;
  final String username;
  final String displayName;
  final String bio;

  String get name => displayName.isNotEmpty ? displayName : username;

  static UserProfile fromJson(Map<String, dynamic> json) => UserProfile(
        userId: json['user_id'] as String,
        username: json['username'] as String,
        displayName: json['display_name'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
      );
}

/// The signed-in account.
class Account {
  const Account({
    required this.userId,
    required this.username,
    required this.deviceId,
  });

  final String userId;
  final String username;
  final String deviceId;
}
