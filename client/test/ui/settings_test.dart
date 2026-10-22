import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frogster/data/local/account_store.dart';
import 'package:frogster/data/local/preferences.dart';
import 'package:frogster/data/models/models.dart';
import 'package:frogster/data/remote/api_client.dart';
import 'package:frogster/features/settings/view/settings_screen.dart';

import 'design_test.dart' show localized;

const _account = Account(userId: 'u', username: 'kvak', deviceId: 'd');

Widget _settings({
  Future<UserProfile> Function(String, String)? save,
  Future<void> Function(String, String)? changePassword,
  Future<void> Function(String)? deleteAccount,
}) =>
    localized(SettingsScreen(
      account: _account,
      server: 'chat.example.com',
      preferences: AppPreferences(MemorySecureValues()),
      sessions: const [],
      onRevokeSession: (_) {},
      onSignOut: ({required bool forget}) {},
      appVersion: '9.9.9',
      loadProfile: () async =>
          const UserProfile(userId: 'u', username: 'kvak', displayName: 'Квакша', bio: 'живу в пруду'),
      onSaveProfile: save,
      onChangePassword: changePassword,
      onDeleteAccount: deleteAccount,
    ));

void main() {
  testWidgets('the profile shows the name contacts see, and edits it', (tester) async {
    (String, String)? saved;
    await tester.pumpWidget(_settings(save: (name, bio) async {
      saved = (name, bio);
      return UserProfile(userId: 'u', username: 'kvak', displayName: name, bio: bio);
    }));
    await tester.pumpAndSettle();
    expect(find.text('Квакша'), findsOneWidget);
    expect(find.text('@kvak'), findsOneWidget);
    expect(find.text('живу в пруду'), findsOneWidget);

    await tester.tap(find.byTooltip('Изменить профиль'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Имя'), '  Жаба  ');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(saved?.$1, 'Жаба');
    expect(find.text('Жаба'), findsOneWidget);
  });

  testWidgets('a password change needs the new one twice', (tester) async {
    var called = false;
    await tester.pumpWidget(_settings(changePassword: (_, _) async => called = true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Сменить пароль'), 200);
    await tester.tap(find.text('Сменить пароль'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'old password!');
    await tester.enterText(fields.at(1), 'new password 1');
    await tester.enterText(fields.at(2), 'new password 2');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();

    expect(find.text('Пароли не совпадают'), findsOneWidget);
    expect(called, isFalse);
  });

  testWidgets('a wrong password does not delete the account, and says so', (tester) async {
    await tester.pumpWidget(_settings(
      deleteAccount: (_) async => throw const ApiException(403, 'password is incorrect'),
    ));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Удалить аккаунт'), 200);
    await tester.tap(find.text('Удалить аккаунт'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.text('Удалить навсегда'));
    await tester.pumpAndSettle();
    expect(find.text('Текущий пароль неверный'), findsOneWidget);
  });

  testWidgets('about shows the version', (tester) async {
    await tester.pumpWidget(_settings());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Версия 9.9.9'), 200);
    expect(find.text('Версия 9.9.9'), findsOneWidget);
  });
}
