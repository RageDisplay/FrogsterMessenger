/// The navigation bar at the bottom of the chat list.
library;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/pond_colors.dart';

class PondNavBar extends StatelessWidget {
  const PondNavBar({
    super.key,
    required this.onNewChat,
    required this.onOpenSettings,
  });

  final VoidCallback? onNewChat;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: pond.lily,
            borderRadius: BorderRadius.circular(PondRadii.card),
            border: Border.all(color: pond.outline),
          ),
          child: Row(
            children: [
              // The current section. Contacts join it in a later stage.
              Expanded(
                child: Container(
                  height: 42,
                  decoration: BoxDecoration(
                    color: pond.accentSoft,
                    borderRadius: BorderRadius.circular(PondRadii.control),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.chat_bubble_outline_rounded,
                          size: 18, color: pond.onAccentSoft),
                      const SizedBox(width: 8),
                      Text(
                        l10n.navChats,
                        style: TextStyle(
                          color: pond.onAccentSoft,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: l10n.navNewChat,
                onPressed: onNewChat,
                style: IconButton.styleFrom(
                  backgroundColor: pond.accent,
                  foregroundColor: pond.onAccent,
                  fixedSize: const Size(42, 42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PondRadii.control),
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 22),
              ),
              const SizedBox(width: 2),
              IconButton(
                tooltip: l10n.navSettings,
                onPressed: onOpenSettings,
                style: IconButton.styleFrom(
                  foregroundColor: pond.inkMuted,
                  fixedSize: const Size(42, 42),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PondRadii.control),
                  ),
                ),
                icon: const Icon(Icons.tune_rounded, size: 20),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
