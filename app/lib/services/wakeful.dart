import 'dart:ffi';
import 'dart:io';

import 'runtime_env.dart';

// ── Windows: SetThreadExecutionState ──
//
// Windows has no inhibitor process to spawn, so the lock is a direct call into
// kernel32. Bound here by FFI rather than through a package: `win32` is only a
// transitive dependency of path_provider_windows, and depending on a package
// nobody declared is how a build breaks on an unrelated upgrade.
typedef _SetThreadExecutionStateC = Uint32 Function(Uint32 flags);
typedef _SetThreadExecutionStateDart = int Function(int flags);

/// Keep the flag in force until it is explicitly cleared, rather than resetting
/// it the moment this call returns.
const _esContinuous = 0x80000000;
const _esSystemRequired = 0x00000001;
const _esDisplayRequired = 0x00000002;

/// Keeps the screen awake while the app is reading aloud.
///
/// Not a nicety: a session that dims out mid-chapter looks like the app
/// crashed, and on desktop the screensaver can suspend audio outright.
///
/// Reference-counted, because more than one thing wants this at once — a
/// read-aloud session and Car Mode both hold it, and whichever ends first must
/// not release the other's claim.
///
/// Desktop only for now. Mobile needs the platform's own wakelock, which
/// arrives with the background-audio work: a foreground service on Android and
/// an audio session on iOS keep playback alive with the screen *off*, which is
/// the behaviour that actually matters there.
class Wakeful {
  static int _claims = 0;
  static Process? _inhibitor;

  static bool get isHeld => _claims > 0;

  /// Claim wakefulness. Balance every call with [release].
  static Future<void> acquire() async {
    _claims++;
    if (_claims > 1 || _inhibitor != null) return;

    if (Platform.isWindows) {
      _setWindowsState(
        _esContinuous | _esSystemRequired | _esDisplayRequired,
      );
      return;
    }

    // Linux and macOS both hold the lock for as long as a child process lives,
    // so the child is killed on release and nothing else tracks state. Only the
    // command differs.
    final List<String>? spawn = switch (Platform.operatingSystem) {
      'linux' => _linuxInhibitor(),
      // -d keeps the display awake, -i the system. caffeinate ships with macOS,
      // so unlike systemd-inhibit it is never missing.
      'macos' => _macInhibitor(),
      _ => null,
    };
    if (spawn == null) return;

    try {
      _inhibitor = await Process.start(spawn.first, spawn.sublist(1));
    } catch (_) {
      // A missing inhibitor is not worth failing playback over; the screen may
      // dim, but the book still reads.
      _inhibitor = null;
    }
  }

  static List<String>? _linuxInhibitor() {
    final inhibit = RuntimeEnv.findBinary('systemd-inhibit');
    if (inhibit == null) return null;
    return [
      inhibit,
      '--what=idle:sleep',
      '--who=Audier',
      '--why=Reading aloud',
      '--mode=block',
      'sleep',
      'infinity',
    ];
  }

  static List<String>? _macInhibitor() {
    final caffeinate = RuntimeEnv.findBinary('caffeinate') ?? '/usr/bin/caffeinate';
    // -w makes caffeinate exit on its own if this app dies without releasing,
    // so a crash cannot leave the Mac permanently awake.
    return [caffeinate, '-d', '-i', '-w', '$pid'];
  }

  /// Returns false when the call could not be made at all, which is not worth
  /// surfacing: the book still reads, the screen may just dim.
  static bool _setWindowsState(int flags) {
    try {
      final setState = DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_SetThreadExecutionStateC, _SetThreadExecutionStateDart>(
        'SetThreadExecutionState',
      );
      // A zero return means the call failed; anything else is the previous
      // state, which we do not need.
      return setState(flags) != 0;
    } catch (_) {
      return false;
    }
  }

  /// Drop one claim. The lock lifts only when the last holder releases.
  static Future<void> release() async {
    if (_claims == 0) return;
    _claims--;
    if (_claims > 0) return;
    _dropLock();
  }

  /// Drop every claim, for dispose paths that cannot know how many they hold.
  static Future<void> releaseAll() async {
    _claims = 0;
    _dropLock();
  }

  static void _dropLock() {
    if (Platform.isWindows) {
      // ES_CONTINUOUS on its own clears the display and system requirements
      // set in acquire(); there is no separate "release" call.
      _setWindowsState(_esContinuous);
      return;
    }
    final process = _inhibitor;
    _inhibitor = null;
    process?.kill();
  }
}
