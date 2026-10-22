import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/local/account_store.dart';
import 'package:frogster/data/local/preferences.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/ws_client.dart';
import 'package:frogster/features/auth/view/login_screen.dart';
import 'package:frogster/features/chat_list/view/chat_list_screen.dart';
import 'package:frogster/l10n/app_localizations.dart';
import 'package:frogster/ui/theme/app_theme.dart';
import 'package:frogster/ui/theme/pond_colors.dart';
import 'package:frogster/ui/widgets/lily_avatar.dart';

Widget localized(Widget child, {Locale locale = const Locale('ru'), bool dark = false}) =>
    MaterialApp(
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );

const _chats = [
  Chat(id: 'c1', type: 'direct', epoch: 0, peerUsername: 'anya'),
  Chat(id: 'g1', type: 'group', epoch: 0, title: 'Проект'),
];

void main() {
  group('avatars', () {
    test('the same contact always gets the same tint', () {
      // String.hashCode differs between runs; avatar colours must not.
      expect(PondColors.light.tintFor('alice'), PondColors.light.tintFor('alice'));
      expect(PondColors.dark.tintFor('alice'), PondColors.dark.tintFor('alice'));
    });

    test('contacts spread across the palette', () {
      final tints = {
        for (final n in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'])
          PondColors.light.tintFor(n),
      };
      expect(tints.length, greaterThan(3));
    });

    test('FNV-1a matches its published test vector', () {
      // Pins the hash so a refactor cannot silently reshuffle every colour.
      expect(stableHash('a'), 0xE40C292C);
    });

    test('initials handle empty names and non-Latin letters', () {
      expect(LilyAvatar.initialOf(''), '?');
      expect(LilyAvatar.initialOf('  ярослав'), 'Я');
    });
  });

  group('chat filters', () {
    testWidgets('narrow the list to direct chats or groups', (tester) async {
      await tester.pumpWidget(localized(ChatListScreen(
        chats: _chats,
        connection: SocketState.connected,
        onOpenChat: (_) {},
      )));
      expect(find.text('anya'), findsOneWidget);
      expect(find.text('Проект'), findsOneWidget);

      await tester.tap(find.text('Группы'));
      await tester.pump();
      expect(find.text('anya'), findsNothing);
      expect(find.text('Проект'), findsOneWidget);

      await tester.tap(find.text('Личные'));
      await tester.pump();
      expect(find.text('anya'), findsOneWidget);
      expect(find.text('Проект'), findsNothing);
    });
  });

  group('interface language', () {
    test('follows the system when it is Russian or English', () {
      expect(resolveLocale([const Locale('en', 'US')], supportedLocales),
          const Locale('en'));
      expect(resolveLocale([const Locale('ru', 'RU')], supportedLocales),
          const Locale('ru'));
    });

    test('falls back to Russian for anything else', () {
      expect(resolveLocale([const Locale('de')], supportedLocales),
          const Locale('ru'));
    });

    test('a chosen language and theme survive a restart', () async {
      final values = MemorySecureValues();
      final before = AppPreferences(values);
      await before.setThemeMode(ThemeMode.dark);
      await before.setLocale(const Locale('en'));

      final after = AppPreferences(values);
      await after.load();
      expect(after.themeMode, ThemeMode.dark);
      expect(after.locale, const Locale('en'));

      await after.setLocale(null);
      final third = AppPreferences(values);
      await third.load();
      expect(third.locale, isNull);
    });

    testWidgets('the sign-in screen speaks Russian', (tester) async {
      await tester.pumpWidget(localized(
        LoginScreen(busy: false, onSubmit: (_) async {}),
      ));
      expect(find.text('Войти'), findsOneWidget);
      expect(find.text('Сервер'), findsOneWidget);
    });
  });

  testWidgets('the chat list renders in the dark theme', (tester) async {
    await tester.pumpWidget(localized(
      ChatListScreen(
        chats: const [],
        connection: SocketState.connecting,
        onOpenChat: (_) {},
      ),
      dark: true,
    ));
    expect(find.text('Чаты'), findsWidgets);
    expect(find.text('подключение…'), findsOneWidget);
    final context = tester.element(find.byType(ChatListScreen));
    expect(Theme.of(context).scaffoldBackgroundColor, PondColors.dark.pond);
  });
}
