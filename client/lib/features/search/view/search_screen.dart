/// Finding a chat by its name or a message by its words.
///
/// Searches what is on this device. Secret history exists nowhere else, so
/// there is nothing more to search; cloud history older than what has been
/// loaded is not covered yet.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/models/models.dart';
import '../../../l10n/app_localizations.dart';
import '../../../ui/format.dart';
import '../../../ui/theme/pond_colors.dart';
import '../../../ui/widgets/lily_avatar.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.chats,
    required this.searchMessages,
    required this.onOpenChat,
  });

  final List<Chat> chats;
  final Future<List<Message>> Function(String query) searchMessages;
  final void Function(Chat chat) onOpenChat;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  Timer? _debounce;
  var _query = '';
  var _messages = const <Message>[];
  var _generation = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onChanged(String value) {
    setState(() => _query = value.trim());
    _debounce?.cancel();
    if (_query.length < 2) {
      setState(() => _messages = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      // An answer to an older query must not replace a newer one.
      final generation = ++_generation;
      final found = await widget.searchMessages(_query);
      if (mounted && generation == _generation) setState(() => _messages = found);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final pond = context.pond;
    final q = _query.toLowerCase();
    final chats = q.isEmpty
        ? const <Chat>[]
        : widget.chats
            .where((c) =>
                !c.hidden &&
                (c.displayName.toLowerCase().contains(q) ||
                    (c.peerUsername?.toLowerCase().contains(q) ?? false)))
            .toList();
    final byId = {for (final c in widget.chats) c.id: c};
    final messages = _messages.where((m) => byId[m.chatId] != null).toList();

    Widget section(String title) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: pond.inkMuted,
            ),
          ),
        );

    return Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          onChanged: _onChanged,
          decoration: InputDecoration(
            hintText: l10n.searchHint,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
          ),
        ),
      ),
      body: SafeArea(
        child: _query.isEmpty
            ? const SizedBox.shrink()
            : chats.isEmpty && messages.isEmpty
                ? Center(child: Text(l10n.searchNothing, style: TextStyle(color: pond.inkMuted)))
                : ListView(
                    children: [
                      if (chats.isNotEmpty) section(l10n.chatsTitle),
                      for (final chat in chats)
                        ListTile(
                          leading: LilyAvatar(
                            seed: chat.peerUsername ?? chat.id,
                            label: chat.displayName,
                            icon: chat.isGroup ? Icons.groups_rounded : null,
                            secret: chat.isSecret,
                            size: 40,
                          ),
                          title: Text(chat.displayName, style: const TextStyle(fontWeight: FontWeight.w700)),
                          onTap: () => widget.onOpenChat(chat),
                        ),
                      if (messages.isNotEmpty) section(l10n.searchMessages),
                      for (final message in messages)
                        ListTile(
                          title: Text(
                            byId[message.chatId]!.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: _Highlighted(text: message.body, query: _query),
                          trailing: Text(
                            formatListStamp(context, message.sentAt),
                            style: TextStyle(fontSize: 12, color: pond.inkMuted),
                          ),
                          onTap: () => widget.onOpenChat(byId[message.chatId]!),
                        ),
                    ],
                  ),
      ),
    );
  }
}

/// The message with the matched words picked out, starting near the match
/// so it shows even in a long message.
class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query});

  final String text;
  final String query;

  @override
  Widget build(BuildContext context) {
    final pond = context.pond;
    final flat = text.replaceAll('\n', ' ');
    final at = flat.toLowerCase().indexOf(query.toLowerCase());
    if (at < 0) return Text(flat, maxLines: 2, overflow: TextOverflow.ellipsis);
    final start = at > 30 ? at - 30 : 0;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: '${start > 0 ? '…' : ''}${flat.substring(start, at)}'),
        TextSpan(
          text: flat.substring(at, at + query.length),
          style: TextStyle(color: pond.accent, fontWeight: FontWeight.w700),
        ),
        TextSpan(text: flat.substring(at + query.length)),
      ]),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: pond.inkMuted),
    );
  }
}
