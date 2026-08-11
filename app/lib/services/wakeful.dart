import 'dart:io';

import 'runtime_env.dart';

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
    if (!Platform.isLinux) return;

    // systemd-inhibit holds the lock for as long as the child process lives,
    // so the child is a sleep that we kill on release. Nothing else needs to
    // track state.
    final inhibit = RuntimeEnv.findBinary('systemd-inhibit');
    if (inhibit == null) return;

    try {
      _inhibitor = await Process.start(inhibit, [
        '--what=idle:sleep',
        '--who=Audier',
        '--why=Reading aloud',
        '--mode=block',
        'sleep',
        'infinity',
      ]);
    } catch (_) {
      // A missing inhibitor is not worth failing playback over; the screen may
      // dim, but the book still reads.
      _inhibitor = null;
    }
  }

  /// Drop one claim. The lock lifts only when the last holder releases.
  static Future<void> release() async {
    if (_claims == 0) return;
    _claims--;
    if (_claims > 0) return;

    final process = _inhibitor;
    _inhibitor = null;
    process?.kill();
  }

  /// Drop every claim, for dispose paths that cannot know how many they hold.
  static Future<void> releaseAll() async {
    _claims = 0;
    final process = _inhibitor;
    _inhibitor = null;
    process?.kill();
  }
}
