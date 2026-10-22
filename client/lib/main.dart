import 'package:flutter/material.dart';

import 'app.dart';
import 'ui/desktop/desktop_shell.dart';

Future<void> main() async {
  // Platform channels (secure storage, sqflite) are touched during startup,
  // so the binding must exist before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  await DesktopShell.prepare();
  runApp(const FrogsterApp());
}
