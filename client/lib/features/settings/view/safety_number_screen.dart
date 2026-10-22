/// Displays a conversation's safety number for out-of-band verification.
///
/// The server never proves that a published key belongs to the person it
/// claims. Comparing these digits over a channel the server does not control
/// -- in person, by phone -- is what turns "the server says this is Bob" into
/// "this is Bob".
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../crypto/safety_number.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';

class SafetyNumberScreen extends StatelessWidget {
  const SafetyNumberScreen({
    super.key,
    required this.peerName,
    required this.digits,
    this.onMarkVerified,
  });

  final String peerName;

  /// The 60-digit number. Both sides see the same value.
  final String digits;

  final VoidCallback? onMarkVerified;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.safetyNumberTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Text(
            l10n.verifyWith(peerName),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.safetyExplain,
            style: TextStyle(color: pond.inkMuted, height: 1.4),
          ),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
            decoration: BoxDecoration(
              color: pond.night,
              borderRadius: BorderRadius.circular(PondRadii.card),
            ),
            child: SelectableText(
              formatSafetyNumber(digits),
              textAlign: TextAlign.center,
              style: TextStyle(
                // Monospace so digits line up in columns and are easy to
                // read aloud without losing your place.
                fontFamily: 'monospace',
                fontSize: 19,
                letterSpacing: 2,
                height: 1.8,
                color: pond.onNight,
              ),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: digits));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l10n.copied)),
                );
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: Text(l10n.copy),
          ),
          if (onMarkVerified != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onMarkVerified,
              icon: const Icon(Icons.verified_rounded),
              label: Text(l10n.markVerified),
            ),
          ],
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: pond.lily,
              borderRadius: BorderRadius.circular(PondRadii.card),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 20, color: pond.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.safetyChangeNote,
                    style: TextStyle(fontSize: 13, color: pond.inkMuted, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
