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

  /// Called with true when the user chose to erase this device's identity.
  final void Function({required bool forget}) onSignOut;
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
            subtitle: const Text('Keeps your keys so you can sign back in'),
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
          '"${session.userAgent}" will be signed out immediately and retired: '
          'your contacts stop encrypting new messages to it. Use this for a '
          'phone you no longer have.',
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

  /// Offers the two very different kinds of sign-out.
  ///
  /// Erasing the keys is not just "sign out and clear data": contacts have
  /// pinned this device's identity key, so a device that comes back with a new
  /// one is a stranger to them and no existing conversation can continue. That
  /// consequence has to be stated before the fact, not discovered after.
  void _confirmSignOut(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Your messages and encryption keys stay on this device, so you can '
          'sign back in and carry on where you left off.\n\n'
          'Erasing everything also removes this device\'s identity. Your '
          'contacts will see it as a new device, and existing conversations '
          'cannot be continued.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onSignOut(forget: true);
            },
            child: const Text('Erase everything'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onSignOut(forget: false);
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
      leading: Icon(session.isCurrent ? Icons.smartphone : Icons.devices_other),
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
