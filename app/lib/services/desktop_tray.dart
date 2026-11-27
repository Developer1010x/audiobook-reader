import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'playback_remote.dart';

/// A tray icon whose menu drives the open reader: play/pause and sentence
/// skips without bringing the window forward.
///
/// Everything goes through [PlaybackRemote], so the tray never holds a
/// reference to a screen that may already be gone.
class DesktopTray with TrayListener {
  DesktopTray._();
  static final _instance = DesktopTray._();

  static bool get supported =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Show the icon. Never throws: a desktop without a tray (GNOME without the
  /// AppIndicator extension, for one) must still run the app.
  static Future<void> start() async {
    if (!supported) return;
    try {
      // Windows wants an .ico; macOS and Linux a PNG.
      await trayManager.setIcon(
          Platform.isWindows ? 'assets/tray/tray.ico' : 'assets/tray/tray.png');
      if (!Platform.isLinux) await trayManager.setToolTip('Audier');
      trayManager.addListener(_instance);
      PlaybackRemote.instance.addListener(_instance._rebuild);
      await _instance._rebuild();
    } catch (e) {
      debugPrint('Tray unavailable: $e');
    }
  }

  bool? _lastPlaying;
  String? _lastTitle;
  bool _built = false;

  /// The menu for the current state, as plain data so it can be tested
  /// without a tray.
  static List<({String key, String label, bool enabled})> menuFor(
      PlaybackRemote remote) {
    final has = remote.hasTarget;
    return [
      (key: 'title', label: remote.title ?? 'No book open', enabled: false),
      (key: 'toggle', label: remote.isPlaying ? 'Pause' : 'Play', enabled: has),
      (key: 'previous', label: 'Previous sentence', enabled: has),
      (key: 'next', label: 'Next sentence', enabled: has),
      (key: 'stop', label: 'Stop', enabled: has && remote.isPlaying),
    ];
  }

  Future<void> _rebuild() async {
    final remote = PlaybackRemote.instance;
    // PlaybackRemote fires on every TTS tick (each sentence); only a change in
    // what the menu shows is worth a round trip to the native side.
    if (_built &&
        _lastPlaying == remote.isPlaying &&
        _lastTitle == remote.title) {
      return;
    }
    _built = true;
    _lastPlaying = remote.isPlaying;
    _lastTitle = remote.title;
    final items = menuFor(remote);
    await trayManager.setContextMenu(Menu(items: [
      for (final (i, item) in items.indexed) ...[
        MenuItem(key: item.key, label: item.label, disabled: !item.enabled),
        if (i == 0) MenuItem.separator(),
      ],
    ]));
  }

  @override
  void onTrayIconMouseDown() {
    // Linux's AppIndicator opens the menu itself; elsewhere a click would do
    // nothing unless asked to.
    if (!Platform.isLinux) unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayIconRightMouseDown() => onTrayIconMouseDown();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    final remote = PlaybackRemote.instance;
    switch (menuItem.key) {
      case 'toggle':
        unawaited(remote.togglePlay());
      case 'previous':
        unawaited(remote.skip(-1));
      case 'next':
        unawaited(remote.skip(1));
      case 'stop':
        unawaited(remote.stop());
    }
  }
}
