import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;

import 'piper_tts.dart';
import 'runtime_env.dart';

/// Read-aloud. Uses the OS voice on every platform, so nothing is sent anywhere —
/// this is the layer a storybook uses, and it never touches an LLM.
///
/// **Linux needs its own path.** flutter_tts ships implementations for Android,
/// iOS, macOS, Windows and web, but *not* Linux — calling it there fails silently,
/// which looks exactly like a broken Play button. On Linux we drive
/// speech-dispatcher (`spd-say`) directly instead.
class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();

  /// The spd-say process currently speaking, on Linux only.
  Process? _linuxProcess;

  bool _speaking = false;
  bool _paused = false;
  bool _preparing = false;
  double _rate = 0.5;

  /// Piper voice name; null means the first installed voice.
  String? _voice;

  /// Piper is preferred when installed, but can be turned off to fall back to
  /// the faster, worse system voice.
  bool _preferPiper = true;

  /// Bumped on every speak/stop, so a superseded chunk pipeline exits quietly.
  int _session = 0;

  bool get isSpeaking => _speaking;
  bool get isPaused => _paused;

  /// True while Piper is synthesising and no audio is playing yet.
  bool get isPreparing => _preparing;

  /// Which engine will actually be used, for display in the UI.
  static String get engineName {
    if (!_usesLinuxBackend) return 'System voice';
    return PiperTts.isAvailable ? 'Piper (neural)' : 'espeak-ng (robotic)';
  }

  List<String> get availableVoices => PiperTts.isAvailable ? PiperTts.voices : const [];

  String? get voice => _voice;
  set voice(String? value) {
    _voice = value;
    notifyListeners();
  }

  bool get usingPiper => _usesLinuxBackend && PiperTts.isAvailable && _preferPiper;
  set preferPiper(bool value) {
    _preferPiper = value;
    notifyListeners();
  }
  double get rate => _rate;

  static bool get _usesLinuxBackend => Platform.isLinux;

  /// Whether speech can work at all here. The UI disables Play rather than
  /// offering a button that does nothing.
  static Future<bool> isAvailable() async {
    if (!_usesLinuxBackend) return true;
    return PiperTts.isAvailable || RuntimeEnv.findBinary('spd-say') != null;
  }

  /// Human-readable reason speech is unavailable, for the UI to show.
  static String get unavailableMessage =>
      'No speech engine found. Install one with:\n'
      '    sudo apt install speech-dispatcher speech-dispatcher-espeak-ng';

  /// Fires when a chunk finishes, so the reader can turn the page and continue.
  VoidCallback? onPageFinished;

  TtsService() {
    if (!_usesLinuxBackend) {
      _tts.setCompletionHandler(() {
        _speaking = false;
        _paused = false;
        notifyListeners();
        onPageFinished?.call();
      });
      _tts.setCancelHandler(_reset);
      _tts.setErrorHandler((msg) => _reset());
    }
  }

  void _reset() {
    _speaking = false;
    _paused = false;
    notifyListeners();
  }

  static String? _which(String binary) {
    try {
      final result = Process.runSync('which', [binary]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  /// Called with the index of the segment now being spoken, so the UI can
  /// highlight it. Null when speech stops.
  void Function(int? index)? onSegment;

  Future<void> speak(String text) async {
    final clean = _clean(text);
    if (clean.isEmpty) return;

    if (_usesLinuxBackend) {
      await _speakLinux(clean);
      return;
    }
    await _tts.setSpeechRate(_rate);
    await _tts.speak(clean);
    _speaking = true;
    _paused = false;
    notifyListeners();
  }

  /// Speak an explicit list of segments, reporting which one is playing.
  ///
  /// This is what lets the reader follow along on the page: the caller owns the
  /// split (so it knows each segment's position), and gets told when each one
  /// starts.
  Future<void> speakSegments(List<String> segments) async {
    if (segments.isEmpty) return;
    if (_usesLinuxBackend && PiperTts.isAvailable && _preferPiper) {
      await stop();
      await _speakPiper(segments.map(_clean).where((s) => s.isNotEmpty).toList());
      return;
    }
    // Engines without per-segment control still speak, just without follow-along.
    onSegment?.call(0);
    await speak(segments.join(' '));
  }

  Future<void> _speakLinux(String text) async {
    await stop();
    if (PiperTts.isAvailable && _preferPiper) {
      await _speakPiper(_chunk(text));
      return;
    }
    // spd-say rate is -100..100; the app's 0.1..1.0 maps onto it with 0.5 as normal.
    final rate = ((_rate - 0.5) * 200).round().clamp(-100, 100);
    try {
      // -w waits for completion, so awaiting exitCode tells us when the page
      // finished and the reader can advance to the next one.
      final spd = RuntimeEnv.findBinary('spd-say');
      if (spd == null) throw Exception(unavailableMessage);
      _linuxProcess = await Process.start(spd, ['-w', '-r', '$rate', '--', text]);
    } catch (e) {
      _reset();
      throw Exception(unavailableMessage);
    }
    _speaking = true;
    _paused = false;
    notifyListeners();

    final process = _linuxProcess;
    unawaited(process!.exitCode.then((_) {
      // Only fire completion if this process was not superseded by a newer one.
      if (!identical(_linuxProcess, process)) return;
      _linuxProcess = null;
      _speaking = false;
      _paused = false;
      notifyListeners();
      onPageFinished?.call();
    }));
  }

  /// Speak with Piper, chunk by chunk.
  ///
  /// Synthesising a whole page takes ~10 seconds, which would mean staring at a
  /// spinner before any sound. Instead the text is split into sentence-sized
  /// chunks: the first is synthesised and played immediately, and each later
  /// chunk is synthesised *while the previous one plays*, so audio starts in
  /// about a second and never gaps.
  Future<void> _speakPiper(List<String> chunks) async {
    final session = ++_session;
    _preparing = true;
    _speaking = true;
    notifyListeners();

    final voice = _voice ?? PiperTts.voices.first;
    if (chunks.isEmpty) {
      _preparing = false;
      _reset();
      return;
    }

    Future<File?> synth(int index) async {
      if (index >= chunks.length) return null;
      final out = p.join(
        Directory.systemTemp.path,
        'audiobook_reader_tts_${session}_$index.wav',
      );
      try {
        return await PiperTts.synthesise(
          chunks[index],
          voice: voice,
          rate: _rate,
          outPath: out,
        );
      } catch (_) {
        return null; // a failed chunk is skipped rather than killing playback
      }
    }

    try {
      var pending = synth(0);
      for (var i = 0; i < chunks.length; i++) {
        final audio = await pending;
        // Stopped, or a newer speak() superseded this one.
        if (session != _session) {
          if (audio != null) _cleanup(audio);
          return;
        }
        // Start the next chunk rendering while this one plays.
        pending = synth(i + 1);

        if (audio == null) continue;
        if (i == 0) {
          _preparing = false;
          notifyListeners();
        }
        onSegment?.call(i); // drives the on-page highlight
        await _play(audio, session);
        if (session != _session) return;
      }
    } finally {
      if (session == _session) {
        _linuxProcess = null;
        _speaking = false;
        _paused = false;
        _preparing = false;
        onSegment?.call(null);
        notifyListeners();
        onPageFinished?.call();
      }
    }
  }

  /// Play one file and wait for it to finish.
  Future<void> _play(File audio, int session) async {
    final player = PiperTts.player!;
    final process = await Process.start(
      player,
      PiperTts.playerArgs(player, audio.path),
    );
    _linuxProcess = process;
    await process.exitCode;
    _cleanup(audio);
  }

  /// Split into chunks that end on sentence boundaries where possible, so the
  /// voice does not break mid-clause. Roughly [_chunkChars] each.
  static const _chunkChars = 350;

  static List<String> _chunk(String text) {
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final chunks = <String>[];
    final buffer = StringBuffer();

    for (final sentence in sentences) {
      if (buffer.isNotEmpty && buffer.length + sentence.length > _chunkChars) {
        chunks.add(buffer.toString().trim());
        buffer.clear();
      }
      // A single sentence longer than a chunk is kept whole — splitting it
      // would sound worse than a slightly long chunk.
      buffer.write(buffer.isEmpty ? sentence : ' $sentence');
    }
    if (buffer.toString().trim().isNotEmpty) chunks.add(buffer.toString().trim());
    return chunks.where((c) => c.isNotEmpty).toList();
  }

  void _cleanup(File audio) {
    try {
      if (audio.existsSync()) audio.deleteSync();
    } catch (_) {}
  }

  Future<void> pause() async {
    if (_usesLinuxBackend) {
      // speech-dispatcher has no reliable per-process pause; stopping is honest.
      await stop();
      return;
    }
    await _tts.pause();
    _paused = true;
    notifyListeners();
  }

  Future<void> stop() async {
    if (_usesLinuxBackend) {
      _session++; // invalidates any in-flight Piper chunk pipeline
      onSegment?.call(null);
      final process = _linuxProcess;
      _linuxProcess = null; // clear first, so the exit handler stays quiet
      process?.kill();
      try {
        final spd = RuntimeEnv.findBinary('spd-say');
        if (spd != null) await Process.run(spd, ['-C']); // cancel queued speech
      } catch (_) {}
      _reset();
      return;
    }
    await _tts.stop();
    _reset();
  }

  Future<void> setRate(double value) async {
    _rate = value.clamp(0.1, 1.0);
    if (!_usesLinuxBackend) await _tts.setSpeechRate(_rate);
    notifyListeners();
  }

  /// PDF text extraction leaves artefacts that sound wrong when spoken: hard line
  /// wraps mid-sentence, hyphenated breaks, page numbers stranded on their own line.
  static String _clean(String text) {
    return text
        .replaceAll(RegExp(r'-\n\s*'), '') // re-join hyphenated line breaks
        .replaceAll(RegExp(r'\n{2,}'), '. ') // paragraph break -> sentence pause
        .replaceAll(RegExp(r'(?<![.!?:])\n'), ' ') // soft wrap -> space
        .replaceAll(RegExp(r'^\s*\d+\s*$', multiLine: true), '') // lone page numbers
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  @override
  void dispose() {
    _linuxProcess?.kill();
    if (!_usesLinuxBackend) _tts.stop();
    super.dispose();
  }
}
