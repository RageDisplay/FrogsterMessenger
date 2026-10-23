/// Makes the voice channels available to every screen.
library;

import 'package:flutter/widgets.dart';

import '../../data/voice/voice_controller.dart';

class VoiceScope extends InheritedNotifier<VoiceController> {
  const VoiceScope({super.key, required VoiceController? controller, this.openChat, required super.child})
      : super(notifier: controller);

  /// Opens a chat by id: where the call bar takes the user.
  final void Function(String chatId)? openChat;

  /// The controller of the signed-in session, if there is one; rebuilds
  /// the caller on every change.
  static VoiceController? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VoiceScope>()?.notifier;

  static VoiceScope? scopeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<VoiceScope>();
}
