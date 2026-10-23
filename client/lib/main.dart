import 'package:flutter/material.dart';

import 'app.dart';
import 'data/local/database.dart';
import 'data/local/error_log.dart';
import 'ui/desktop/desktop_shell.dart';

Future<void> main() async {
  // Platform channels (secure storage, sqflite) are touched during startup,
  // so the binding must exist before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await ErrorLog.install(await AppDatabase.dataDirectory());
  } catch (_) {
    // Without a log the app still runs.
  }
  await DesktopShell.prepare();
  runApp(const FrogsterApp());
}
