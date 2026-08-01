/// Responsive layout breakpoints.
///
/// Follows the Material 3 window size classes. The layout is chosen by
/// available width, not by platform: a phone in landscape and a small desktop
/// window should behave the same way, and a tablet should not be forced into a
/// phone layout because of its operating system.
library;

import 'package:flutter/widgets.dart';

class Breakpoints {
  /// Below this, one pane at a time with a drawer for navigation.
  static const double compact = 600;

  /// At or above this, the chat list and the conversation sit side by side.
  static const double expanded = 840;
}

enum WindowSize { compact, medium, expanded }

WindowSize windowSizeOf(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (width >= Breakpoints.expanded) return WindowSize.expanded;
  if (width >= Breakpoints.compact) return WindowSize.medium;
  return WindowSize.compact;
}

/// True when there is room for a list pane and a detail pane together.
bool isTwoPane(BuildContext context) =>
    windowSizeOf(context) == WindowSize.expanded;
