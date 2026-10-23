/// A group's details: name, members and roles, and leaving.
library;

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/avatars.dart';

class GroupInfoScreen extends StatefulWidget {
  const GroupInfoScreen({
    super.key,
    required this.chat,
    required this.selfUserId,
    required this.onRename,
    required this.onAddMembers,
    required this.onRemove,
    required this.onLeave,
    this.onChangeAvatar,
    this.onRemoveAvatar,
    this.onSetHideHistory,
  });

  final Chat chat;
  final String selfUserId;

  /// Each returns the chat as it stands afterwards, or null if it failed.
  final Future<Chat?> Function(String title) onRename;
  final Future<Chat?> Function() onAddMembers;
  final Future<Chat?> Function(ChatMember member) onRemove;
  final Future<void> Function() onLeave;

  /// Cloud groups only: their look and history live on the server.
  final Future<Chat?> Function()? onChangeAvatar;
  final Future<Chat?> Function()? onRemoveAvatar;
  final Future<Chat?> Function(bool hide)? onSetHideHistory;

  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  late Chat _chat = widget.chat;
  var _busy = false;

  Future<void> _run(Future<Chat?> Function() action) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (updated != null && mounted) setState(() => _chat = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).actionFailed('$e'))),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename() async {
    final l10n = AppLocalizations.of(context);
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameDialog(
        title: l10n.rename,
        label: l10n.groupNameLabel,
        initial: _chat.title ?? '',
      ),
    );
    if (title == null || title.isEmpty || title == _chat.title) return;
    await _run(() => widget.onRename(title));
  }

  Future<void> _avatarMenu() async {
    final l10n = AppLocalizations.of(context);
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
            if (_chat.avatarVersion > 0 && widget.onRemoveAvatar != null)
              ListTile(
                leading: Icon(Icons.delete_outline_rounded, color: context.pond.danger),
                title: Text(l10n.avatarRemove, style: TextStyle(color: context.pond.danger)),
                onTap: () => Navigator.of(sheetContext).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == 'set') await _run(widget.onChangeAvatar!);
    if (choice == 'remove') await _run(widget.onRemoveAvatar!);
  }

  Future<void> _leave() async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.leaveGroupTitle),
        content: Text(l10n.leaveGroupBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.pond.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.leave),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    setState(() => _busy = true);
    try {
      await widget.onLeave();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final chat = _chat;
    final admin = chat.isAdmin;
    final manageCloud = admin && !chat.isSecret;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.groupInfo, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Row(
                  children: [
                    InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: manageCloud && widget.onChangeAvatar != null && !_busy
                          ? _avatarMenu
                          : null,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ChatAvatar(chat: chat, size: 64),
                          if (manageCloud && widget.onChangeAvatar != null)
                            Positioned(
                              right: -4,
                              bottom: -4,
                              child: CircleAvatar(
                                radius: 13,
                                backgroundColor: pond.accent,
                                child: Icon(Icons.photo_camera_rounded, size: 14, color: pond.onAccent),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            chat.displayName,
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Icon(
                                chat.isSecret ? Icons.lock_rounded : Icons.cloud_outlined,
                                size: 13,
                                color: chat.isSecret ? pond.mint : pond.inkMuted,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${chat.isSecret ? l10n.modeSecret : l10n.modeCloud} · '
                                '${l10n.membersCount(chat.members.length)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: chat.isSecret ? pond.mint : pond.inkMuted,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (admin)
                      IconButton(
                        tooltip: l10n.rename,
                        onPressed: _busy ? null : _rename,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                if (manageCloud && widget.onSetHideHistory != null) ...[
                  Material(
                    color: pond.lily,
                    borderRadius: BorderRadius.circular(PondRadii.card),
                    clipBehavior: Clip.antiAlias,
                    child: SwitchListTile(
                      value: chat.hideHistory,
                      onChanged: _busy ? null : (v) => _run(() => widget.onSetHideHistory!(v)),
                      title: Text(l10n.hideHistoryTitle, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(l10n.hideHistoryHint, style: TextStyle(color: pond.inkMuted)),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Material(
                  color: pond.lily,
                  borderRadius: BorderRadius.circular(PondRadii.card),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      if (admin) ...[
                        ListTile(
                          onTap: _busy ? null : () => _run(widget.onAddMembers),
                          leading: Icon(Icons.person_add_alt_1_outlined, color: pond.accent),
                          title: Text(
                            l10n.addMembers,
                            style: TextStyle(color: pond.accent, fontWeight: FontWeight.w700),
                          ),
                        ),
                        Divider(height: 1, color: pond.outline),
                      ],
                      for (final member in chat.members)
                        ListTile(
                          leading: UserAvatar.member(member, showPresence: true),
                          title: Text(
                            member.userId == widget.selfUserId
                                ? l10n.youSuffix(member.name)
                                : member.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: member.userId == widget.selfUserId
                              ? Text('@${member.username}', style: TextStyle(color: pond.inkMuted))
                              : PresenceLine(userId: member.userId, fallback: '@${member.username}'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (member.isAdmin)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: pond.accentSoft,
                                    borderRadius: BorderRadius.circular(PondRadii.chip),
                                  ),
                                  child: Text(
                                    l10n.roleAdmin,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: pond.accent,
                                    ),
                                  ),
                                ),
                              if (admin && member.userId != widget.selfUserId)
                                PopupMenuButton<void>(
                                  enabled: !_busy,
                                  itemBuilder: (_) => [
                                    PopupMenuItem(
                                      onTap: () => _run(() => widget.onRemove(member)),
                                      child: Text(
                                        l10n.removeFromGroup,
                                        style: TextStyle(color: pond.danger),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: pond.danger,
                    side: BorderSide(color: pond.outline),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: _busy ? null : _leave,
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(l10n.leaveGroup),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One text field and a save button. Owns its controller, so the field
/// outlives nothing it depends on while the dialog animates away.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title, required this.label, required this.initial});

  final String title;
  final String label;
  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(l10n.save),
        ),
      ],
    );
  }
}
