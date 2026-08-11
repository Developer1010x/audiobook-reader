import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;

import 'concurrency.dart';
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

  /// How many chunks are rendered *ahead* of the one currently playing.
  ///
  /// Rendering a single chunk ahead is enough only while synthesis is faster
  /// than playback; a long sentence, a larger voice model or a busy machine
  /// tips that over and the gap between chunks is audible. Two absorbs the
  /// wobble. Much more would burn CPU and disk on audio nobody hears when the
  /// user stops after the first sentence.
  static const defaultLookAhead = 2;

  int _lookAhead = defaultLookAhead;

  int get lookAhead => _lookAhead;
  set lookAhead(int value) => _lookAhead = value.clamp(1, 4);

  /// Piper spends a whole core per process, so synthesis is capped far below
  /// the CPU pool: the point of rendering ahead is unbroken audio, not a busy
  /// machine behind a page that has stopped scrolling smoothly.
  late final _SynthGate _synthGate = _SynthGate(min(2, Concurrency.cpuPool));

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
  /// chunks and a small window of them is kept rendering ahead of the chunk
  /// being played ([lookAhead] deep, at most [_SynthGate.limit] processes at a
  /// time), so audio starts in about a second and a slow chunk has a head start
  /// rather than a gap.
  ///
  /// Playback itself stays strictly sequential: the window only decides *when*
  /// a chunk is rendered, never the order it is heard in.
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
      if (session != _session) return null;
      await _synthGate.acquire();
      try {
        // Checked again after queueing: a chunk that was superseded while it
        // waited for a slot must not cost a core, nor leave a file behind.
        if (session != _session) return null;
        // The pid keeps two running copies of the app off each other's audio —
        // the session counter alone restarts at zero in every process.
        return await PiperTts.synthesise(
          chunks[index],
          voice: voice,
          rate: _rate,
          outPath: p.join(
            Directory.systemTemp.path,
            'audiobook_reader_tts_${pid}_${session}_$index.wav',
          ),
        );
      } catch (_) {
        return null; // a failed chunk is skipped rather than killing playback
      } finally {
        _synthGate.release();
      }
    }

    // Chunks rendering ahead of the playhead, keyed by index so playback can
    // claim exactly the one it needs next.
    final rendering = <int, Future<File?>>{};
    void schedule(int index) {
      if (index >= chunks.length) return;
      rendering.putIfAbsent(index, () => synth(index));
    }

    try {
      for (var i = 0; i <= _lookAhead; i++) {
        schedule(i);
      }

      var started = false;
      for (var i = 0; i < chunks.length; i++) {
        final audio = await (rendering.remove(i) ?? synth(i));
        // Stopped, or a newer speak() superseded this one.
        if (session != _session) {
          if (audio != null) _cleanup(audio);
          return;
        }
        // Top the window back up, so rendering continues under this playback.
        schedule(i + _lookAhead + 1);

        if (audio == null) continue;
        if (!started) {
          started = true;
          _preparing = false;
          notifyListeners();
        }
        onSegment?.call(i); // drives the on-page highlight
        await _play(audio, session);
        if (session != _session) return;
      }
    } finally {
      // Everything left in the window sits ahead of the playhead and will never
      // be heard. Its files are already on disk, or about to be, so they have to
      // be chased down on every exit — stop, supersede or throw alike.
      _discardRendered(rendering.values.toList());
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

  /// Delete look-ahead audio that was abandoned before it could be played.
  ///
  /// Deliberately not awaited: a Piper process already running cannot be
  /// hurried, and stop() has to feel instant. Each delete happens as its render
  /// settles, long after the caller has moved on.
  void _discardRendered(Iterable<Future<File?>> rendering) {
    for (final render in rendering) {
      unawaited(render.then(
        (audio) {
          if (audio != null) _cleanup(audio);
        },
        onError: (_) {},
      ));
    }
  }

  /// Play one file and wait for it to finish.
  Future<void> _play(File audio, int session) async {
    try {
      final player = PiperTts.player!;
      final process = await Process.start(
        player,
        PiperTts.playerArgs(player, audio.path),
      );
      _linuxProcess = process;
      await process.exitCode;
    } finally {
      // The file goes whether or not the player ever started. This chunk is the
      // one path _discardRendered cannot cover — it was claimed out of the
      // window before playing — so a missing or broken audio tool would
      // otherwise strand one WAV in /tmp per chunk.
      _cleanup(audio);
    }
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
      // That pipeline will not clear the spinner itself: its finally only
      // restores state for the *current* session. Stopping while the first
      // chunk is still rendering would otherwise leave "preparing" up for good,
      // and the Play button stuck as a spinner. Cleared here, synchronously
      // with the session bump, so a speak() racing this stop cannot have its
      // own spinner cleared by us afterwards.
      _preparing = false;
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
    // Killing the player only ends the chunk being heard. Without invalidating
    // the session the Piper loop carries straight on to the next look-ahead
    // render — speaking after the screen is gone, and finally calling
    // notifyListeners() on a disposed notifier. Bumping the session is the same
    // signal stop() uses, so the pipeline exits through its own cleanup and its
    // unplayed renders are discarded.
    _session++;
    _preparing = false;
    _linuxProcess?.kill();
    _linuxProcess = null;
    if (!_usesLinuxBackend) _tts.stop();
    super.dispose();
  }
}

/// A counting semaphore over Piper processes.
///
/// The look-ahead window would otherwise launch every queued chunk at once, and
/// three synthesisers running against a two-core machine make the page stutter
/// under the very audio they were meant to smooth out.
class _SynthGate {
  _SynthGate(this.limit);

  final int limit;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_active < limit) {
      _active++;
      return Future<void>.value();
    }
    final slot = Completer<void>();
    _waiting.add(slot);
    return slot.future;
  }

  /// A freed slot is handed straight to the longest waiter, keeping the queue
  /// first-come — the playhead's own chunk is always the first one queued.
  void release() {
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }
    _active--;
  }
}
