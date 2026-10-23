/// Picking several messages and acting on them at once, on a real chat
/// stack.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/repositories/device_resolver.dart';
import 'package:frogster/features/chat/bloc/chat_bloc.dart';
import 'package:frogster/features/chat/view/chat_screen.dart';
import 'package:frogster/l10n/app_localizations.dart';
import 'package:frogster/ui/theme/app_theme.dart';

import '../data/fake_server.dart';

void main() {
  testWidgets('select, copy and delete several messages', (tester) async {
    late FakeServer server;
    late FakeDevice alice, bob;
    late Chat chat;
    await tester.runAsync(() async {
      server = FakeServer();
      alice = await server.addDevice('alice');
      bob = await server.addDevice('bob');
      final fake = server.createChat(type: 'direct', mode: ChatMode.cloud, creator: alice.user, members: [bob.user]);
      for (final d in [alice, bob]) {
        await d.ws.connect();
      }
      await server.settle();
      for (final body in ['раз', 'два', 'три']) {
        await alice.repository.send(chatId: fake.id, body: body);
      }
      await server.settle();
      chat = (await alice.dao.chatById(fake.id))!;
    });

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BlocProvider(
        create: (_) => ChatBloc(
          repository: alice.repository,
          crypto: alice.engine,
          resolver: DeviceResolver(
            api: alice.api,
            crypto: alice.engine,
            selfDeviceId: alice.id,
            selfUsername: alice.user.username,
          ),
        )..add(ChatOpened(chat)),
        child: ChatScreen(selfUserId: alice.user.id),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    expect(find.text('два'), findsOneWidget);

    await tester.longPress(find.text('раз'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    // A tap now picks rather than opens anything.
    // The bubble's own text no longer takes taps: the row around it does.
    await tester.tap(find.text('три'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    expect(copied, 'раз\n\nтри', reason: 'in the order of the conversation');
    expect(find.textContaining('selected'), findsNothing);

    await tester.longPress(find.text('раз'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('два'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.byTooltip('Delete for everyone'));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 messages?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    // The bloc works in the test's zone: real I/O completes only as frames
    // are pumped, so real time and frames take turns.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.runAsync(() => server.settle());
    await tester.pumpAndSettle();

    expect(find.text('раз'), findsNothing);
    expect(find.text('два'), findsNothing);
    expect(find.text('три'), findsOneWidget);
    await tester.runAsync(() async {
      // The deletion leaves from the widget zone; give it time to arrive.
      for (var i = 0; i < 60 && (await bob.messages(chat.id)).length > 1; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(bodies(await bob.messages(chat.id)), ['три'], reason: 'deleted for everyone');
      await tester.pumpWidget(const SizedBox());
      await alice.dispose();
      await bob.dispose();
    });
  });
}
