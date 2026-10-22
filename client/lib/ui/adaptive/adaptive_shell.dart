/// The responsive shell around the chat list and the conversation.
///
/// On a wide window both panes are visible at once; on a narrow one the
/// conversation covers the list and back navigation returns to it. The choice
/// is made from available width, so resizing a desktop window switches layouts
/// without any platform check.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/pond_colors.dart';
import '../widgets/brand_mark.dart';
import 'breakpoints.dart';

class AdaptiveShell extends StatelessWidget {
  const AdaptiveShell({
    super.key,
    required this.list,
    required this.detail,
    required this.hasSelection,
    required this.onClearSelection,
    this.listPaneWidth = 380,
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
            // The conversation floats on its own pad beside the list rather
            // than being split off by a rule.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 10, 10, 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(PondRadii.sheet),
                  child: hasSelection && detail != null
                      ? detail!
                      : (emptyDetail ?? const _NoConversationSelected()),
                ),
              ),
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
    final pond = context.pond;

    return ColoredBox(
      color: pond.lily,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BrandMark(size: 56, color: pond.outline),
            const SizedBox(height: 20),
            Text(
              AppLocalizations.of(context).selectConversation,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: pond.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
