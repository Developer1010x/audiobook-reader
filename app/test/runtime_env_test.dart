import 'dart:io';

import 'package:audiobook_reader/services/runtime_env.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the packaging detection.
///
/// The bug these exist for: `$SNAP` is inherited from whatever launched the
/// process. A snap-installed Flutter SDK sets it for every `flutter test`, so
/// naive detection made an ordinary desktop build believe it was confined —
/// and confined builds refuse to look for host binaries at all, silently
/// disabling OCR and speech.
void main() {
  test('does not mistake an inherited \$SNAP for our own confinement', () {
    final inherited = Platform.environment['SNAP'];
    if (inherited == null || inherited.isEmpty) return; // nothing to prove here

    final exeInsideSnap = Platform.resolvedExecutable.startsWith(inherited);
    expect(RuntimeEnv.isSnap, exeInsideSnap,
        reason: 'confinement must be decided by where our executable lives, '
            'not by an inherited environment variable');
  });

  test('an unconfined build still searches the host for binaries', () {
    if (RuntimeEnv.isSandboxed) return;
    // `sh` exists on every Linux/macOS machine; if lookup were broken this
    // would return null and every engine would report "not installed".
    expect(RuntimeEnv.findBinary('sh'), isNotNull);
  });

  test('reports a human-readable packaging label', () {
    expect(
      RuntimeEnv.packagingLabel,
      anyOf('native', 'Snap', 'Flatpak'),
    );
  });

  test('bundled binary directories are searched before the host', () {
    // Order matters: a bundled copy must win, or a packaged build would run
    // whatever happens to be on the host PATH.
    final dirs = RuntimeEnv.bundledBinDirs;
    expect(dirs, isNotEmpty);
  });

  test('install hints match how the app was actually installed', () {
    final hint = RuntimeEnv.installHint('Tesseract');
    if (RuntimeEnv.isSnap) {
      expect(hint, contains('snap'));
    } else if (RuntimeEnv.isFlatpak) {
      expect(hint, contains('Flatpak'));
    } else {
      // A native build gives no packaged hint; the caller falls back to apt.
      expect(hint, isEmpty);
    }
  });
}
