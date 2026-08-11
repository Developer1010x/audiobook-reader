/// The synthesis half of [SpeechPipeline]: sentences in, audio files out, a
/// little way ahead of the playhead and never further.
///
/// **Which implementation serves which platform.** Nothing here decides the
/// platform split on its own — [SpeechBackend.forPlatform] owns that — but a
/// synthesiser is the piece that physically cannot exist on some of them, so
/// the table is repeated where the code is:
///
///   | implementation             | serves                | why not elsewhere |
///   |----------------------------|-----------------------|-------------------|
///   | [PiperSynthesiser]         | linux, macos          | it is a subprocess, so it cannot exist inside the iOS or Android sandbox. Windows is *nominally* possible but [PiperTts] only looks in `$HOME/.local/...`, so it honestly reports unavailable there rather than pretending. |
///   | [FlutterTtsSynthesiser]    | android, ios, macos   | flutter_tts has no Linux implementation and fails *silently* there; its Windows implementation has no `synthesizeToFile` method at all (verified: `windows/` in flutter_tts 4.2.5 contains no such handler), so a Windows render would throw `MissingPluginException` on every sentence. |
///   | [UnavailableSynthesiser]   | everything else       | the honest null object: [SpeechSynthesiser.isAvailable] is false and [SpeechSynthesiser.render] throws, so the UI disables Play instead of offering a button that does nothing. |
///
/// On a platform with neither real engine — Linux without Piper installed,
/// Windows, web — [FileSynthesisers.forPlatform] still returns a synthesiser
/// rather than null, and it answers `isAvailable() == false` with an
/// [SpeechSynthesiser.unavailableMessage] the user can act on. Callers never
/// have to null-check, and no code path silently does nothing.
///
/// (`SpeechDispatcherSynthesiser` — the `spd-say` fallback the contract
/// describes with `canRenderToFile == false` — is deliberately not here. It
/// does not render, so it has no place in a *file* synthesiser; the degraded
/// whole-page path stays where it already works, in `TtsService`.)
///
/// **The look-ahead lives here too**, in [SpeechRenderWindow]. That is not an
/// afterthought: rendering ahead is the only reason a `render → file` design
/// does not put a second of silence between every sentence, and the rules that
/// make it safe — bounded depth, strict order, one owner per temp file — are
/// the same rules on both platforms even though the engines are not.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../concurrency.dart';
import '../piper_tts.dart';
import 'speech_pipeline.dart';

// ─────────────────────────────────────────────────────────────────────────────
// The one thing the contract does not express
// ─────────────────────────────────────────────────────────────────────────────

/// [SpeechSynthesiser] plus the two facts a look-ahead window needs and the
/// contract has no field for.
///
/// **Not a gratuitous extension.** [SpeechRenderPolicy.maxConcurrentRenders] is
/// a *preference* — how much of the machine the app is willing to spend. It is
/// not a *capability*, and for flutter_tts the capability is hard-limited to
/// one: the plugin keeps a single pending-result slot in native code, shared by
/// every Dart `FlutterTts` instance, so a second overlapping render is refused
/// outright on Android (`result.success(0)` while its `synth` flag is set) and
/// overwrites the pending reply on iOS and macOS, stranding the first call's
/// Future forever. A window that trusted the policy alone would deadlock on
/// mobile the first time it tried to render two sentences at once.
///
/// [SpeechRenderWindow] takes the smaller of the two, so the policy can still
/// throttle Piper below its capability without ever exceeding it.
abstract class FileSpeechSynthesiser implements SpeechSynthesiser {
  /// How many renders this engine can genuinely have in flight. One means the
  /// engine is a single global resource, not a slow one.
  int get maxParallelRenders;

  /// Extension for [SpeechCache] to mint paths with, without the dot. The
  /// container matters to the *player*, and on iOS it also decides what
  /// `AVAudioFile` writes, so the engine names it rather than the cache.
  String get fileExtension;
}

// ─────────────────────────────────────────────────────────────────────────────
// Where the audio goes
// ─────────────────────────────────────────────────────────────────────────────

/// The sweepable directory every rendered sentence is written into.
///
/// **One directory, one filename convention, so a crash is recoverable.** The
/// normal exit paths delete their own files ([SpeechRenderWindow] discards the
/// window it abandons, the player releases what it has finished with), but a
/// SIGKILL, an OOM kill or a `flutter run` hot restart takes the process out
/// between the render and the delete, and whatever was on disk stays there with
/// nobody left who knows it exists. Encoding the process id into the name is
/// what makes those files identifiable later — see [sweep].
class SpeechCache {
  SpeechCache({this.folderName = 'speech'});

  /// Subdirectory of the app's temporary directory. Not the *cache* directory:
  /// these files are worthless the moment they have been heard, and on iOS the
  /// cache directory is backed up in some configurations while tmp never is.
  final String folderName;

  /// Every file this cache mints starts with it, so [sweep] can tell our
  /// audio apart from anything else sharing a temp directory.
  static const _prefix = 'spk';

  Directory? _dir;

  /// Distinguishes files rendered by *this* run from those of a previous or
  /// concurrent one. The queue generation alone cannot: it restarts at zero in
  /// every process, so two running copies of the app would render to
  /// byte-identical paths and eat each other's audio.
  static final int _pid = pid;

  /// Renders within one process can collide too — the same sentence re-rendered
  /// after a voice change lands on the same page and sentence index — and
  /// overwriting a file the player still has open is a click or a silence, not
  /// an error anyone would trace back to here.
  static int _serial = 0;

  Future<Directory> directory() async {
    final existing = _dir;
    if (existing != null) return existing;

    Directory base;
    try {
      base = await getTemporaryDirectory();
    } catch (_) {
      // path_provider needs the plugin bindings up. A unit test or a headless
      // tool has no reason to be denied a temp directory over that.
      base = Directory.systemTemp;
    }
    final dir = Directory(p.join(base.path, folderName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Absolute path for one unit of one queue generation.
  Future<String> pathFor(
    SpeechUnit unit, {
    required int queueId,
    required String extension,
  }) async {
    final dir = await directory();
    final serial = _serial++;
    return p.join(
      dir.path,
      '${_prefix}_${_pid}_q${queueId}_p${unit.page}s${unit.sentenceIndex}'
      '_$serial.$extension',
    );
  }

  /// Delete without ever throwing.
  ///
  /// Called from `finally` blocks on the stop path, where a missing file, a
  /// file still being written by a subprocess that has not noticed it was
  /// killed, and a second delete of the same path are all normal.
  static Future<void> deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // A temp file that will not delete is worth no user-visible failure.
    }
  }

  /// Audio left behind by runs that are no longer alive.
  ///
  /// **Deliberately cautious, because the cost of being wrong is asymmetric.**
  /// Deleting a few kilobytes late is invisible; deleting the look-ahead window
  /// of a *second running copy* of the app cuts its playback off mid-paragraph.
  /// So a file is only removed when it belongs to another process id **and**
  /// that process is provably gone (Linux, via `/proc`) or the file is old
  /// enough that no live look-ahead window could still be waiting on it — the
  /// window is at most four sentences deep and refills continuously, so hours
  /// of age means nobody is coming back for it.
  Future<void> sweep({Duration orphanAfter = const Duration(hours: 6)}) async {
    try {
      final dir = await directory();
      final now = DateTime.now();
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File) continue;
        final owner = _pidOf(p.basename(entry.path));
        if (owner == null) continue; // not ours; leave it alone
        if (owner == _pid) continue; // this run's, and this run is alive

        // Provably dead is enough on its own. Anything else — a live process,
        // or a platform where we cannot tell — falls back to age, which is
        // still safe for a second running copy of the app: its look-ahead is at
        // most four sentences and refills continuously, so its files are
        // seconds old, never hours. Without this fallback on the `alive == true`
        // branch, a recycled pid (routine on a box that has been up for days)
        // would pin a crashed run's audio in the temp directory forever.
        final alive = _processIsAlive(owner);
        if (alive != false) {
          final stat = await entry.stat();
          if (now.difference(stat.modified) < orphanAfter) continue;
        }
        await deleteQuietly(entry.path);
      }
    } catch (_) {
      // Best-effort by definition: it runs once at startup and must never be
      // the reason the app fails to open.
    }
  }

  /// Process id out of `spk_<pid>_q…`, or null when the name is not ours.
  static int? _pidOf(String basename) {
    if (!basename.startsWith('${_prefix}_')) return null;
    final parts = basename.split('_');
    if (parts.length < 3) return null;
    return int.tryParse(parts[1]);
  }

  /// True, false, or null for "cannot tell on this platform".
  ///
  /// Only Linux gets a real answer, and Linux is where the desktop pipeline
  /// actually lives. Shelling out to `kill -0` elsewhere would mean spawning a
  /// process per orphan during startup, which costs more than the disk it
  /// reclaims; those platforms fall back to the age rule.
  static bool? _processIsAlive(int owner) {
    if (!Platform.isLinux) return null;
    try {
      return Directory('/proc/$owner').existsSync();
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Piper — linux, macos
// ─────────────────────────────────────────────────────────────────────────────

/// Neural synthesis by subprocess, reusing [PiperTts] for everything about
/// where Piper and its voices live.
///
/// **Serves linux and macos.** It shells out, which rules out iOS and Android
/// entirely, and [PiperTts]'s discovery only searches Unix-shaped paths, so on
/// Windows it reports unavailable rather than half-working.
///
/// Discovery, the `--length-scale` rate mapping and the install instructions
/// are *not* duplicated here — [PiperTts] owns them, is already covered by the
/// existing engine, and a second copy would drift.
class PiperSynthesiser implements FileSpeechSynthesiser {
  PiperSynthesiser({SpeechCache? cache, int? maxParallelRenders})
      : cache = cache ?? SpeechCache(),
        maxParallelRenders =
            maxParallelRenders ?? math.max(1, math.min(2, Concurrency.cpuPool));

  final SpeechCache cache;

  /// Piper spends a whole core per process, so this stays far below
  /// [Concurrency.cpuPool]: the point of rendering ahead is unbroken audio, not
  /// a busy machine behind a page that has stopped scrolling smoothly.
  @override
  final int maxParallelRenders;

  @override
  String get engineName => 'Piper (neural)';

  @override
  String get fileExtension => 'wav';

  @override
  bool get canRenderToFile => true;

  /// `--length-scale` is applied at synthesis, so the speed is frozen into the
  /// WAV and a rate change invalidates the whole look-ahead window.
  @override
  bool get bakesRateIntoAudio => true;

  /// **Binary and voices only — deliberately not [PiperTts.isAvailable].**
  ///
  /// That getter also requires `pw-play`/`paplay`/`aplay`/`ffplay` to exist,
  /// which is a *playback* capability and belongs to the player's own probe. A
  /// synthesiser that reported unavailable because no audio tool was installed
  /// would be answering a question it was not asked, and the composing pipeline
  /// would have no way to tell the two failures apart in its error message.
  @override
  Future<bool> isAvailable() async {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return false;
    }
    return PiperTts.binary != null && PiperTts.voices.isNotEmpty;
  }

  @override
  String get unavailableMessage => PiperTts.installMessage;

  @override
  Future<List<SpeechVoice>> voices() async => [
        for (final name in PiperTts.voices)
          SpeechVoice(
            id: name,
            name: _prettyName(name),
            locale: _localeOf(name),
            isNeural: true,
          ),
      ];

  @override
  Future<RenderedSpeech> render(
    SpeechUnit unit, {
    required SpeechQueue queue,
    required SpeechVoice voice,
    required double rate,
    required String outputPath,
  }) async {
    final file = await PiperTts.synthesise(
      unit.text,
      voice: voice.id,
      rate: rate,
      outPath: outputPath,
    );
    return RenderedSpeech(
      unit: unit,
      queueId: queue.id,
      path: file.path,
      voiceId: voice.id,
      rate: rate,
      // The subprocess player cannot report a duration — it is a `pw-play` that
      // either is running or is not — so without reading it out of the header
      // here, NowPlaying.duration stays null forever on desktop and some
      // platform controls hide the progress bar entirely when it is.
      duration: await _wavDuration(file.path),
    );
  }

  @override
  Future<void> discard(RenderedSpeech rendered) =>
      SpeechCache.deleteQuietly(rendered.path);

  @override
  Future<void> sweepOrphans() => cache.sweep();

  /// `en_US-lessac-medium` → `Lessac (medium)`.
  static String _prettyName(String model) {
    final withoutLocale = model.contains('-')
        ? model.substring(model.indexOf('-') + 1)
        : model;
    final parts = withoutLocale.split('-');
    final speaker = parts.first;
    final label = speaker.isEmpty
        ? model
        : speaker[0].toUpperCase() + speaker.substring(1);
    return parts.length > 1 ? '$label (${parts.sublist(1).join(' ')})' : label;
  }

  static String? _localeOf(String model) {
    final dash = model.indexOf('-');
    return dash > 0 ? model.substring(0, dash) : null;
  }
}

/// Length of a canonical PCM WAV, or null when the header is not one.
///
/// Kept defensive rather than clever: every unexpected byte returns null, and a
/// null duration is a lock screen without a scrubber, not a failed sentence.
Future<Duration?> _wavDuration(String path) async {
  RandomAccessFile? handle;
  try {
    handle = await File(path).open();
    // Enough for the canonical 44-byte header plus the LIST/INFO chunks some
    // encoders put in front of `data`.
    final header = await handle.read(4096);
    if (header.length < 44) return null;

    final bytes = ByteData.sublistView(header);
    if (String.fromCharCodes(header, 0, 4) != 'RIFF' ||
        String.fromCharCodes(header, 8, 12) != 'WAVE') {
      return null;
    }

    var offset = 12;
    var byteRate = 0;
    while (offset + 8 <= header.length) {
      final id = String.fromCharCodes(header, offset, offset + 4);
      final size = bytes.getUint32(offset + 4, Endian.little);
      if (id == 'fmt ' && offset + 20 <= header.length) {
        byteRate = bytes.getUint32(offset + 16, Endian.little);
      } else if (id == 'data') {
        if (byteRate <= 0) return null;
        return Duration(microseconds: (size * 1000000) ~/ byteRate);
      }
      // Chunks are word-aligned; an odd size carries a pad byte.
      offset += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      await handle?.close();
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// flutter_tts — android, ios, macos
// ─────────────────────────────────────────────────────────────────────────────

/// The platform voice, rendered to a file so it can be played in the
/// background.
///
/// **Serves android, ios and macos.** Not Linux: flutter_tts has no Linux
/// implementation and its calls fail silently there, which is
/// indistinguishable from a broken Play button. Not Windows either, despite the
/// plugin supporting Windows for `speak` — its Windows implementation has no
/// `synthesizeToFile` handler at all, so every render would throw
/// `MissingPluginException`.
///
/// **Why this class is more than three lines of plugin call.** `synthesizeToFile`
/// does not do what its Future implies. Read against flutter_tts 4.2.5:
///
///   * By default the native side replies `1` as soon as the utterance has been
///     *queued*. Awaiting it and then opening the file gives an empty or
///     half-written file — the classic "it plays a click" bug. Completion only
///     travels back when `awaitSynthCompletion(true)` has been set, which this
///     class does once, up front.
///   * Even then the reply can never arrive. On Android the error path
///     (`UtteranceProgressListener.onError` for a `STF_` utterance) clears the
///     plugin's internal `synth` flag and posts `synth.onError`, but never
///     completes the stored result — so the Future hangs for the life of the
///     process. Hence the error handler *and* the timeout below; either one
///     alone leaves a real hang unhandled.
///   * A hang is not local damage. That same `synth` flag is what makes Android
///     refuse every subsequent `synthesizeToFile` with `0` while it is set, so
///     one unrecovered timeout would silence the rest of the book. `stop()` is
///     the only call that clears it, so recovery calls it explicitly.
///   * The plugin's channel is `static`, and each `FlutterTts()` constructor
///     re-registers the handler on it, so **the most recently constructed
///     instance receives every callback** and all instances share one native
///     object. Pass [tts] in when something else in the app already owns an
///     instance; otherwise this class's error handler may simply never fire and
///     every failure degrades to a timeout.
///   * `synth.onComplete` and `speak.onComplete` both route to the *same*
///     `completionHandler`, so an instance shared with anything that speaks
///     will cross-fire. One more reason for this class to own its instance.
class FlutterTtsSynthesiser implements FileSpeechSynthesiser {
  FlutterTtsSynthesiser({
    SpeechCache? cache,
    FlutterTts? tts,
    this.renderTimeout = const Duration(seconds: 30),
  })  : cache = cache ?? SpeechCache(),
        _tts = tts ?? FlutterTts();

  final SpeechCache cache;
  final FlutterTts _tts;

  /// Backstop for a reply that never comes.
  ///
  /// Generous on purpose: the first synthesis after a cold start has to wake
  /// the platform TTS service, and cutting that off would make the first
  /// sentence of every session fail. Anything past this is a stuck engine, not
  /// a slow one.
  final Duration renderTimeout;

  bool _configured = false;

  /// Completed with an error by the plugin's error handler, so a failed render
  /// fails fast instead of sitting out the whole timeout.
  ///
  /// Cleared as each render ends, so a *late* error — one that arrives after
  /// its own render already gave up on the timeout — lands on nothing. If it
  /// arrives later still, once the next render has started, it costs that one
  /// sentence. That is the honest trade: the alternative is correlating
  /// utterance ids the plugin does not expose to Dart.
  Completer<void>? _failure;

  /// Serialises renders end to end; see [maxParallelRenders].
  Future<void> _tail = Future<void>.value();

  /// **One.** Not a throughput choice — the plugin has a single native
  /// pending-result slot shared by every instance, and overlapping calls are
  /// refused on Android and stranded on iOS and macOS.
  @override
  int get maxParallelRenders => 1;

  @override
  String get engineName => 'System voice';

  /// Android's TTS writes RIFF/WAV. On iOS and macOS the extension is what
  /// `AVAudioFile(forWriting:)` uses to choose its container, so asking for
  /// `.wav` is what makes the result a WAV rather than whatever the default
  /// would be.
  @override
  String get fileExtension => 'wav';

  @override
  bool get canRenderToFile => true;

  /// `setSpeechRate` is applied to the utterance before it is written, so the
  /// speed is baked in. A player that can retime (just_audio's `setSpeed`) may
  /// still prefer its own path — see `SpeechQueuePlayer.supportsPlaybackSpeed`.
  @override
  bool get bakesRateIntoAudio => true;

  static bool get _isSupportedPlatform =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  Future<bool> isAvailable() async {
    if (!_isSupportedPlatform) return false;
    try {
      // The channel answering at all is the real probe; a device with no voice
      // data installed answers with an empty list, and that is a genuine
      // "unavailable" rather than an error.
      return (await voices()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  String get unavailableMessage {
    if (Platform.isLinux) {
      return 'The system voice is not available on Linux. Install Piper for '
          'local neural speech:\n${PiperTts.installMessage}';
    }
    if (Platform.isWindows) {
      return 'The system voice on Windows cannot render speech to a file, '
          'which this player needs. Install Piper instead.';
    }
    return 'No speech voices are installed. Add one in the system settings '
        'under Accessibility → Spoken content.';
  }

  @override
  Future<List<SpeechVoice>> voices() async {
    if (!_isSupportedPlatform) return const [];
    final raw = await _tts.getVoices;
    if (raw is! List) return const [];

    final result = <SpeechVoice>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final name = entry['name']?.toString();
      if (name == null || name.isEmpty) continue;
      final locale = entry['locale']?.toString();
      // iOS and macOS report a quality; Android does not, so its voices stay
      // marked non-neural rather than being guessed at from their names.
      final quality = entry['quality']?.toString().toLowerCase();
      result.add(SpeechVoice(
        id: _voiceId(name, locale),
        name: name,
        locale: locale,
        isNeural: quality == 'enhanced' || quality == 'premium',
      ));
    }
    result.sort((a, b) {
      final byLocale = (a.locale ?? '').compareTo(b.locale ?? '');
      return byLocale != 0 ? byLocale : a.name.compareTo(b.name);
    });
    return result;
  }

  @override
  Future<RenderedSpeech> render(
    SpeechUnit unit, {
    required SpeechQueue queue,
    required SpeechVoice voice,
    required double rate,
    required String outputPath,
  }) =>
      _serialised(() => _render(unit, queue, voice, rate, outputPath));

  Future<RenderedSpeech> _render(
    SpeechUnit unit,
    SpeechQueue queue,
    SpeechVoice voice,
    double rate,
    String outputPath,
  ) async {
    if (!_isSupportedPlatform) throw StateError(unavailableMessage);
    await _configure();
    // Re-applied every render, never memoised. The plugin's channel is `static`
    // and there is one native engine behind every Dart instance, so anything
    // else in the app that speaks — `TtsService` calls `setSpeechRate` and
    // `setVolume` on its own `FlutterTts` — silently changes the state this
    // render is about to be written with. A cached "already applied" flag would
    // then be wrong in the one direction that is inaudible until playback:
    // sentences written at the wrong speed, or, because iOS bakes
    // `utterance.volume` into the file, an hour of listening frozen at whatever
    // level a sleep-timer fade last left behind. Three channel round trips are
    // nothing beside the synthesis they precede.
    await _applyVoice(voice);
    await _applyRate(rate);
    await _applyFullVolume();

    // A leftover file at this path would pass the existence check below and be
    // played as if it were this sentence.
    await SpeechCache.deleteQuietly(outputPath);

    final failure = Completer<void>();
    _failure = failure;
    try {
      // With awaitSynthCompletion set, this Future is the completion signal —
      // except on the Android error path, where it never resolves at all.
      final reply = _tts.synthesizeToFile(unit.text, outputPath, true);
      final outcome = await Future.any<Object?>([
        reply,
        failure.future.then((_) => null),
      ]).timeout(renderTimeout);

      // `1` is the only success. Android answers `0` when a previous synthesis
      // is still flagged in flight, and iOS answers a string on versions below
      // 13 where writing is unsupported.
      if (outcome != 1) {
        await _recoverEngine();
        throw StateError(
          'The system voice refused to render "${unit.id}" ($outcome).',
        );
      }

      final file = File(outputPath);
      // The plugin reports success in cases where nothing was written, so the
      // file itself is the last word. A zero-byte file plays as a click and
      // would otherwise look like a working sentence.
      if (!await file.exists() || await file.length() == 0) {
        throw StateError('The system voice produced no audio for "${unit.id}".');
      }

      return RenderedSpeech(
        unit: unit,
        queueId: queue.id,
        path: outputPath,
        voiceId: voice.id,
        rate: rate,
        // Left null: just_audio reports a duration once it opens the file, and
        // guessing here would only be wrong.
      );
    } on TimeoutException {
      await _recoverEngine();
      rethrow;
    } finally {
      if (identical(_failure, failure)) _failure = null;
    }
  }

  @override
  Future<void> discard(RenderedSpeech rendered) =>
      SpeechCache.deleteQuietly(rendered.path);

  @override
  Future<void> sweepOrphans() => cache.sweep();

  /// Clear the plugin's stuck in-flight flag.
  ///
  /// Android sets `synth = true` when a render starts and only clears it on a
  /// completed render or on `stop()`. A timed-out or errored render leaves it
  /// set, and every later `synthesizeToFile` then returns `0` immediately — the
  /// rest of the book silently fails. This is the only way back.
  Future<void> _recoverEngine() async {
    try {
      await _tts.stop();
    } catch (_) {
      // Recovery that fails leaves us no worse off than not trying.
    }
  }

  Future<void> _configure() async {
    if (_configured) return;

    // Synchronous, so it is in place before the first render can fail. The
    // Android error path posts here and nowhere else, so this handler is the
    // difference between failing in a second and failing on the timeout.
    _tts.setErrorHandler((message) {
      final pending = _failure;
      _failure = null;
      if (pending != null && !pending.isCompleted) {
        pending.completeError(
          StateError('The system voice failed: $message'),
        );
      }
    });

    // Without this, every synthesizeToFile Future resolves at *queue* time and
    // the file is read before it has been written.
    await _tts.awaitSynthCompletion(true);

    // Set last, and only once the call above actually took. Marking configured
    // up front would mean a single failed channel call — a cold platform TTS
    // service, a MissingPluginException — left the flag set forever with
    // await-completion still off, and every render from then on would read a
    // file the engine had merely been asked to start writing. The zero-length
    // guard catches the empty case; a half-written file passes it and plays as
    // a sentence that stops mid-word.
    _configured = true;
  }

  /// Volume belongs to the player, so the sleep-timer fade costs nothing and
  /// invalidates no rendered-ahead audio — but only if what is written is
  /// always full scale.
  Future<void> _applyFullVolume() async {
    try {
      await _tts.setVolume(1.0);
    } catch (_) {
      // Not fatal: a platform that will not take a volume still renders.
    }
  }

  /// `setVoice` needs a name *and* a locale, but [SpeechVoice.id] has to be one
  /// opaque string the settings screen can store. Flattening them here and
  /// splitting in [_applyVoice] keeps that pair together through persistence.
  static String _voiceId(String name, String? locale) =>
      (locale == null || locale.isEmpty) ? name : '$name|$locale';

  Future<void> _applyVoice(SpeechVoice voice) async {
    final split = voice.id.indexOf('|');
    final name = split < 0 ? voice.id : voice.id.substring(0, split);
    final locale = split < 0 ? '' : voice.id.substring(split + 1);
    // setVoice wants both keys; a voice discovered without a locale is passed
    // with an empty one rather than being dropped, since the name alone is
    // enough on Android.
    await _tts.setVoice({'name': name, 'locale': locale});
  }

  Future<void> _applyRate(double rate) async {
    // Same 0.1–1.0 scale the existing engine passes straight through, so a
    // stored rate means the same thing before and after the migration.
    await _tts.setSpeechRate(rate.clamp(0.1, 1.0));
  }

  /// A mutex, not a pool: [maxParallelRenders] is one, and this enforces it
  /// even for a caller that ignores it. The chain is built from a completer
  /// that always completes normally, so one failed render cannot poison every
  /// render after it.
  Future<T> _serialised<T>(Future<T> Function() action) {
    final previous = _tail;
    final gate = Completer<void>();
    _tail = gate.future;
    return previous
        .then((_) => action())
        .whenComplete(() => gate.complete());
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The honest null object
// ─────────────────────────────────────────────────────────────────────────────

/// What a platform with no workable engine gets.
///
/// Returning this rather than null means the pipeline is never holding an empty
/// reference and no caller has to branch; [isAvailable] answers false, the UI
/// disables Play, and [render] throws loudly if anything ignores that.
class UnavailableSynthesiser implements FileSpeechSynthesiser {
  const UnavailableSynthesiser(this.unavailableMessage);

  @override
  final String unavailableMessage;

  @override
  String get engineName => 'No speech engine';

  @override
  int get maxParallelRenders => 1;

  @override
  String get fileExtension => 'wav';

  @override
  bool get canRenderToFile => false;

  @override
  bool get bakesRateIntoAudio => true;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<SpeechVoice>> voices() async => const [];

  @override
  Future<RenderedSpeech> render(
    SpeechUnit unit, {
    required SpeechQueue queue,
    required SpeechVoice voice,
    required double rate,
    required String outputPath,
  }) async =>
      throw StateError(unavailableMessage);

  @override
  Future<void> discard(RenderedSpeech rendered) async {}

  @override
  Future<void> sweepOrphans() async {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Choosing one
// ─────────────────────────────────────────────────────────────────────────────

/// Picks the synthesiser a platform *can* run.
class FileSynthesisers {
  const FileSynthesisers._();

  /// The candidate for this platform, mirroring [SpeechBackend.forPlatform].
  ///
  /// Synchronous and platform-only, exactly like that enum: whether an engine
  /// is *installed* is a filesystem or platform-channel question and stays with
  /// [SpeechSynthesiser.isAvailable], which the caller must still await. Fusing
  /// the two is how you get a Play button that does nothing on a machine
  /// without Piper.
  ///
  /// On macOS both engines work, and Piper wins when it is installed: it is the
  /// same neural quality across every platform the user reads on, and a voice
  /// that changes when you pick the book up on a different machine is jarring.
  /// [preferNeural] false pins the platform voice instead.
  static FileSpeechSynthesiser forPlatform({
    SpeechCache? cache,
    FlutterTts? tts,
    bool preferNeural = true,
  }) {
    final shared = cache ?? SpeechCache();

    if (Platform.isAndroid || Platform.isIOS) {
      return FlutterTtsSynthesiser(cache: shared, tts: tts);
    }
    if (Platform.isMacOS) {
      final piperInstalled =
          PiperTts.binary != null && PiperTts.voices.isNotEmpty;
      return preferNeural && piperInstalled
          ? PiperSynthesiser(cache: shared)
          : FlutterTtsSynthesiser(cache: shared, tts: tts);
    }
    if (Platform.isLinux || Platform.isWindows) {
      // flutter_tts cannot render to a file on either, so Piper is the only
      // candidate — including on Windows, where it will usually then report
      // unavailable, which is the honest answer.
      return PiperSynthesiser(cache: shared);
    }
    return const UnavailableSynthesiser(
      'Read-aloud is not supported on this platform.',
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Rendering ahead
// ─────────────────────────────────────────────────────────────────────────────

/// Keeps a small window of sentences rendered ahead of the playhead, and hands
/// the audio out **in queue order**.
///
/// **What this is for.** Rendering only the sentence being played puts a
/// synthesis pause in every gap; on a busy machine or a large voice model that
/// is audible, and a paragraph reads like a bad phone line. Rendering the whole
/// chapter up front means a spinner before any sound, a saturated CPU behind a
/// page the user is still trying to read, and — the common case — a hundred
/// files deleted unheard when they stop after the first sentence. So: a sliding
/// window [SpeechRenderPolicy.lookAhead] deep, refilled as the playhead moves.
///
/// **Order.** Renders finish out of order by nature — a short sentence
/// overtakes a long one, a warm engine overtakes a cold one — so a completed
/// render is held until every earlier one in the queue has been emitted or has
/// failed. The player enforces order too, and it must; this simply means the
/// supply stream is never itself a source of scrambling.
///
/// **Ownership, which is the part that leaks temp files if it is vague.** Every
/// [RenderedSpeech] this window creates leaves by exactly one of two doors:
///
///   * out through [rendered], after which it belongs to the listener — which
///     hands it to `SpeechQueuePlayer.supply` and deletes it when the player
///     puts it on `released`; or
///   * into [SpeechSynthesiser.discard], because the queue was superseded, the
///     window was closed, or the playhead ran past it before it was wanted.
///
/// There is no third door. In particular a render still in flight when [close]
/// is called is *not* awaited — a running Piper process cannot be hurried and
/// stop has to feel instant — it is discarded as it settles, long after the
/// caller has moved on.
class SpeechRenderWindow {
  SpeechRenderWindow({
    required this.synthesiser,
    SpeechCache? cache,
    SpeechRenderPolicy policy = const SpeechRenderPolicy(),
  })  : cache = cache ?? SpeechCache(),
        _policy = policy.sanitised;

  final SpeechSynthesiser synthesiser;
  final SpeechCache cache;

  SpeechRenderPolicy _policy;
  SpeechRenderPolicy get policy => _policy;

  /// Always stored sanitised, so a bad stored setting cannot turn the window
  /// into a whole-chapter prerender.
  set policy(SpeechRenderPolicy value) {
    _policy = value.sanitised;
    _wake(); // a wider window may have room for a unit already waiting
  }

  /// Audio ready to be supplied to a player, in strict queue order.
  ///
  /// Single-subscription on purpose: a broadcast stream drops events when
  /// nobody is listening, and here a dropped event is an orphaned file. Listen
  /// once, before the first [open].
  Stream<RenderedSpeech> get rendered => _out.stream;

  /// A unit that could not be rendered, so the caller can log it and carry on.
  /// One bad sentence must not end a chapter, so nothing here stops the window.
  void Function(SpeechUnit unit, Object error)? onRenderFailed;

  late final _out = StreamController<RenderedSpeech>(
    onListen: () => _listened = true,
  );

  /// Whether anything ever subscribed. Not the same as `_out.hasListener`,
  /// which is also false after a subscription has been cancelled — and the two
  /// cases need opposite handling in [dispose].
  bool _listened = false;

  /// Bumped by [open], [close] and [dispose]; everything in flight for an older
  /// value exits quietly and discards what it made. The same guard as
  /// [SpeechQueue.id], but for this object's own lifecycle: a queue can be
  /// re-opened at a new position without a new generation upstream.
  int _generation = 0;

  int _playhead = 0;

  /// [SpeechQueue.id] of the open run, so [advanceTo] can drop status events
  /// belonging to a run that has already been superseded.
  int? _queueId;

  /// Completed whenever the window may have moved, so gated renders re-check.
  Completer<void>? _moved;

  /// Finished renders waiting for their turn to be emitted; null means "this
  /// index produced nothing", which still has to be recorded or the ordered
  /// flush would stall behind it forever.
  final _pending = <int, RenderedSpeech?>{};
  var _nextToEmit = 0;

  int get playhead => _playhead;

  /// Start rendering [queue] from [SpeechQueue.startAt].
  ///
  /// Supersedes anything already running. Returns as soon as the run is
  /// established — the renders themselves continue in the background and arrive
  /// on [rendered].
  Future<void> open(
    SpeechQueue queue, {
    required SpeechVoice voice,
    required double rate,
  }) async {
    assert(queue.isOrdered, 'A queue out of reading order would read the book '
        'out of sequence, and nothing downstream can detect it.');

    _supersede();
    if (queue.isEmpty) return;

    final generation = _generation;
    _playhead = queue.startAt.clamp(0, math.max(0, queue.length - 1));
    _nextToEmit = 0;
    _queueId = queue.id;

    // Not awaited: the caller wants playback to start, not the queue to finish.
    unawaited(_run(queue, voice, rate, generation));
  }

  /// Tell the window where playback has reached, so it refills ahead of that.
  ///
  /// Driven from the player's status stream, using
  /// `SpeechPlayerStatus.queueIndex` — the one place a queue index is the right
  /// thing to read, because this is transport arithmetic and not the highlight.
  ///
  /// **Pass [queueId] — `SpeechPlayerStatus.queueId` — whenever the caller has
  /// it.** A player's status stream delivers asynchronously, so an event emitted
  /// just before a skip arrives just after it, carrying a queue index from the
  /// run that was superseded. Applied blind, an index of 30 from the old run
  /// drags the new run's playhead to 30: its sentences 0–29 are then settled as
  /// "produced nothing", the player never receives the audio it is waiting for,
  /// and playback sits in `preparing` forever with no error anywhere. The
  /// contract already requires stale status events to be dropped by
  /// `SpeechPlayerStatus.queueId`; this is the same guard, enforced here too so
  /// the window is not silently depending on a caller getting it right.
  void advanceTo(int queueIndex, {int? queueId}) {
    if (queueId != null && queueId != _queueId) return; // superseded run
    if (queueIndex <= _playhead) return; // never rewinds; see [open]
    _playhead = queueIndex;
    _wake();
  }

  /// Stop rendering and discard everything not already handed out.
  ///
  /// Fast by contract: renders already running settle in their own time and
  /// delete themselves then.
  Future<void> close() async => _supersede();

  /// [close], and never usable again.
  Future<void> dispose() async {
    await close();
    if (_listened) {
      await _out.close();
      return;
    }

    // Two problems, one cause. `close()` on a single-subscription controller
    // that was never listened to returns a Future that **never completes**, so
    // this method would hang the whole teardown — a pipeline whose availability
    // check failed and which is disposed without ever having started is exactly
    // that case. And anything already buffered in the controller has no listener
    // to take ownership of it, so its file would be orphaned. Draining into
    // [SpeechSynthesiser.discard] fixes both: `close()` now has somewhere to
    // deliver `done`, and by the time it completes every buffered render has
    // been handed to the drain.
    final drained = <Future<void>>[];
    final sub = _out.stream.listen(
      (rendered) => drained.add(_discard(rendered)),
      onError: (_) {},
    );
    await _out.close();
    await sub.cancel();
    await Future.wait(drained);
  }

  /// Invalidate the current run and release everything holding on to it.
  void _supersede() {
    _generation++;
    _queueId = null; // a status event for the run just ended is stale by definition
    _wake();

    // Anything buffered for ordering will never be emitted now.
    final stranded = _pending.values.whereType<RenderedSpeech>().toList();
    _pending.clear();
    for (final rendered in stranded) {
      unawaited(_discard(rendered));
    }
  }

  void _wake() {
    final waiting = _moved;
    _moved = null;
    if (waiting != null && !waiting.isCompleted) waiting.complete();
  }

  Future<void> _run(
    SpeechQueue queue,
    SpeechVoice voice,
    double rate,
    int generation,
  ) async {
    // The engine's real capability wins over the policy's preference — see
    // [FileSpeechSynthesiser.maxParallelRenders]. A window that ran two
    // flutter_tts renders at once would hang on the second one.
    final capability = synthesiser is FileSpeechSynthesiser
        ? (synthesiser as FileSpeechSynthesiser).maxParallelRenders
        : _policy.maxConcurrentRenders;
    final limit = math.max(1, math.min(_policy.maxConcurrentRenders, capability));

    // mapBounded rather than a hand-rolled pool: it bounds the fan-out, it
    // hands out indices in ascending order (so the playhead's own sentence is
    // always claimed before the ones behind it), and it takes the cancellation
    // predicate this window needs anyway.
    //
    // Wrapped because this future is deliberately not awaited: a throw escaping
    // here would be an unhandled zone error rather than anything a caller could
    // catch, and worse, `mapBounded`'s worker stops claiming indices the moment
    // it throws — with the flutter_tts concurrency of one that silently ends the
    // chapter. `_renderOne` is written to be total; this is the belt to its
    // braces.
    try {
      await Concurrency.mapBounded<SpeechUnit, RenderedSpeech?>(
        queue.units,
        (unit, index) => _renderOne(unit, index, queue, voice, rate, generation),
        concurrency: limit,
        isCancelled: () => generation != _generation,
      );
    } catch (_) {
      // Nothing useful to do: every per-unit failure is already reported through
      // [onRenderFailed], and a run that cannot continue simply stops rendering.
    }
  }

  Future<RenderedSpeech?> _renderOne(
    SpeechUnit unit,
    int index,
    SpeechQueue queue,
    SpeechVoice voice,
    double rate,
    int generation,
  ) async {
    // Units behind the playhead are in the queue so a backwards skip has
    // somewhere to go, not so they can be rendered. A backwards skip re-opens
    // the window at the new position, which is also what rebuilds their audio.
    if (index < _playhead || generation != _generation) {
      _settle(index, null, generation);
      return null;
    }

    await _waitForRoom(index, generation);
    // Re-checked after the wait, exactly as the existing engine does: a unit
    // superseded or overtaken while it queued must not cost a core, nor leave
    // a file behind.
    if (generation != _generation || index < _playhead) {
      _settle(index, null, generation);
      return null;
    }

    String? path;
    RenderedSpeech rendered;
    try {
      path = await cache.pathFor(
        unit,
        queueId: queue.id,
        extension: synthesiser is FileSpeechSynthesiser
            ? (synthesiser as FileSpeechSynthesiser).fileExtension
            : 'wav',
      );
      rendered = await synthesiser.render(
        unit,
        queue: queue,
        voice: voice,
        rate: rate,
        outputPath: path,
      );
    } catch (error) {
      // Catches the path mint as well as the render itself: an unwritable temp
      // directory would otherwise escape mapBounded into an unawaited run and
      // strand the ordered flush behind an index that never settles.
      //
      // A failed render can still have left a partial file — Piper writes the
      // header before it writes samples — and nothing else knows the path.
      if (path != null) await SpeechCache.deleteQuietly(path);
      // Guarded: this is caller-supplied logging, and a throw from it would
      // propagate out of the worker, stop `mapBounded` from claiming any further
      // index, and silently end the chapter — the exact failure the "one bad
      // sentence must not end a chapter" rule exists to prevent.
      try {
        onRenderFailed?.call(unit, error);
      } catch (_) {
        // A reporting callback that fails is not a reason to stop reading.
      }
      _settle(index, null, generation);
      return null;
    }

    if (generation != _generation) {
      // Completed after a stop or a newer open. This is the case the existing
      // engine's `_discardRendered` covers, and the reason it exists.
      await _discard(rendered);
      _settle(index, null, generation);
      return null;
    }

    _settle(index, rendered, generation);
    return rendered;
  }

  /// Block until [index] is inside the window, the run is superseded, or the
  /// playhead has passed it.
  Future<void> _waitForRoom(int index, int generation) async {
    while (generation == _generation) {
      if (index <= _playhead + _policy.lookAhead) return;
      if (index < _playhead) return;
      await (_moved ??= Completer<void>()).future;
    }
  }

  /// Record an index's outcome and flush everything now emittable.
  ///
  /// **Every index must land here exactly once**, including the ones that
  /// produced nothing: the flush pointer walks the queue in order, so a missing
  /// entry would hold back every later render permanently.
  void _settle(int index, RenderedSpeech? rendered, int generation) {
    if (generation != _generation) {
      if (rendered != null) unawaited(_discard(rendered));
      return;
    }
    _pending[index] = rendered;

    while (_pending.containsKey(_nextToEmit)) {
      final next = _pending.remove(_nextToEmit);
      _nextToEmit++;
      if (next == null) continue;
      if (_out.isClosed) {
        unawaited(_discard(next));
        continue;
      }
      // Ownership passes to the listener here and nowhere else.
      _out.add(next);
    }
  }

  Future<void> _discard(RenderedSpeech rendered) async {
    try {
      await synthesiser.discard(rendered);
    } catch (_) {
      // discard is documented as never throwing, but a stop path is no place
      // to find out that an implementation disagrees.
    }
  }
}
