/// The voice channels on screen: the panel in a group's chat and the bar
/// over every screen during a call.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/local/account_store.dart';
import 'package:frogster/data/local/preferences.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/data/voice/voice_controller.dart';
import 'package:frogster/data/voice/voice_link.dart';
import 'package:frogster/data/voice/voice_models.dart';
import 'package:frogster/features/voice/voice_bar.dart';
import 'package:frogster/features/voice/voice_channels.dart';
import 'package:frogster/features/voice/voice_scope.dart';
import 'package:frogster/l10n/app_localizations.dart';
import 'package:frogster/ui/theme/app_theme.dart';

import '../data/voice_controller_test.dart' show FakeCall, FakePlatform, FakeVoiceApi, roomsFrame;

Chat group({String role = 'member'}) => Chat(
      id: 'g1',
      type: 'group',
      epoch: 1,
      mode: ChatMode.cloud,
      title: 'Пруд',
      role: role,
      members: const [
        ChatMember(userId: 'me', username: 'me', role: 'member'),
        ChatMember(userId: 'bob', username: 'bob', displayName: 'Боб', role: 'member'),
      ],
    );

void main() {
  late FakeVoiceApi api;
  late StreamController<Envelope> frames;
  late VoiceController voice;
  late FakeCall call;

  setUp(() {
    api = FakeVoiceApi()..channels['g1'] = const [VoiceChannel(id: 'ch1', name: 'Общий')];
    frames = StreamController<Envelope>.broadcast(sync: true);
    voice = VoiceController(
      api: api,
      frames: frames.stream,
      connection: const Stream.empty(),
      preferences: AppPreferences(MemorySecureValues()),
      selfUserId: 'me',
      platform: FakePlatform(),
      startCall: (_, _) async => call = FakeCall(),
    );
  });

  tearDown(() async {
    voice.dispose();
    await frames.close();
  });

  Future<void> show(WidgetTester tester, Widget child) => tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ListenableBuilder(listenable: voice, builder: (_, _) => child)),
      ));

  testWidgets('a channel shows who is in it, and joins on a tap', (tester) async {
    await show(tester, Column(children: [VoiceChannelsPanel(chat: group(), controller: voice)]));
    await tester.pump();
    frames.add(roomsFrame('g1', {'ch1': [(11, 'bob')]}));
    await tester.pump();

    expect(find.text('Voice channels · 1 talking'), findsOneWidget);
    expect(find.text('Общий'), findsOneWidget);
    expect(find.text('Боб'), findsOneWidget);
    expect(find.byTooltip('New voice channel'), findsNothing, reason: 'only admins make channels');

    await tester.tap(find.text('Join'));
    await tester.pump();
    expect(api.calls, ['join ch1']);
    expect(voice.current?.channel.id, 'ch1');
    call.statuses.add(const VoiceLinkStatus(VoiceRoute.udp));
    frames.add(roomsFrame('g1', {'ch1': [(10, 'me'), (11, 'bob')]}));
    await tester.pump();
    expect(find.text('You are here'), findsOneWidget);
  });

  testWidgets('nothing to show a member in a group without channels; an admin can make one', (tester) async {
    api.channels['g1'] = const [];
    await show(tester, Column(children: [VoiceChannelsPanel(chat: group(), controller: voice)]));
    await tester.pump();
    expect(find.text('Voice channels'), findsNothing);

    await show(tester, Column(children: [VoiceChannelsPanel(chat: group(role: 'admin'), controller: voice)]));
    await tester.pump();
    await tester.tap(find.byTooltip('New voice channel'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Болталка');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.calls, ['create Болталка']);
    expect(find.text('Болталка'), findsOneWidget);
  });

  testWidgets('the bar above the navigator, as the app has it, through screens, dialogs and the end of the call',
      (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light(),
      locale: const Locale('ru'),
      navigatorKey: navigator,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => VoiceScope(controller: voice, openChat: (_) {}, child: VoiceFrame(child: child!)),
      home: const Scaffold(body: Center(child: Text('home'))),
    ));
    await voice.join('g1', const VoiceChannel(id: 'ch1', name: 'Общий'), chatTitle: 'Пруд');
    await tester.pump();
    expect(find.text('Общий · Пруд'), findsOneWidget);
    expect(find.text('home'), findsOneWidget, reason: 'the screen under the bar is the same one');

    navigator.currentState!.push(MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('second')),
        body: Builder(builder: (context) {
          return TextButton(
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('snack')));
              showDialog<void>(context: context, builder: (_) => const AlertDialog(title: Text('dialog')));
            },
            child: const Text('go'),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsOneWidget);
    expect(find.text('snack'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pumpAndSettle();
    expect(find.text('dialog'), findsOneWidget, reason: 'the screens survive the bar going away');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar: where, how, and the buttons work', (tester) async {
    await voice.join('g1', const VoiceChannel(id: 'ch1', name: 'Общий'), chatTitle: 'Пруд');
    String? opened;
    await show(tester, VoiceBar(controller: voice, onOpen: (id) => opened = id));
    expect(find.text('Общий · Пруд'), findsOneWidget);
    expect(find.text('Connecting…'), findsOneWidget);

    call.statuses.add(const VoiceLinkStatus(VoiceRoute.relayed, rtt: Duration(milliseconds: 85)));
    await tester.pump();
    expect(find.text("Connected through the server's HTTPS port · 85 ms"), findsOneWidget);

    await tester.tap(find.byIcon(Icons.mic_rounded));
    await tester.pump();
    expect(voice.current!.muted, isTrue);
    expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.headset_rounded));
    await tester.pump();
    expect(voice.current!.deafened, isTrue);

    await tester.tap(find.text('Общий · Пруд'));
    expect(opened, 'g1');

    await tester.tap(find.byIcon(Icons.call_end_rounded));
    await tester.pump();
    expect(voice.current, isNull);
    expect(find.byType(IconButton), findsNothing, reason: 'no call, no bar');
  });
}
