import 'package:flutter/material.dart';

import 'app.dart';

void main() {
  // Platform channels (secure storage, sqflite) are touched during startup,
  // so the binding must exist before runApp.
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FrogsterApp());
}
