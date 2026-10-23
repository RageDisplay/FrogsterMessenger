/// Voice channels of cloud groups, as the server describes them.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Someone in a voice channel.
class VoiceParticipant {
  const VoiceParticipant({
    required this.member,
    required this.userId,
    required this.deviceId,
    this.muted = false,
    this.deafened = false,
  });

  /// Their number in the relay: what their sound arrives under.
  final int member;
  final String userId;
  final String deviceId;
  final bool muted;
  final bool deafened;

  static VoiceParticipant fromJson(Map<String, dynamic> json) => VoiceParticipant(
        member: json['member'] as int,
        userId: json['user_id'] as String,
        deviceId: json['device_id'] as String,
        muted: json['muted'] as bool? ?? false,
        deafened: json['deafened'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is VoiceParticipant &&
      other.member == member &&
      other.userId == userId &&
      other.muted == muted &&
      other.deafened == deafened;

  @override
  int get hashCode => Object.hash(member, userId, muted, deafened);
}

/// A voice channel of a group.
class VoiceChannel {
  const VoiceChannel({required this.id, required this.name, this.position = 0, this.participants = const []});

  final String id;
  final String name;
  final int position;
  final List<VoiceParticipant> participants;

  VoiceChannel withParticipants(List<VoiceParticipant> people) =>
      VoiceChannel(id: id, name: name, position: position, participants: people);

  static VoiceChannel fromJson(Map<String, dynamic> json) => VoiceChannel(
        id: json['id'] as String,
        name: json['name'] as String,
        position: json['position'] as int? ?? 0,
        participants: [
          for (final p in (json['participants'] as List<dynamic>? ?? const []))
            VoiceParticipant.fromJson(p as Map<String, dynamic>),
        ],
      );
}

/// Who is in one channel right now, from a `voice` frame.
class VoiceRoom {
  const VoiceRoom({required this.channelId, required this.participants});

  final String channelId;
  final List<VoiceParticipant> participants;

  static VoiceRoom fromJson(Map<String, dynamic> json) => VoiceRoom(
        channelId: json['channel_id'] as String,
        participants: [
          for (final p in (json['participants'] as List<dynamic>? ?? const []))
            VoiceParticipant.fromJson(p as Map<String, dynamic>),
        ],
      );
}

/// What joining a channel hands this device: its number and keys, and
/// where to send sound.
class VoiceGrant {
  const VoiceGrant({
    required this.channelId,
    required this.member,
    required this.tag,
    required this.secret,
    required this.udpPort,
    required this.mediaPath,
  });

  final String channelId;
  final int member;
  final Uint8List tag;
  final Uint8List secret;

  /// 0 when the server offers no UDP.
  final int udpPort;
  final String mediaPath;

  static VoiceGrant fromJson(Map<String, dynamic> json) => VoiceGrant(
        channelId: json['channel_id'] as String,
        member: json['member'] as int,
        tag: base64Decode(json['tag'] as String),
        secret: base64Decode(json['secret'] as String),
        udpPort: json['udp_port'] as int? ?? 0,
        mediaPath: json['media_path'] as String? ?? '/v1/voice/media',
      );

  Map<String, dynamic> toJson() => {
        'channel_id': channelId,
        'member': member,
        'tag': base64Encode(tag),
        'secret': base64Encode(secret),
        'udp_port': udpPort,
        'media_path': mediaPath,
      };
}
