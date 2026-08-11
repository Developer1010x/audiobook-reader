import 'dart:async';

import 'package:flutter/foundation.dart';

/// What ends the listening session.
enum SleepMode {
  /// Not armed.
  off,

  /// A fixed stretch of wall-clock time.
  duration,

  /// Stop once the page being read has been read out.
  endOfPage,

  /// Stop once the chapter being read has been read out.
  endOfChapter,
}

/// Where an armed timer is in its life.
///
/// [fading] is a phase of its own so the UI can say *why* the voice is getting
/// quieter, rather than looking like a machine going wrong.
enum SleepPhase { idle, running, fading, expired }

/// The sleep timer: stop reading aloud after a while, gently.
///
/// Pure Dart on purpose — [ChangeNotifier] is the only Flutter thing here, and
/// there is no widget, no `BuildContext`, no `SharedPreferences`. That is what
/// makes it testable in milliseconds with an injected clock, and what lets the
/// reader own one for the lifetime of its `State` (so it survives every widget
/// rebuild, and dies with the screen).
///
/// **Time is a deadline, not a countdown.** [remaining] is always derived from
/// a stored [DateTime], never accumulated tick by tick, so it cannot drift, it
/// survives an NTP step in either direction, and a laptop suspended for two
/// hours mid-book wakes up correctly expired — you were not listening.
///
/// **A paused book does not get sleepy.** [hold] freezes the deadline into a
/// remaining [Duration] and [resume] turns it back into a deadline. Fiddling
/// with the voice picker for five minutes must not cost five minutes of
/// listening, and a timer that fires while nothing is playing would silence a
/// book the user never started.
///
/// Nothing here stops anything. The timer reports — [onExpire], [hasExpired],
/// [fadeVolume] — and the reader decides what that means for its own engine.
class SleepTimer extends ChangeNotifier {
  /// [now] is injectable so tests never wait. Under `fakeAsync`, pass
  /// `() => clock.now()`: the periodic ticker and the clock then advance
  /// together and an hour of timer costs a microsecond of test.
  SleepTimer({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  SleepMode _mode = SleepMode.off;
  Duration? _total;

  /// When the session ends. Authoritative while a duration is running.
  DateTime? _deadline;

  /// What was left at the moment of a hold. Exactly one of this and [_deadline]
  /// is non-null while a duration is armed — holding converts between them.
  Duration? _held;

  bool _isHeld = false;
  bool _hasExpired = false;
  bool _disposed = false;

  int _fadeSeconds = 0;
  double _lastFadeVolume = 1.0;

  /// The last countdown text handed to listeners, so a repaint only happens
  /// when the *displayed* value actually changes.
  String? _lastDisplayKey;

  Timer? _ticker;

  /// Fired once, when the session ends. A one-shot callback rather than a
  /// listener because expiry is an event, not a state a widget renders.
  VoidCallback? onExpire;

  /// Fired as the fade progresses, with a volume in 0..1.
  ///
  /// Only when the value changes, so a backend that relaunches a player process
  /// per chunk is not asked to do so for a volume it is already at.
  void Function(double volume)? onFadeTick;

  // ── state ──

  SleepMode get mode => _mode;

  SleepPhase get phase {
    if (_hasExpired) return SleepPhase.expired;
    if (_mode == SleepMode.off) return SleepPhase.idle;
    if (fadeVolume < 1.0) return SleepPhase.fading;
    return SleepPhase.running;
  }

  /// What was chosen. Null for [SleepMode.endOfPage] and
  /// [SleepMode.endOfChapter], which have no knowable length.
  Duration? get total => _total;

  /// Never negative, never drifting. [Duration.zero] when there is no deadline
  /// to count down to — including the two end-of-section modes.
  Duration get remaining {
    if (_mode != SleepMode.duration) return Duration.zero;
    if (_held != null) return _held!;
    final deadline = _deadline;
    if (deadline == null) return Duration.zero;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get isArmed => _mode != SleepMode.off;

  /// The latch. Set once at expiry, read by the auto-advance handlers, cleared
  /// only by [clearExpiry].
  ///
  /// It has to be a latch rather than a moment because the moment is not
  /// enough: a page can finish speaking, an advance can be queued, and only
  /// *then* does the timer fire. Without something for that queued advance to
  /// check on its way through, the book carries on all night.
  bool get hasExpired => _hasExpired;

  /// True while the countdown is frozen — a manual pause, or Car Mode holding
  /// it so an expiry cannot silence the audio mid-drive for no visible reason.
  bool get isHeld => _isHeld;

  /// 1.0 outside the fade window, ramping to 0.0 at the deadline.
  ///
  /// A cliff-edge cut mid-chapter is a worse ending than a ramp, and the ramp
  /// is what tells a half-asleep listener the timer is doing its job rather
  /// than the audio having broken.
  double get fadeVolume {
    if (_fadeSeconds <= 0 || _mode != SleepMode.duration) return 1.0;
    if (_deadline == null) return 1.0; // held, or already spent
    final left = remaining.inMilliseconds;
    final window = _fadeSeconds * 1000;
    if (left >= window) return 1.0;
    return (left / window).clamp(0.0, 1.0);
  }

  int get fadeSeconds => _fadeSeconds;

  // ── commands ──

  /// Arm the timer, replacing whatever was running.
  ///
  /// Replacing, never adding: picking 30 minutes on a timer with 12 left gives
  /// 30, because that is what the user just asked for.
  ///
  /// [fadeSeconds] is clamped to [total] — a two-minute timer with a
  /// thirty-second fade is fine, a thirty-second timer with one would start the
  /// book already quiet.
  void arm(SleepMode mode, {Duration? total, int fadeSeconds = 30}) {
    if (_disposed) return;
    assert(mode != SleepMode.duration || total != null,
        'SleepMode.duration needs a total');

    if (mode == SleepMode.off ||
        (mode == SleepMode.duration && (total == null || total <= Duration.zero))) {
      cancel();
      return;
    }

    _liftFade();
    _hasExpired = false;
    _isHeld = false;
    _held = null;
    _mode = mode;

    if (mode == SleepMode.duration) {
      final length = total!;
      _total = length;
      _fadeSeconds = fadeSeconds.clamp(0, length.inSeconds);
      _deadline = _now().add(length);
      _startTicker();
    } else {
      // No lead time is knowable when the end is "whenever this page runs out",
      // so these modes stop cleanly instead of fading into it.
      _total = null;
      _fadeSeconds = 0;
      _deadline = null;
      _stopTicker();
    }

    _lastDisplayKey = _displayKey();
    _notify();
  }

  /// Push the ending back by [extra] without restarting it.
  ///
  /// Never fires [onExpire]; on a spent timer it re-arms from now, because
  /// "+10 minutes" on a timer that has just stopped the book can only sensibly
  /// mean ten more minutes.
  void extend(Duration extra) {
    if (_disposed || _mode == SleepMode.off || extra <= Duration.zero) return;
    if (_mode != SleepMode.duration) return; // nothing to move

    _liftFade();
    if (_hasExpired) {
      _hasExpired = false;
      _total = extra;
      _held = null;
      _isHeld = false;
      _deadline = _now().add(extra);
    } else if (_isHeld) {
      _held = (_held ?? Duration.zero) + extra;
      _total = (_total ?? Duration.zero) + extra;
    } else {
      _deadline = (_deadline ?? _now()).add(extra);
      _total = (_total ?? Duration.zero) + extra;
    }
    if (!_isHeld) _startTicker();
    _lastDisplayKey = _displayKey();
    _notify();
  }

  /// Freeze the countdown. Called on a manual pause, and while Car Mode is on.
  ///
  /// Idempotent: a second hold must not re-snapshot, or a held timer would
  /// silently gain the time it had already lost.
  void hold() {
    if (_disposed || _isHeld || _mode == SleepMode.off || _hasExpired) return;
    _isHeld = true;
    if (_mode == SleepMode.duration) {
      _held = remaining;
      _deadline = null;
    }
    _stopTicker();
    // Car Mode holds the timer while audio keeps playing, so a hold caught
    // mid-fade must give the listener their volume back — otherwise the book
    // stays quiet for as long as the hold lasts.
    _liftFade();
    _notify();
  }

  /// Unfreeze, from exactly where [hold] left off.
  void resume() {
    if (_disposed || !_isHeld) return;
    _isHeld = false;
    if (_mode == SleepMode.duration) {
      _deadline = _now().add(_held ?? Duration.zero);
      _held = null;
      _startTicker();
    }
    _lastDisplayKey = _displayKey();
    _notify();
  }

  /// Disarm completely.
  void cancel() {
    if (_disposed) return;
    final wasArmed = _mode != SleepMode.off || _hasExpired;
    _liftFade();
    _reset();
    if (wasArmed) _notify();
  }

  /// Clear the latch once speech starts again.
  ///
  /// Called from every start-of-speech path, and a no-op unless the timer has
  /// actually fired — which is why it can live in one funnel rather than being
  /// scattered across the play, skip and tap entry points.
  ///
  /// A spent timer is also disarmed here, not merely un-latched. It has done
  /// what it was asked to do; leaving it armed would stop the book again at the
  /// end of the very next page, and leave a 0:00 chip haunting the app bar.
  void clearExpiry() {
    if (_disposed || !_hasExpired) return;
    _reset();
    _notify();
  }

  /// Report that a page has been read out.
  ///
  /// The timer deliberately does not know what a chapter is: [isChapterEnd] is
  /// the caller's answer, recomputed from wherever the reader actually is. That
  /// is what makes [SleepMode.endOfChapter] re-target for free — skip into a
  /// new chapter with it armed and it means *that* chapter's end.
  ///
  /// Ignored while held, so a chapter ending mid-drive cannot silence Car Mode.
  void pageFinished({bool isChapterEnd = false}) {
    if (_disposed || _isHeld || _hasExpired) return;
    if (_mode == SleepMode.endOfPage ||
        (_mode == SleepMode.endOfChapter && isChapterEnd)) {
      _expire();
    }
  }

  /// Run one tick by hand, for tests that would rather not drive a clock.
  @visibleForTesting
  void tick() => _tick();

  // ── internals ──

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _tick() {
    if (_disposed) return;
    // Anything but a live countdown has nothing to tick for; stop burning a
    // wakeup a second on it.
    if (_mode != SleepMode.duration || _isHeld || _deadline == null || _hasExpired) {
      _stopTicker();
      return;
    }
    if (remaining <= Duration.zero) {
      _expire();
      return;
    }
    _emitFade();
    final key = _displayKey();
    if (key != _lastDisplayKey) {
      _lastDisplayKey = key;
      _notify();
    }
  }

  void _expire() {
    _hasExpired = true;
    _deadline = null;
    _held = null;
    _stopTicker();
    // Not lifted through [onFadeTick]: the reader restores full volume as part
    // of stopping, and unfading the last half-second first would be audible.
    _lastFadeVolume = 1.0;
    _lastDisplayKey = _displayKey();
    _notify();
    onExpire?.call();
  }

  /// Back to disarmed, without touching the fade callback or listeners.
  void _reset() {
    _mode = SleepMode.off;
    _total = null;
    _deadline = null;
    _held = null;
    _isHeld = false;
    _hasExpired = false;
    _fadeSeconds = 0;
    _stopTicker();
    _lastDisplayKey = null;
  }

  void _emitFade() {
    final volume = fadeVolume;
    if ((volume - _lastFadeVolume).abs() < 0.001) return;
    _lastFadeVolume = volume;
    onFadeTick?.call(volume);
  }

  /// Give the volume back if we are mid-fade. Every path out of a fade goes
  /// through here — the app is never left silently quiet.
  void _liftFade() {
    if (_lastFadeVolume >= 1.0) return;
    _lastFadeVolume = 1.0;
    onFadeTick?.call(1.0);
  }

  String _displayKey() => '${phase.name}|${formatRemaining(remaining)}';

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  /// The countdown text, and the granularity contract behind it: minutes until
  /// the last minute, seconds only inside it.
  ///
  /// A digit changing every second in the corner of the eye is motion carrying
  /// no information for 59 ticks out of 60 — so the timer notifies its
  /// listeners only when this string would change, which for most of its life
  /// is once a minute.
  static String formatRemaining(Duration left) {
    final seconds = left.isNegative ? 0 : left.inSeconds;
    if (seconds < 60) return '${seconds}s';
    return '${(seconds / 60).ceil()} min';
  }

  @override
  void dispose() {
    // The reader is gone. Cancelling the ticker stops the countdown; dropping
    // the callbacks stops anything still in flight from reaching a dead screen,
    // and _disposed keeps every public command a no-op from here on.
    _disposed = true;
    _stopTicker();
    onExpire = null;
    onFadeTick = null;
    super.dispose();
  }
}
