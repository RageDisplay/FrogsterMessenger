/// Starting conversations: finding people, choosing how the chat is
/// protected, and putting groups together.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/theme/app_theme.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/lily_avatar.dart';

/// Looks people up by the start of their username.
typedef UserSearch = Future<List<UserProfile>> Function(String query);

/// Search as you type: debounced, and only once the query is long enough for
/// the server to accept it.
class _SearchState {
  _SearchState(this._search, this._onChanged);

  final UserSearch _search;
  final VoidCallback _onChanged;

  Timer? _debounce;
  var _generation = 0;

  String query = '';
  List<UserProfile> results = const [];
  bool loading = false;
  String? error;

  bool get tooShort => query.trim().replaceFirst('@', '').length < 2;

  void update(String value) {
    query = value;
    _debounce?.cancel();
    if (tooShort) {
      results = const [];
      loading = false;
      error = null;
      _onChanged();
      return;
    }
    loading = true;
    _onChanged();
    _debounce = Timer(const Duration(milliseconds: 300), _run);
  }

  Future<void> _run() async {
    // A slow answer to an older query must not replace a newer one.
    final generation = ++_generation;
    try {
      final found = await _search(query.trim());
      if (generation != _generation) return;
      results = found;
      error = null;
    } catch (e) {
      if (generation != _generation) return;
      results = const [];
      error = '$e';
    }
    loading = false;
    _onChanged();
  }

  void dispose() => _debounce?.cancel();
}

/// The search box with its results under it.
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.state,
    required this.onTap,
    this.selected = const {},
    this.hideIds = const {},
  });

  final _SearchState state;
  final void Function(UserProfile user) onTap;

  /// Shown with a check mark, when picking several people.
  final Set<String> selected;

  /// People who cannot be picked, such as current members.
  final Set<String> hideIds;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;

    if (state.tooShort) {
      return _Hint(text: l10n.searchTooShort);
    }
    if (state.loading && state.results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    if (state.error != null) {
      return _Hint(text: l10n.searchFailed(state.error!));
    }
    final visible = state.results.where((u) => !hideIds.contains(u.userId)).toList();
    if (visible.isEmpty) return _Hint(text: l10n.searchNobody);

    return Column(
      children: [
        for (final user in visible)
          ListTile(
            onTap: () => onTap(user),
            leading: LilyAvatar(seed: user.username, label: user.name, size: 40),
            title: Text(user.name, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('@${user.username}', style: TextStyle(color: pond.inkMuted)),
            trailing: selected.contains(user.userId)
                ? Icon(Icons.check_circle_rounded, color: pond.accent)
                : null,
          ),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: context.pond.inkMuted),
        ),
      );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onChanged, this.autofocus = true});

  final ValueChanged<String> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextField(
        autofocus: autofocus,
        autocorrect: false,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: AppLocalizations.of(context).newChatSearchHint,
          prefixIcon: const Icon(Icons.search_rounded),
        ),
      );
}

/// Cloud or secret, with a line on what the choice means.
class ModePicker extends StatelessWidget {
  const ModePicker({super.key, required this.mode, required this.onChanged});

  final ChatMode mode;
  final ValueChanged<ChatMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ChatMode>(
          segments: [
            ButtonSegment(
              value: ChatMode.cloud,
              icon: const Icon(Icons.cloud_outlined),
              label: Text(l10n.modeCloud),
            ),
            ButtonSegment(
              value: ChatMode.secret,
              icon: const Icon(Icons.lock_outline_rounded),
              label: Text(l10n.modeSecret),
            ),
          ],
          selected: {mode},
          showSelectedIcon: false,
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 8),
        Text(
          mode == ChatMode.cloud ? l10n.modeCloudExplain : l10n.modeSecretExplain,
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: mode == ChatMode.secret ? pond.mint : pond.inkMuted,
          ),
        ),
      ],
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.children, this.action});

  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
          actions: [?action, const SizedBox(width: 8)],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: children,
              ),
            ),
          ),
        ),
      );
}

/// Finds someone and opens a chat with them, cloud or secret.
class NewChatScreen extends StatefulWidget {
  const NewChatScreen({
    super.key,
    required this.search,
    required this.onStart,
    required this.onNewGroup,
  });

  final UserSearch search;
  final Future<void> Function(UserProfile user, ChatMode mode) onStart;
  final VoidCallback onNewGroup;

  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

class _NewChatScreenState extends State<NewChatScreen> {
  late final _search = _SearchState(widget.search, () {
    if (mounted) setState(() {});
  });
  var _mode = ChatMode.cloud;
  var _busy = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _start(UserProfile user) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onStart(user, _mode);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    return _Page(
      title: l10n.newChatTitle,
      children: [
        ModePicker(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
        const SizedBox(height: 16),
        _SearchField(onChanged: _search.update),
        const SizedBox(height: 8),
        Material(
          color: pond.lily,
          borderRadius: BorderRadius.circular(PondRadii.card),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                onTap: widget.onNewGroup,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: pond.accentSoft,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.group_add_outlined, color: pond.accent),
                ),
                title: Text(l10n.newGroup, style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Divider(height: 1, color: pond.outline),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              _SearchResults(state: _search, onTap: _start),
            ],
          ),
        ),
      ],
    );
  }
}

/// Puts a group together: how it is protected, its name and its members.
class NewGroupScreen extends StatefulWidget {
  const NewGroupScreen({
    super.key,
    required this.search,
    required this.onCreate,
    this.initialMode = ChatMode.cloud,
  });

  final UserSearch search;
  final Future<void> Function(String title, List<UserProfile> members, ChatMode mode) onCreate;
  final ChatMode initialMode;

  @override
  State<NewGroupScreen> createState() => _NewGroupScreenState();
}

class _NewGroupScreenState extends State<NewGroupScreen> {
  late final _search = _SearchState(widget.search, () {
    if (mounted) setState(() {});
  });
  final _name = TextEditingController();
  final _picked = <String, UserProfile>{};
  late var _mode = widget.initialMode;
  var _busy = false;
  String? _problem;

  @override
  void dispose() {
    _search.dispose();
    _name.dispose();
    super.dispose();
  }

  void _toggle(UserProfile user) => setState(() {
        if (_picked.remove(user.userId) == null) _picked[user.userId] = user;
        _problem = null;
      });

  Future<void> _create() async {
    final l10n = AppLocalizations.of(context);
    final title = _name.text.trim();
    if (title.isEmpty) {
      setState(() => _problem = l10n.groupNeedsName);
      return;
    }
    if (_picked.isEmpty) {
      setState(() => _problem = l10n.groupNeedsMembers);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    try {
      await widget.onCreate(title, _picked.values.toList(), _mode);
    } catch (e) {
      if (mounted) setState(() => _problem = l10n.actionFailed('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    return _Page(
      title: l10n.newGroupTitle,
      action: FilledButton(
        onPressed: _busy ? null : _create,
        child: Text(l10n.create),
      ),
      children: [
        ModePicker(mode: _mode, onChanged: (m) => setState(() => _mode = m)),
        const SizedBox(height: 16),
        TextField(
          controller: _name,
          maxLength: 64,
          decoration: InputDecoration(
            labelText: l10n.groupNameLabel,
            helperText: _mode == ChatMode.secret ? l10n.secretGroupNameNote : null,
            helperMaxLines: 2,
            counterText: '',
          ),
        ),
        if (_picked.isNotEmpty) ...[
          const SizedBox(height: 14),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final user in _picked.values)
                InputChip(
                  label: Text(user.name),
                  avatar: LilyAvatar(seed: user.username, label: user.name, size: 22),
                  onDeleted: () => _toggle(user),
                ),
            ],
          ),
        ],
        if (_problem != null) ...[
          const SizedBox(height: 10),
          Text(_problem!, style: TextStyle(color: pond.danger)),
        ],
        if (_busy) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 2),
        ],
        const SizedBox(height: 16),
        Text(
          l10n.groupMembersLabel.toUpperCase(),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: pond.inkMuted,
          ),
        ),
        const SizedBox(height: 8),
        _SearchField(onChanged: _search.update, autofocus: false),
        _SearchResults(
          state: _search,
          selected: _picked.keys.toSet(),
          onTap: _toggle,
        ),
      ],
    );
  }
}

/// Picks people to add to an existing group.
class UserPickerScreen extends StatefulWidget {
  const UserPickerScreen({
    super.key,
    required this.search,
    this.excludeIds = const {},
  });

  final UserSearch search;

  /// Already in the group.
  final Set<String> excludeIds;

  @override
  State<UserPickerScreen> createState() => _UserPickerScreenState();
}

class _UserPickerScreenState extends State<UserPickerScreen> {
  late final _search = _SearchState(widget.search, () {
    if (mounted) setState(() {});
  });
  final _picked = <String, UserProfile>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Page(
      title: l10n.addMembers,
      action: FilledButton(
        onPressed: _picked.isEmpty
            ? null
            : () => Navigator.of(context).pop(_picked.values.toList()),
        child: Text(l10n.add),
      ),
      children: [
        _SearchField(onChanged: _search.update),
        _SearchResults(
          state: _search,
          selected: _picked.keys.toSet(),
          hideIds: widget.excludeIds,
          onTap: (user) => setState(() {
            if (_picked.remove(user.userId) == null) _picked[user.userId] = user;
          }),
        ),
      ],
    );
  }
}
