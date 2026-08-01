/// The responsive shell around the chat list and the conversation.
///
/// On a wide window both panes are visible at once; on a narrow one the
/// conversation covers the list and back navigation returns to it. The choice
/// is made from available width, so resizing a desktop window switches layouts
/// without any platform check.
library;

import 'package:flutter/material.dart';

import 'breakpoints.dart';

class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
    super.key,
    required this.list,
    required this.detail,
    required this.hasSelection,
    required this.onClearSelection,
    this.listPaneWidth = 360,
    this.emptyDetail,
  });

  /// The chat list.
  final Widget list;

  /// The open conversation, if any.
  final Widget? detail;

  final bool hasSelection;
  final VoidCallback onClearSelection;
  final double listPaneWidth;

  /// Shown in the detail pane when nothing is selected. Two-pane only.
  final Widget? emptyDetail;

  @override
  Widget build(BuildContext context) {
    if (isTwoPane(context)) {
      return Scaffold(
        body: Row(
          children: [
            SizedBox(width: listPaneWidth, child: list),
            const VerticalDivider(width: 1),
            Expanded(
              child: hasSelection && detail != null
                  ? detail!
                  : (emptyDetail ?? const _NoConversationSelected()),
            ),
          ],
        ),
      );
    }

    // Narrow: PopScope intercepts the system back gesture so it closes the
    // conversation instead of leaving the app, matching what the visible
    // back arrow does.
    if (hasSelection && detail != null) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) onClearSelection();
        },
        child: detail!,
      );
    }

    return list;
  }
}

class _NoConversationSelected extends StatelessWidget {
  const _NoConversationSelected();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ColoredBox(
      color: scheme.surfaceContainerLowest,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chat_bubble_outline, size: 72, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              'Select a conversation',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}
