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
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Safety number')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Verify with $peerName',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Compare these numbers in person or over a call you trust. If they '
            'match, your conversation is end-to-end encrypted and nobody in '
            'between can read it.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: SelectableText(
                formatSafetyNumber(digits),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  // Monospace so digits line up in columns and are easy to
                  // read aloud without losing your place.
                  fontFamily: 'monospace',
                  fontSize: 18,
                  letterSpacing: 2,
                  height: 1.8,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: digits));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Safety number copied')),
                );
              }
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy'),
          ),
          if (onMarkVerified != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onMarkVerified,
              icon: const Icon(Icons.verified_outlined),
              label: const Text('Mark as verified'),
            ),
          ],
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 20, color: scheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'If this number changes later, your contact may have '
                    'reinstalled the app — or someone may be intercepting the '
                    'conversation. Frogster blocks sending until you check.',
                    style: Theme.of(context).textTheme.bodySmall,
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
