/// Settings: appearance, account security, sessions and sign-out.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frogster_audio/frogster_audio.dart' show AudioDevice;

import '../../../data/audio/voice_player.dart';
import '../../../data/audio/voice_recording.dart';
import '../../../data/local/error_log.dart';
import '../../../data/local/preferences.dart';
import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/avatars.dart';

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
    this.loadProfile,
    this.onSaveProfile,
    this.onDeleteAccount,
    this.onChangeAvatar,
    this.onRemoveAvatar,
    this.onSetLastSeenVisible,
    this.soundSettings = true,
    this.voicePlayer,
    this.appVersion = '',
  });

  /// Off in tests, which have no microphones to list.
  final bool soundSettings;

  /// Plays back a microphone test.
  final VoicePlayer? voicePlayer;

  final Account account;

  /// The server address, shown under the name.
  final String server;

  final AppPreferences preferences;
  final List<DeviceSession> sessions;
  final void Function(DeviceSession session) onRevokeSession;

  /// Called with true when the user chose to erase this device's identity.
  final void Function({required bool forget}) onSignOut;

  /// Changes the password; throws when the current one is wrong.
  final Future<void> Function(String current, String next)? onChangePassword;

  final Future<UserProfile> Function()? loadProfile;
  final Future<UserProfile> Function(String displayName, String bio)? onSaveProfile;

  /// Closes the account for good; throws when the password is wrong.
  final Future<void> Function(String password)? onDeleteAccount;

  /// Picks and uploads a new picture; null when the user changed their mind.
  final Future<UserProfile?> Function()? onChangeAvatar;
  final Future<UserProfile> Function()? onRemoveAvatar;

  final Future<UserProfile> Function(bool visible)? onSetLastSeenVisible;

  final String appVersion;

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
            _ProfileCard(
              account: account,
              server: server,
              load: loadProfile,
              save: onSaveProfile,
              changeAvatar: onChangeAvatar,
              removeAvatar: onRemoveAvatar,
            ),
            if (onSetLastSeenVisible != null && loadProfile != null) ...[
              _SectionTitle(l10n.privacy),
              _PrivacySection(load: loadProfile!, setLastSeenVisible: onSetLastSeenVisible!),
            ],
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
            if (soundSettings) ...[
              _SectionTitle(l10n.sound),
              _SoundSection(preferences: preferences, player: voicePlayer),
            ],
            _SectionTitle(l10n.notifications),
            _Pad(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.notifications_outlined),
                    title: Text(l10n.notificationsShow),
                    value: preferences.notifications,
                    onChanged: preferences.setNotifications,
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.short_text_rounded),
                    title: Text(l10n.notificationsPreview),
                    subtitle: Text(l10n.notificationsPreviewHint),
                    value: preferences.notificationPreview,
                    onChanged: preferences.notifications
                        ? preferences.setNotificationPreview
                        : null,
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
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => _ChangePasswordDialog(onSubmit: onChangePassword!),
                      ),
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
            if (onDeleteAccount != null) ...[
              const SizedBox(height: 10),
              _Pad(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: ListTile(
                  leading: Icon(Icons.delete_forever_outlined, color: pond.danger),
                  title: Text(l10n.deleteAccount, style: TextStyle(color: pond.danger)),
                  subtitle: Text(l10n.deleteAccountHint),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (_) => _DeleteAccountDialog(onSubmit: onDeleteAccount!),
                  ),
                ),
              ),
            ],
            _SectionTitle(l10n.about),
            _Pad(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(l10n.appTitle),
                    subtitle: Text(l10n.appVersion(appVersion)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: Text(l10n.licenses),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: l10n.appTitle,
                      applicationVersion: appVersion,
                    ),
                  ),
                  if (ErrorLog.instance != null)
                    ListTile(
                      leading: const Icon(Icons.bug_report_outlined),
                      title: Text(l10n.errorLogCopy),
                      subtitle: Text(l10n.errorLogHint),
                      onTap: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        final text = await ErrorLog.instance!.read();
                        if (text.isNotEmpty) await Clipboard.setData(ClipboardData(text: text));
                        messenger.showSnackBar(SnackBar(
                          content: Text(text.isEmpty ? l10n.errorLogEmpty : l10n.errorLogCopied),
                        ));
                      },
                    ),
                ],
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
          session.label.isEmpty ? l10n.unknownDevice : session.label,
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

/// The account at the top: name, how contacts see it, and editing it.
class _ProfileCard extends StatefulWidget {
  const _ProfileCard({
    required this.account,
    required this.server,
    this.load,
    this.save,
    this.changeAvatar,
    this.removeAvatar,
  });

  final Account account;
  final String server;
  final Future<UserProfile> Function()? load;
  final Future<UserProfile> Function(String displayName, String bio)? save;
  final Future<UserProfile?> Function()? changeAvatar;
  final Future<UserProfile> Function()? removeAvatar;

  @override
  State<_ProfileCard> createState() => _ProfileCardState();
}

class _ProfileCardState extends State<_ProfileCard> {
  UserProfile? _profile;
  var _busy = false;

  Future<void> _avatarMenu() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(l10n.avatarChoose),
              onTap: () => Navigator.of(sheetContext).pop('set'),
            ),
            if ((_profile?.avatarVersion ?? 0) > 0 && widget.removeAvatar != null)
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: context.pond.danger),
                title: Text(l10n.avatarRemove, style: TextStyle(color: context.pond.danger)),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    setState(() => _busy = true);
    try {
      final updated = choice == 'set' ? await widget.changeAvatar!() : await widget.removeAvatar!();
      if (updated != null && mounted) setState(() => _profile = updated);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.actionFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.load?.call().then((p) {
      if (mounted) setState(() => _profile = p);
    }).catchError((Object _) {});
  }

  Future<void> _edit() async {
    final save = widget.save;
    if (save == null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _ProfileDialog(
        displayName: _profile?.displayName ?? '',
        bio: _profile?.bio ?? '',
      ),
    );
    if (result == null) return;
    final (displayName, about) = result;
    try {
      final saved = await save(displayName, about);
      if (mounted) setState(() => _profile = saved);
      messenger.showSnackBar(SnackBar(content: Text(l10n.profileSaved)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(l10n.actionFailed('$e'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final l10n = AppLocalizations.of(context);
    final profile = _profile;
    final shown = (profile?.displayName.isNotEmpty ?? false)
        ? profile!.displayName
        : widget.account.username;
    return _Pad(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: widget.changeAvatar == null || _busy ? null : _avatarMenu,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                UserAvatar(
                  userId: widget.account.userId,
                  username: widget.account.username,
                  name: shown,
                  avatarVersion: profile?.avatarVersion ?? 0,
                  size: 60,
                ),
                if (widget.changeAvatar != null)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: CircleAvatar(
                      radius: 12,
                      backgroundColor: pond.accent,
                      child: _busy
                          ? SizedBox.square(
                              dimension: 12,
                              child: CircularProgressIndicator(strokeWidth: 2, color: pond.onAccent),
                            )
                          : Icon(Icons.photo_camera_rounded, size: 13, color: pond.onAccent),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(shown, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                Text('@${widget.account.username}', style: TextStyle(color: pond.inkMuted)),
                if (profile != null && profile.bio.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(profile.bio, style: const TextStyle(fontSize: 14, height: 1.35)),
                ],
                const SizedBox(height: 4),
                Text(
                  l10n.signedInAs(widget.server),
                  style: TextStyle(fontSize: 12, color: pond.inkMuted),
                ),
              ],
            ),
          ),
          if (widget.save != null)
            IconButton(
              tooltip: l10n.editProfile,
              onPressed: _edit,
              icon: const Icon(Icons.edit_outlined),
            ),
        ],
      ),
    );
  }
}

/// Which microphone, and what is done to the sound.
class _SoundSection extends StatefulWidget {
  const _SoundSection({required this.preferences, this.player});

  final AppPreferences preferences;
  final VoicePlayer? player;

  @override
  State<_SoundSection> createState() => _SoundSectionState();
}

enum _TestStage { idle, recording, playing }

class _SoundSectionState extends State<_SoundSection> {
  List<AudioDevice>? _microphones;
  List<AudioDevice>? _speakers;
  var _test = _TestStage.idle;
  VoiceRecording? _recording;

  @override
  void initState() {
    super.initState();
    Future<List<AudioDevice>> list(Future<List<AudioDevice>> Function() f) =>
        f().catchError((Object _) => const <AudioDevice>[]);
    list(listMicrophones).then((d) {
      if (mounted) setState(() => _microphones = d);
    });
    list(listSpeakers).then((d) {
      if (mounted) setState(() => _speakers = d);
    });
  }

  /// A device picker: the system's default, or one of [devices].
  Widget _picker({
    required IconData icon,
    required String title,
    required String defaultLabel,
    required List<AudioDevice>? devices,
    required String? chosen,
    required void Function(String? id) onChanged,
  }) {
    final known = devices?.any((d) => d.id == chosen) ?? false;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: devices == null
          ? const LinearProgressIndicator(minHeight: 2)
          : DropdownButton<String?>(
              isExpanded: true,
              underline: const SizedBox.shrink(),
              value: known ? chosen : null,
              items: [
                DropdownMenuItem(value: null, child: Text(defaultLabel)),
                for (final d in devices)
                  DropdownMenuItem(value: d.id, child: Text(d.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: _test == _TestStage.idle ? onChanged : null,
            ),
    );
  }

  @override
  void dispose() {
    _recording?.cancel();
    super.dispose();
  }

  /// Three seconds through the same chain a message goes through, played
  /// straight back.
  Future<void> _runTest() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final recording = await VoiceRecording.start(widget.preferences);
      setState(() {
        _recording = recording;
        _test = _TestStage.recording;
      });
      await Future<void>.delayed(const Duration(seconds: 3));
      final clip = await recording.finish();
      recording.dispose();
      _recording = null;
      if (!mounted || clip == null) return;
      setState(() => _test = _TestStage.playing);
      final player = widget.player;
      if (player != null) {
        await player.toggle('mic-test-${DateTime.now().millisecondsSinceEpoch}', () async => clip.ogg);
        await Future<void>.delayed(clip.duration + const Duration(milliseconds: 300));
      }
    } on RecordingException catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text(e.problem == RecordingProblem.permission ? l10n.micPermission : l10n.micFailed),
      ));
    } finally {
      if (mounted) setState(() => _test = _TestStage.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final prefs = widget.preferences;
    return _Pad(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          _picker(
            icon: Icons.mic_none_rounded,
            title: l10n.microphone,
            defaultLabel: l10n.microphoneDefault,
            devices: _microphones,
            chosen: prefs.microphone,
            onChanged: prefs.setMicrophone,
          ),
          _picker(
            icon: Icons.headphones_rounded,
            title: l10n.speaker,
            defaultLabel: l10n.speakerDefault,
            devices: _speakers,
            chosen: prefs.speaker,
            onChanged: prefs.setSpeaker,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.noise_aware_rounded),
            title: Text(l10n.noiseSuppression),
            subtitle: Text(l10n.noiseSuppressionHint),
            value: prefs.noiseSuppression,
            onChanged: prefs.setNoiseSuppression,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.graphic_eq_rounded),
            title: Text(l10n.autoGain),
            subtitle: Text(l10n.autoGainHint),
            value: prefs.autoGain,
            onChanged: prefs.setAutoGain,
          ),
          ListTile(
            leading: const Icon(Icons.record_voice_over_outlined),
            title: Text(switch (_test) {
              _TestStage.idle => l10n.micTest,
              _TestStage.recording => l10n.micTestRecording,
              _TestStage.playing => l10n.micTestPlaying,
            }),
            subtitle: _test == _TestStage.recording && _recording != null
                ? ValueListenableBuilder<double>(
                    valueListenable: _recording!.level,
                    builder: (_, level, _) => LinearProgressIndicator(value: level, minHeight: 6),
                  )
                : Text(l10n.micTestHint),
            onTap: _test == _TestStage.idle ? _runTest : null,
          ),
        ],
      ),
    );
  }
}

/// Who sees what of the user.
class _PrivacySection extends StatefulWidget {
  const _PrivacySection({required this.load, required this.setLastSeenVisible});

  final Future<UserProfile> Function() load;
  final Future<UserProfile> Function(bool visible) setLastSeenVisible;

  @override
  State<_PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends State<_PrivacySection> {
  bool? _visible;
  var _busy = false;

  @override
  void initState() {
    super.initState();
    widget.load().then((p) {
      if (mounted) setState(() => _visible = p.lastSeenVisible ?? true);
    }).catchError((Object _) {});
  }

  Future<void> _set(bool visible) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _visible = visible;
    });
    try {
      final saved = await widget.setLastSeenVisible(visible);
      if (mounted) setState(() => _visible = saved.lastSeenVisible ?? visible);
    } catch (e) {
      if (mounted) setState(() => _visible = !visible);
      messenger.showSnackBar(SnackBar(content: Text(l10n.actionFailed('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Pad(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: SwitchListTile(
        secondary: const Icon(Icons.visibility_outlined),
        title: Text(l10n.lastSeenVisible),
        subtitle: Text(l10n.lastSeenVisibleHint),
        value: _visible ?? true,
        onChanged: _visible == null || _busy ? null : _set,
      ),
    );
  }
}

/// Name and bio. Owns its text controllers: disposing them as soon as the
/// dialog returns would pull them from under its closing animation.
class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.displayName, required this.bio});

  final String displayName;
  final String bio;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  late final _name = TextEditingController(text: widget.displayName);
  late final _bio = TextEditingController(text: widget.bio);

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.editProfile),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            maxLength: 64,
            decoration: InputDecoration(
              labelText: l10n.displayNameLabel,
              helperText: l10n.displayNameHint,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bio,
            maxLength: 140,
            maxLines: 3,
            minLines: 1,
            decoration: InputDecoration(labelText: l10n.bioLabel),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((_name.text.trim(), _bio.text.trim())),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.onSubmit});

  final Future<void> Function(String current, String next) onSubmit;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _repeat = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    if (_next.text.length < 10) return setState(() => _error = l10n.passwordTooShort);
    if (_next.text != _repeat.text) return setState(() => _error = l10n.passwordsDiffer);
    setState(() {
      _busy = true;
      _error = null;
    });
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.onSubmit(_current.text, _next.text);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text(l10n.passwordChanged)));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e'.contains('403') ? l10n.passwordWrong : l10n.actionFailed('$e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    InputDecoration field(String label) => InputDecoration(labelText: label);
    return AlertDialog(
      title: Text(l10n.changePassword),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _current, obscureText: true, decoration: field(l10n.currentPassword)),
          const SizedBox(height: 8),
          TextField(controller: _next, obscureText: true, decoration: field(l10n.newPassword)),
          const SizedBox(height: 8),
          TextField(controller: _repeat, obscureText: true, decoration: field(l10n.repeatPassword)),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: context.pond.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(l10n.save),
        ),
      ],
    );
  }
}

class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.onSubmit});

  final Future<void> Function(String password) onSubmit;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final _password = TextEditingController();
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(_password.text);
      navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e'.contains('403') ? l10n.passwordWrong : l10n.actionFailed('$e');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    return AlertDialog(
      title: Text(l10n.deleteAccountTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.deleteAccountBody, style: const TextStyle(height: 1.4)),
          const SizedBox(height: 14),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: InputDecoration(labelText: l10n.passwordLabel),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: TextStyle(color: pond.danger)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: pond.danger),
          onPressed: _busy ? null : _submit,
          child: Text(l10n.deleteAccountConfirm),
        ),
      ],
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
    // A Material rather than a decorated box: list tiles paint their ink on
    // the nearest Material, and a coloured box above it would hide the ink.
    return Material(
      color: context.pond.lily,
      borderRadius: BorderRadius.circular(PondRadii.card),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
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
      leading: Icon(switch (session.deviceName) {
        'Android device' || 'iPhone' => Icons.smartphone_rounded,
        'Windows PC' || 'Mac' || 'Linux PC' => Icons.computer_rounded,
        _ => Icons.devices_other_rounded,
      }),
      title: Text(
        session.label.isEmpty ? l10n.unknownDevice : session.label,
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
