/// System notifications for new messages: toasts on Windows, the
/// notification shade on Android.
///
/// These are local: the app shows them itself while it runs, in the
/// foreground, in the background, or -- on Windows -- tucked away in the
/// tray. Nothing about them passes through any third party.
library;

import 'dart:async';
import 'dart:io';

import 'dart:ui' show Color;

import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    hide Message;

import '../models/models.dart';

/// The words a notification uses, in the user's language. Passed in rather
/// than looked up here, because this layer has no BuildContext.
class NotificationTexts {
  const NotificationTexts({
    required this.newMessage,
    required this.photo,
    required this.file,
    required this.voice,
    required this.appName,
  });

  final String newMessage;
  final String photo;
  final String file;
  final String voice;
  final String appName;
}

/// Whether a message deserves a notification.
///
/// Not for our own messages (from another of our devices), not for a muted
/// chat, and not for the chat the user is looking at right now.
bool shouldNotify({
  required Message message,
  required Chat? chat,
  required bool enabled,
  required bool appInFront,
  required String? openChatId,
}) {
  if (!enabled || message.isOutgoing) return false;
  if (chat == null || chat.muted) return false;
  if (appInFront && openChatId == message.chatId) return false;
  return true;
}

/// What the notification says. With previews off, only that something
/// arrived: no name, no words, in case someone else looks at the screen.
({String title, String body}) notificationContent({
  required Message message,
  required Chat chat,
  required bool showPreview,
  required NotificationTexts texts,
}) {
  if (!showPreview) return (title: texts.appName, body: texts.newMessage);

  final sender = chat.member(message.senderId)?.name;
  final title = chat.isGroup && sender != null
      ? '$sender · ${chat.displayName}'
      : chat.displayName;
  final attachment = message.attachment;
  final body = message.body.isNotEmpty
      ? message.body
      : attachment == null
          ? texts.newMessage
          : attachment.voice
              ? texts.voice
              : attachment.isImage
                  ? texts.photo
                  : (attachment.fileName ?? texts.file);
  return (title: title, body: body);
}

/// One notification per chat, replaced as more messages arrive.
int notificationIdFor(String chatId) {
  // FNV-1a: stable across runs, unlike String.hashCode.
  var hash = 0x811c9dc5;
  for (final unit in chatId.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash & 0x7fffffff;
}

class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  final _taps = StreamController<String>.broadcast();
  var _ready = false;

  /// Chat ids of notifications the user tapped.
  Stream<String> get taps => _taps.stream;

  static const _channel = AndroidNotificationChannel(
    'messages',
    'Messages',
    description: 'New messages',
    importance: Importance.high,
  );

  Future<void> initialize() async {
    if (_ready || !(Platform.isAndroid || Platform.isWindows)) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_frogster'),
          windows: WindowsInitializationSettings(
            appName: 'Frogster',
            appUserModelId: 'com.vectrixsecurity.frogster',
            // Identifies the app to Windows' notification system; fixed for
            // the app's lifetime.
            guid: '3f0b1c4e-7a52-4d0e-9a8b-6c1f2e5d9b47',
          ),
        ),
        onDidReceiveNotificationResponse: (response) {
          final chatId = response.payload;
          if (chatId != null && chatId.isNotEmpty) _taps.add(chatId);
        },
      );
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_channel);
      // Android 13+ asks once; refusing just means no notifications.
      await android?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      // A notification system that will not start must not take the
      // messenger down with it.
      // ignore: avoid_print
      print('[frogster] notifications unavailable: $e');
    }
  }

  Future<void> show({
    required String chatId,
    required String title,
    required String body,
  }) async {
    if (!_ready) return;
    try {
      await _plugin.show(
        id: notificationIdFor(chatId),
        title: title,
        body: body,
        payload: chatId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.id,
            _channel.name,
            channelDescription: _channel.description,
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            // The brand purple, which Android tints the small icon with.
            color: const Color(0xFF5B2BD1),
          ),
          windows: const WindowsNotificationDetails(),
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[frogster] could not show a notification: $e');
    }
  }

  /// Clears a chat's notification once the user has seen the chat.
  Future<void> clear(String chatId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(id: notificationIdFor(chatId));
    } catch (_) {}
  }

  Future<void> dispose() => _taps.close();
}
