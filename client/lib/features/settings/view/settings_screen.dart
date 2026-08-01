/// Settings: account, active sessions, and sign-out.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.account,
    required this.sessions,
    required this.onRevokeSession,
    required this.onSignOut,
    this.onChangePassword,
  });

  final Account account;
  final List<DeviceSession> sessions;
  final void Function(DeviceSession session) onRevokeSession;
  final VoidCallback onSignOut;
  final VoidCallback? onChangePassword;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Text(
                account.username.isEmpty
                    ? '?'
                    : account.username.substring(0, 1).toUpperCase(),
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            title: Text(account.username),
            subtitle: const Text('Signed in'),
          ),
          const Divider(),
          _SectionHeader(title: 'Security'),
          if (onChangePassword != null)
            ListTile(
              leading: const Icon(Icons.password_outlined),
              title: const Text('Change password'),
              subtitle: const Text('Signs out every other device'),
              onTap: onChangePassword,
            ),
          _SectionHeader(title: 'Active sessions'),
          if (sessions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('No other sessions'),
            )
          else
            for (final session in sessions)
              _SessionTile(
                session: session,
                onRevoke: () => _confirmRevoke(context, session),
              ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: scheme.error),
            title: Text('Sign out', style: TextStyle(color: scheme.error)),
            subtitle: const Text('Erases keys and messages on this device'),
            onTap: () => _confirmSignOut(context),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _confirmRevoke(BuildContext context, DeviceSession session) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out this device?'),
        content: Text(
          'The device "${session.userAgent}" will be signed out immediately.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onRevokeSession(session);
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }

  /// Signing out destroys local keys, and with them the ability to read any
  /// history stored on this device. The user must be told before, not after.
  void _confirmSignOut(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your encryption keys and all messages stored on this device will be '
          'erased. Messages you have already sent stay with their recipients, '
          'but this device will not be able to read its own history again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onSignOut();
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.session, required this.onRevoke});

  final DeviceSession session;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        session.isCurrent ? Icons.smartphone : Icons.devices_other,
      ),
      title: Text(
        session.userAgent.isEmpty ? 'Unknown device' : session.userAgent,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        session.isCurrent
            ? 'This device'
            : 'Last used ${_formatDate(session.lastUsedAt)}',
      ),
      trailing: session.isCurrent
          ? null
          : IconButton(
              tooltip: 'Sign out',
              onPressed: onRevoke,
              icon: const Icon(Icons.close),
            ),
    );
  }

  static String _formatDate(DateTime time) {
    final local = time.toLocal();
    return '${local.day}/${local.month}/${local.year}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }
}
