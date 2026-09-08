import 'dart:io';

import 'package:path/path.dart' as p;

/// Where the app is running, and where its helper binaries actually live.
///
/// **Why this exists.** The app drives Piper, Tesseract and speech-dispatcher as
/// subprocesses. That is fine for a normal desktop install, but a Snap or
/// Flatpak build is confined: `/usr/bin/tesseract` on the host is invisible from
/// inside the sandbox. Packaged builds therefore *bundle* those binaries, and
/// every lookup must prefer the bundled copy before falling back to the host.
///
/// Getting this wrong does not crash — it silently reports "OCR not installed"
/// on a machine where OCR was shipped inside the package.
class RuntimeEnv {
  static String? _snap;
  static bool? _flatpak;
  static bool _resolved = false;

  static void _resolve() {
    if (_resolved) return;
    _resolved = true;
    final env = Platform.environment;

    // `$SNAP` being set does NOT mean *this* app is a snap — it is inherited
    // from whatever launched us. A snap-installed Flutter SDK sets it for every
    // `flutter run` and `flutter test`, which would make a plain desktop build
    // believe it was confined and stop finding host binaries entirely.
    //
    // The reliable test is whether our own executable lives inside that snap.
    final snap = env['SNAP'];
    if (snap != null && snap.isNotEmpty) {
      final exe = Platform.resolvedExecutable;
      if (p.isWithin(snap, exe) || exe == snap) _snap = snap;
    }

    // Flatpak's marker file is only present inside the sandbox, so it is safe
    // on its own.
    _flatpak = File('/.flatpak-info').existsSync();
  }

  /// `$SNAP` root when running as a snap, else null.
  static String? get snapRoot {
    _resolve();
    return (_snap != null && _snap!.isNotEmpty) ? _snap : null;
  }

  static bool get isSnap => snapRoot != null;

  static bool get isFlatpak {
    _resolve();
    return _flatpak ?? false;
  }

  /// True when host binaries and host services are not directly reachable.
  static bool get isSandboxed => isSnap || isFlatpak;

  static String get packagingLabel {
    if (isSnap) return 'Snap';
    if (isFlatpak) return 'Flatpak';
    return 'native';
  }

  /// The user's home directory, whatever the platform calls it.
  ///
  /// `$HOME` is not set on Windows, so a lookup written against it silently
  /// resolves to `''` there and every `~/...` candidate collapses to a relative
  /// path that never matches. That failure is invisible: the app simply reports
  /// the helper as "not installed" on a machine where it is.
  static String get homeDir =>
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';

  /// The per-user application data directory helpers install themselves into.
  ///
  /// Each desktop has its own convention, and a tool installed by its own
  /// installer lands in the platform's spot rather than a shared one.
  static String get appDataDir {
    final home = homeDir;
    if (home.isEmpty) return '';
    if (Platform.isWindows) {
      return Platform.environment['LOCALAPPDATA'] ??
          p.join(home, 'AppData', 'Local');
    }
    if (Platform.isMacOS) return p.join(home, 'Library', 'Application Support');
    return Platform.environment['XDG_DATA_HOME'] ??
        p.join(home, '.local', 'share');
  }

  /// Executable name for [binary] on this platform.
  ///
  /// Windows will not run an extensionless file, so every candidate path and
  /// every `where` lookup needs the suffix.
  static String exeName(String binary) =>
      Platform.isWindows && !binary.endsWith('.exe') ? '$binary.exe' : binary;

  /// Directories searched for bundled helper binaries, in priority order.
  static List<String> get bundledBinDirs {
    final snap = snapRoot;
    return [
      if (snap != null) ...[
        p.join(snap, 'usr', 'bin'),
        p.join(snap, 'bin'),
      ],
      if (isFlatpak) '/app/bin',
      // A portable/AppImage layout keeps helpers beside the executable.
      p.join(p.dirname(Platform.resolvedExecutable), 'bin'),
    ];
  }

  /// Find [binary], preferring a bundled copy over anything on the host.
  ///
  /// Returns an absolute path, or null when it genuinely is not available.
  static String? findBinary(String binary) {
    final exe = exeName(binary);
    for (final dir in bundledBinDirs) {
      final candidate = p.join(dir, exe);
      if (File(candidate).existsSync()) return candidate;
    }
    // A confined build cannot execute host binaries, so do not pretend it can.
    if (isSandboxed) return null;
    return _which(exe);
  }

  static String? _which(String binary) {
    try {
      final result = Process.runSync(
        Platform.isWindows ? 'where' : 'which',
        [binary],
      );
      if (result.exitCode != 0) return null;
      final out = (result.stdout as String).trim().split('\n').first.trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  /// Read-only data shipped with the package (Piper voices, tessdata).
  static List<String> get bundledDataDirs {
    final snap = snapRoot;
    return [
      if (snap != null) p.join(snap, 'usr', 'share'),
      if (isFlatpak) '/app/share',
      p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets'),
    ];
  }

  /// Instructions must match how the app was installed — telling a Flatpak user
  /// to run `apt install` is useless.
  static String installHint(String what) {
    if (isFlatpak) {
      return '$what is missing from this Flatpak build. '
          'Reinstall from Flathub, or use a cloud provider instead.';
    }
    if (isSnap) {
      return '$what is missing from this Snap build. '
          'Try `snap refresh audiobook-reader`, or use a cloud provider.';
    }
    return '';
  }
}
