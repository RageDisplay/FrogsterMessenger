/// Settings: appearance, account security, sessions and sign-out.
library;

import 'package:flutter/material.dart';

import '../../../data/local/preferences.dart';
import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/lily_avatar.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.account,
    required this.server,
    required this.preferences,
    required this.sessions,
    required this.onRevokeSession,
    required this.onSignOut,
    this.onChangePassword,
  });

  final Account account;

  /// The server address, shown under the name.
  final String server;

  final AppPreferences preferences;
  final List<DeviceSession> sessions;
  final void Function(DeviceSession session) onRevokeSession;

  /// Called with true when the user chose to erase this device's identity.
  final void Function({required bool forget}) onSignOut;
  final VoidCallback? onChangePassword;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListenableBuilder(
        listenable: preferences,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            _Pad(
              child: Row(
                children: [
                  LilyAvatar(
                    seed: account.username,
                    label: account.username,
                    size: 60,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.username,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          l10n.signedInAs(server),
                          style: TextStyle(fontSize: 13, color: pond.inkMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _SectionTitle(l10n.appearance),
            _Pad(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: const Icon(Icons.brightness_auto_rounded),
                        label: Text(l10n.themeSystem),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: const Icon(Icons.light_mode_rounded),
                        label: Text(l10n.themeLight),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: const Icon(Icons.dark_mode_rounded),
                        label: Text(l10n.themeDark),
                      ),
                    ],
                    selected: {preferences.themeMode},
                    onSelectionChanged: (s) => preferences.setThemeMode(s.first),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.language,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: pond.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: '', label: Text(l10n.languageSystem)),
                      // Language names stay in their own language, so they
                      // can be found whatever the current one is.
                      const ButtonSegment(value: 'ru', label: Text('Русский')),
                      const ButtonSegment(value: 'en', label: Text('English')),
                    ],
                    selected: {preferences.locale?.languageCode ?? ''},
                    onSelectionChanged: (s) => preferences.setLocale(
                      s.first.isEmpty ? null : Locale(s.first),
                    ),
                  ),
                ],
              ),
            ),
            _SectionTitle(l10n.security),
            _Pad(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  if (onChangePassword != null)
                    ListTile(
                      leading: const Icon(Icons.password_rounded),
                      title: Text(l10n.changePassword),
                      subtitle: Text(l10n.changePasswordHint),
                      onTap: onChangePassword,
                    ),
                  ListTile(
                    title: Text(
                      l10n.activeSessions,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    dense: true,
                  ),
                  if (sessions.isEmpty)
                    ListTile(
                      leading: const Icon(Icons.devices_rounded),
                      title: Text(l10n.noOtherSessions),
                    )
                  else
                    for (final session in sessions)
                      _SessionTile(
                        session: session,
                        onRevoke: () => _confirmRevoke(context, session),
                      ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _Pad(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListTile(
                leading: Icon(Icons.logout_rounded, color: pond.danger),
                title: Text(
                  l10n.signOut,
                  style: TextStyle(
                    color: pond.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                subtitle: Text(l10n.signOutHint),
                onTap: () => _confirmSignOut(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmRevoke(BuildContext context, DeviceSession session) {
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.signOutDeviceTitle),
        content: Text(l10n.signOutDeviceBody(
          session.userAgent.isEmpty ? l10n.unknownDevice : session.userAgent,
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onRevokeSession(session);
            },
            child: Text(l10n.signOut),
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
    final l10n = AppLocalizations.of(context);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.signOutTitle),
        content: Text(l10n.signOutBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: context.pond.danger,
            ),
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onSignOut(forget: true);
            },
            child: Text(l10n.eraseEverything),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              onSignOut(forget: false);
            },
            child: Text(l10n.signOut),
          ),
        ],
      ),
    );
  }
}

/// A lily pad: the rounded card every settings group sits on.
class _Pad extends StatelessWidget {
  const _Pad({
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: context.pond.lily,
        borderRadius: BorderRadius.circular(PondRadii.card),
      ),
      child: child,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 22, 8, 10),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w700,
          color: context.pond.accent,
        ),
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
    final l10n = AppLocalizations.of(context);
    return ListTile(
      leading: Icon(
        session.isCurrent ? Icons.smartphone_rounded : Icons.devices_other_rounded,
      ),
      title: Text(
        session.userAgent.isEmpty ? l10n.unknownDevice : session.userAgent,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        session.isCurrent
            ? l10n.thisDevice
            : l10n.lastUsed(formatDate(context, session.lastUsedAt)),
      ),
      trailing: session.isCurrent
          ? null
          : IconButton(
              tooltip: l10n.signOut,
              onPressed: onRevoke,
              icon: const Icon(Icons.close_rounded),
            ),
    );
  }
}
