/// Windows: closing the window keeps Frogster running in the tray, so
/// messages still arrive and notify, as a messenger is expected to.
library;

import 'dart:async';
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

class DesktopShell with WindowListener, TrayListener {
  DesktopShell._();

  static final instance = DesktopShell._();

  static bool get supported => Platform.isWindows;

  var _ready = false;
  var _quitting = false;

  /// Run before the first frame: from here on, the close button hides the
  /// window instead of ending the app.
  static Future<void> prepare() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
  }

  /// Puts the icon in the tray, with its menu in the user's language. Safe
  /// to call again when the language changes.
  Future<void> attach({required String openLabel, required String quitLabel}) async {
    if (!supported) return;
    try {
      if (!_ready) {
        windowManager.addListener(this);
        trayManager.addListener(this);
        await trayManager.setIcon('assets/icon/tray.ico');
        await trayManager.setToolTip('Frogster');
        _ready = true;
      }
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: openLabel),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: quitLabel),
      ]));
    } catch (e) {
      // Without a tray the app still works; closing then simply hides it
      // would be a trap, so let the close button close again.
      // ignore: avoid_print
      print('[frogster] tray unavailable: $e');
      await windowManager.setPreventClose(false);
    }
  }

  /// Whether the user is looking at the app right now.
  Future<bool> isInFront() async {
    if (!supported) return true;
    return await windowManager.isVisible() &&
        !await windowManager.isMinimized() &&
        await windowManager.isFocused();
  }

  Future<void> bringToFront() async {
    if (!supported) return;
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    _quitting = true;
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    unawaited(windowManager.hide());
  }

  @override
  void onTrayIconMouseDown() => unawaited(bringToFront());

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        unawaited(bringToFront());
      case 'quit':
        unawaited(quit());
    }
  }
}
