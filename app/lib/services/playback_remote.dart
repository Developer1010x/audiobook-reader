import 'package:flutter/foundation.dart';

/// What a remote control (tray menu, media keys) can do to the open reader.
class PlaybackTarget {
  const PlaybackTarget({
    required this.title,
    required this.isPlaying,
    required this.togglePlay,
    required this.stop,
    required this.skip,
  });

  final String title;
  final bool Function() isPlaying;
  final Future<void> Function() togglePlay;
  final Future<void> Function() stop;

  /// Move by whole sentences: +1 next, -1 previous.
  final Future<void> Function(int sentences) skip;
}

/// The one place outside controls reach playback through.
///
/// Only one reader is open at a time, and it is the only thing that can
/// speak, so a single slot is enough. The reader claims it on open and
/// releases it on close; a remote with nothing claimed does nothing rather
/// than throwing. Listeners (the tray menu, MPRIS) repaint on every change.
class PlaybackRemote extends ChangeNotifier {
  PlaybackRemote._();
  static final instance = PlaybackRemote._();

  PlaybackTarget? _target;
  PlaybackTarget? get target => _target;

  bool get hasTarget => _target != null;
  bool get isPlaying => _target?.isPlaying() ?? false;
  String? get title => _target?.title;

  void claim(PlaybackTarget target) {
    _target = target;
    notifyListeners();
  }

  /// Release only if [target] still holds the slot: a reader closing after
  /// another opened must not unhook the new one.
  void release(PlaybackTarget target) {
    if (!identical(_target, target)) return;
    _target = null;
    notifyListeners();
  }

  /// Called by the reader whenever its play state changes.
  void changed() => notifyListeners();

  Future<void> togglePlay() async => _target?.togglePlay();
  Future<void> stop() async => _target?.stop();
  Future<void> skip(int sentences) async => _target?.skip(sentences);
}
