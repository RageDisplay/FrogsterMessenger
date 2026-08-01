import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/features/auth/view/login_screen.dart';
import 'package:frogster/features/chat/widgets/message_bubble.dart';
import 'package:frogster/features/chat_list/view/chat_list_screen.dart';
import 'package:frogster/features/settings/view/safety_number_screen.dart';
import 'package:frogster/ui/adaptive/adaptive_shell.dart';
import 'package:frogster/ui/theme/app_theme.dart';

/// Wraps a widget in the app's theme at a chosen window size.
Widget host(Widget child, {Size size = const Size(400, 800)}) => MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(theme: AppTheme.light(), home: child),
    );

/// Hosts a bubble the way the chat list does: inside a Scaffold, so its Column
/// is laid out against a bounded height rather than an infinite one.
Widget hostBubble(Widget child) => host(Scaffold(body: child));

Message message({
  String id = 'm1',
  String body = 'hello',
  bool outgoing = false,
  MessageStatus status = MessageStatus.sent,
  Map<String, Set<String>> reactions = const {},
}) =>
    Message(
      id: id,
      chatId: 'c1',
      senderId: 'alice',
      senderDeviceId: 'dev-1',
      body: body,
      sentAt: DateTime(2026, 1, 1, 12, 30),
      isOutgoing: outgoing,
      status: status,
      reactions: reactions,
    );

void main() {
  group('LoginScreen', () {
    testWidgets('rejects a short password before contacting the server',
        (tester) async {
      // The server enforces this too; catching it locally avoids burning a
      // rate-limited request on an obvious mistake.
      var submitted = false;

      await tester.pumpWidget(host(LoginScreen(
        busy: false,
        onSubmit: (_, _, _) async => submitted = true,
      )));

      await tester.enterText(find.byType(TextFormField).first, 'alice');
      await tester.enterText(find.byType(TextFormField).last, 'short');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(submitted, isFalse);
      expect(find.text('At least 10 characters'), findsOneWidget);
    });

    testWidgets('rejects invalid username characters', (tester) async {
      await tester.pumpWidget(host(LoginScreen(
        busy: false,
        onSubmit: (_, _, _) async {},
      )));

      await tester.enterText(find.byType(TextFormField).first, 'bad name!');
      await tester.enterText(
          find.byType(TextFormField).last, 'longenoughpassword');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(
        find.text('Letters, numbers and underscore only'),
        findsOneWidget,
      );
    });

    testWidgets('submits valid credentials', (tester) async {
      String? gotUsername;
      bool? gotRegister;

      await tester.pumpWidget(host(LoginScreen(
        busy: false,
        onSubmit: (username, _, register) async {
          gotUsername = username;
          gotRegister = register;
        },
      )));

      await tester.enterText(find.byType(TextFormField).first, 'alice');
      await tester.enterText(
          find.byType(TextFormField).last, 'correct-horse-battery');
      await tester.tap(find.text('Sign in'));
      await tester.pump();

      expect(gotUsername, 'alice');
      expect(gotRegister, isFalse);
    });

    testWidgets('toggles between sign in and register', (tester) async {
      await tester.pumpWidget(host(LoginScreen(
        busy: false,
        onSubmit: (_, _, _) async {},
      )));

      expect(find.text('Sign in'), findsOneWidget);
      await tester.tap(find.text('Create a new account'));
      await tester.pump();
      expect(find.text('Create account'), findsOneWidget);
    });

    testWidgets('disables input while busy', (tester) async {
      await tester.pumpWidget(host(LoginScreen(
        busy: true,
        onSubmit: (_, _, _) async {},
      )));

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  });

  group('ChatListScreen', () {
    testWidgets('shows an empty state with no chats', (tester) async {
      await tester.pumpWidget(host(ChatListScreen(
        chats: const [],
        connection: SocketState.connected,
        onOpenChat: (_) {},
      )));

      expect(find.text('No conversations yet'), findsOneWidget);
    });

    testWidgets('renders chats with previews and unread badges',
        (tester) async {
      await tester.pumpWidget(host(ChatListScreen(
        chats: [
          Chat(
            id: 'c1',
            type: 'direct',
            epoch: 0,
            peerUsername: 'bob',
            lastMessagePreview: 'see you soon',
            lastMessageAt: DateTime.now(),
            unreadCount: 3,
          ),
        ],
        connection: SocketState.connected,
        onOpenChat: (_) {},
      )));

      expect(find.text('bob'), findsOneWidget);
      expect(find.text('see you soon'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
    });

    testWidgets('warns when the socket is offline', (tester) async {
      // Without this the list just looks stale, and the user cannot tell
      // whether nobody is writing or the connection is down.
      await tester.pumpWidget(host(ChatListScreen(
        chats: const [],
        connection: SocketState.disconnected,
        onOpenChat: (_) {},
      )));

      expect(
        find.text('Offline — messages will send later'),
        findsOneWidget,
      );
    });

    testWidgets('hides the banner when connected', (tester) async {
      await tester.pumpWidget(host(ChatListScreen(
        chats: const [],
        connection: SocketState.connected,
        onOpenChat: (_) {},
      )));

      expect(
        find.text('Offline — messages will send later'),
        findsNothing,
      );
    });

    testWidgets('opens a chat on tap', (tester) async {
      Chat? opened;

      await tester.pumpWidget(host(ChatListScreen(
        chats: [
          Chat(id: 'c1', type: 'direct', epoch: 0, peerUsername: 'bob'),
        ],
        connection: SocketState.connected,
        onOpenChat: (chat) => opened = chat,
      )));

      await tester.tap(find.text('bob'));
      await tester.pump();

      expect(opened?.id, 'c1');
    });

    testWidgets('shows a group icon for group chats', (tester) async {
      await tester.pumpWidget(host(ChatListScreen(
        chats: const [
          Chat(id: 'g1', type: 'group', epoch: 0, title: 'Team'),
        ],
        connection: SocketState.connected,
        onOpenChat: (_) {},
      )));

      expect(find.byIcon(Icons.groups_outlined), findsOneWidget);
      expect(find.text('Team'), findsOneWidget);
    });
  });

  group('MessageBubble', () {
    testWidgets('renders body and time', (tester) async {
      await tester.pumpWidget(hostBubble(
        MessageBubble(message: message(body: 'hi there'), onReact: (_, _) {}),
      ));

      expect(find.text('hi there'), findsOneWidget);
      expect(find.text('12:30'), findsOneWidget);
    });

    testWidgets('shows a delivery indicator only on outgoing messages',
        (tester) async {
      await tester.pumpWidget(hostBubble(
        MessageBubble(
          message: message(outgoing: true, status: MessageStatus.delivered),
          onReact: (_, _) {},
        ),
      ));
      expect(find.byIcon(Icons.done_all), findsOneWidget);

      await tester.pumpWidget(hostBubble(
        MessageBubble(message: message(outgoing: false), onReact: (_, _) {}),
      ));
      expect(find.byIcon(Icons.done_all), findsNothing);
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('marks a failed send distinctly', (tester) async {
      // A failed send must not look like a successful one: that is how a
      // blocked key-change ends up unnoticed.
      await tester.pumpWidget(hostBubble(
        MessageBubble(
          message: message(outgoing: true, status: MessageStatus.failed),
          onReact: (_, _) {},
        ),
      ));

      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('renders reaction counts', (tester) async {
      await tester.pumpWidget(hostBubble(
        MessageBubble(
          message: message(reactions: {
            '👍': {'bob', 'carol'},
          }),
          onReact: (_, _) {},
        ),
      ));

      expect(find.text('👍 2'), findsOneWidget);
    });

    testWidgets('long press opens the reaction picker', (tester) async {
      String? picked;

      await tester.pumpWidget(hostBubble(
        MessageBubble(
          message: message(),
          onReact: (emoji, _) => picked = emoji,
        ),
      ));

      await tester.longPress(find.text('hello'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('❤️'));
      await tester.pumpAndSettle();

      expect(picked, '❤️');
    });
  });

  group('AdaptiveShell', () {
    testWidgets('shows one pane on a narrow window', (tester) async {
      await tester.pumpWidget(host(
        AdaptiveShell(
          list: const Text('LIST'),
          detail: const Text('DETAIL'),
          hasSelection: false,
          onClearSelection: () {},
        ),
        size: const Size(400, 800),
      ));

      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('DETAIL'), findsNothing);
    });

    testWidgets('narrow window replaces the list when a chat is open',
        (tester) async {
      await tester.pumpWidget(host(
        AdaptiveShell(
          list: const Text('LIST'),
          detail: const Text('DETAIL'),
          hasSelection: true,
          onClearSelection: () {},
        ),
        size: const Size(400, 800),
      ));

      expect(find.text('DETAIL'), findsOneWidget);
      expect(find.text('LIST'), findsNothing);
    });

    testWidgets('shows both panes on a wide window', (tester) async {
      await tester.pumpWidget(host(
        AdaptiveShell(
          list: const Text('LIST'),
          detail: const Text('DETAIL'),
          hasSelection: true,
          onClearSelection: () {},
        ),
        size: const Size(1200, 800),
      ));

      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('DETAIL'), findsOneWidget);
    });

    testWidgets('wide window prompts when nothing is selected',
        (tester) async {
      await tester.pumpWidget(host(
        AdaptiveShell(
          list: const Text('LIST'),
          detail: null,
          hasSelection: false,
          onClearSelection: () {},
        ),
        size: const Size(1200, 800),
      ));

      expect(find.text('LIST'), findsOneWidget);
      expect(find.text('Select a conversation'), findsOneWidget);
    });
  });

  group('SafetyNumberScreen', () {
    testWidgets('displays the number in readable groups', (tester) async {
      await tester.pumpWidget(host(
        SafetyNumberScreen(peerName: 'bob', digits: '0' * 60),
      ));

      expect(find.text('Verify with bob'), findsOneWidget);
      expect(find.byType(SelectableText), findsOneWidget);

      final rendered =
          tester.widget<SelectableText>(find.byType(SelectableText));
      final digitsOnly = rendered.data!.replaceAll(RegExp(r'[\s\n]'), '');
      expect(digitsOnly.length, 60);
    });

    testWidgets('explains what a changed number means', (tester) async {
      await tester.pumpWidget(host(
        SafetyNumberScreen(peerName: 'bob', digits: '1' * 60),
      ));

      expect(
        find.textContaining('someone may be intercepting'),
        findsOneWidget,
      );
    });
  });
}
