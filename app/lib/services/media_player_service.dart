import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'runtime_env.dart';

/// Background audio while you read.
///
/// **Why this exists.** Speech synthesis is not always available or wanted — no
/// engine installed, a scanned book with no text, or simply preferring to read
/// with music. Rather than leaving the audio controls dead, the app can play
/// from a folder of your own files, or drive whatever media player is already
/// running on the desktop (Spotify, Rhythmbox, VLC, a browser) through MPRIS.
///
/// MPRIS is the standard D-Bus interface every Linux media player implements,
/// so controlling Spotify needs no Spotify account, API key, or integration —
/// just the player the user already has open.
class MediaPlayerService extends ChangeNotifier {
  static const _audioExtensions = {
    'mp3', 'm4a', 'aac', 'ogg', 'oga', 'opus', 'flac', 'wav', 'wma'
  };

  // ── local folder playback ──

  List<File> _playlist = [];
  int _index = 0;
  Process? _process;
  bool _playing = false;

  List<File> get playlist => List.unmodifiable(_playlist);
  bool get isPlaying => _playing;
  String? get nowPlaying =>
      _playlist.isEmpty ? null : p.basenameWithoutExtension(_playlist[_index].path);

  /// Whether anything can play audio files at all.
  static bool get canPlayFiles => _playerBinary != null;

  static String? get _playerBinary {
    for (final candidate in ['mpv', 'ffplay', 'paplay', 'pw-play', 'aplay']) {
      final path = RuntimeEnv.findBinary(candidate);
      if (path != null) return path;
    }
    return null;
  }

  /// Collect playable audio from [folder], recursively.
  Future<int> loadFolder(String folder) async {
    final dir = Directory(folder);
    if (!await dir.exists()) return 0;

    final found = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final ext = p.extension(entity.path).replaceFirst('.', '').toLowerCase();
      if (_audioExtensions.contains(ext)) found.add(entity);
    }
    found.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));

    _playlist = found;
    _index = 0;
    notifyListeners();
    return found.length;
  }

  Future<void> play() async {
    if (_playlist.isEmpty) return;
    await stop();

    final binary = _playerBinary;
    if (binary == null) {
      throw Exception(
        'No audio player found. Install one with:\n    sudo apt install mpv',
      );
    }

    final name = p.basename(binary);
    // Compressed formats need a real decoder; aplay only handles WAV.
    final args = switch (name) {
      'mpv' => ['--no-video', '--really-quiet', _playlist[_index].path],
      'ffplay' => [
          '-nodisp',
          '-autoexit',
          '-loglevel',
          'quiet',
          _playlist[_index].path
        ],
      _ => [_playlist[_index].path],
    };

    _process = await Process.start(binary, args);
    _playing = true;
    notifyListeners();

    final process = _process;
    unawaited(process!.exitCode.then((_) {
      if (!identical(_process, process)) return;
      _process = null;
      _playing = false;
      notifyListeners();
      // Roll on to the next track, so a folder plays as an album would.
      if (_index < _playlist.length - 1) {
        _index++;
        play();
      }
    }));
  }

  Future<void> stop() async {
    final process = _process;
    _process = null;
    process?.kill();
    _playing = false;
    notifyListeners();
  }

  Future<void> next() async {
    if (_playlist.isEmpty) return;
    _index = (_index + 1) % _playlist.length;
    if (_playing) await play();
    notifyListeners();
  }

  Future<void> previous() async {
    if (_playlist.isEmpty) return;
    _index = (_index - 1 + _playlist.length) % _playlist.length;
    if (_playing) await play();
    notifyListeners();
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }
}

/// Controls whatever media player is already running, over MPRIS.
///
/// Works with Spotify, Rhythmbox, VLC, Amarok, browsers playing YouTube — any
/// player implementing the standard. No account, key or per-app integration.
class MprisControl {
  static const _prefix = 'org.mpris.MediaPlayer2.';

  static String? get _busctl => RuntimeEnv.findBinary('busctl') ??
      RuntimeEnv.findBinary('dbus-send') ??
      RuntimeEnv.findBinary('playerctl');

  static bool get isAvailable => _busctl != null && Platform.isLinux;

  /// Media players currently running, by bus name suffix (e.g. `spotify`).
  static Future<List<String>> players() async {
    final playerctl = RuntimeEnv.findBinary('playerctl');
    if (playerctl != null) {
      try {
        final result = await Process.run(playerctl, ['-l']);
        if (result.exitCode == 0) {
          return (result.stdout as String)
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      } catch (_) {}
    }

    // Fall back to listing D-Bus names directly.
    final busctl = RuntimeEnv.findBinary('busctl');
    if (busctl == null) return const [];
    try {
      final result = await Process.run(busctl, ['--user', 'list', '--json=short']);
      if (result.exitCode != 0) return const [];
      final names = <String>{};
      for (final match
          in RegExp(r'org\.mpris\.MediaPlayer2\.([A-Za-z0-9_.-]+)')
              .allMatches(result.stdout as String)) {
        final name = match.group(1);
        if (name != null) names.add(name);
      }
      return names.toList()..sort();
    } catch (_) {
      return const [];
    }
  }

  static Future<String?> nowPlaying([String? player]) async {
    final playerctl = RuntimeEnv.findBinary('playerctl');
    if (playerctl == null) return null;
    try {
      final result = await Process.run(playerctl, [
        if (player != null) ...['-p', player],
        'metadata',
        '--format',
        '{{artist}} — {{title}}',
      ]);
      if (result.exitCode != 0) return null;
      final text = (result.stdout as String).trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _command(String action, String? player) async {
    final playerctl = RuntimeEnv.findBinary('playerctl');
    if (playerctl != null) {
      await Process.run(playerctl, [
        if (player != null) ...['-p', player],
        action,
      ]);
      return;
    }

    final busctl = RuntimeEnv.findBinary('busctl');
    if (busctl == null || player == null) return;
    final method = switch (action) {
      'play' => 'Play',
      'pause' => 'Pause',
      'play-pause' => 'PlayPause',
      'next' => 'Next',
      'previous' => 'Previous',
      _ => 'PlayPause',
    };
    await Process.run(busctl, [
      '--user',
      'call',
      '$_prefix$player',
      '/org/mpris/MediaPlayer2',
      'org.mpris.MediaPlayer2.Player',
      method,
    ]);
  }

  static Future<void> playPause([String? player]) => _command('play-pause', player);
  static Future<void> play([String? player]) => _command('play', player);
  static Future<void> pause([String? player]) => _command('pause', player);
  static Future<void> next([String? player]) => _command('next', player);
  static Future<void> previous([String? player]) => _command('previous', player);

  static String get installHint =>
      'Install playerctl to control Spotify and other players:\n'
      '    sudo apt install playerctl';
}
