/// The shared contract for read-aloud that survives the screen turning off.
///
/// **Why a contract rather than one class.** Read-aloud cannot be one
/// implementation, because the platforms disagree about what is even possible:
///
///   * `just_audio` 0.10.6 and `audio_service` 0.18.19 — the only route to
///     lock-screen controls, headphone buttons and playback with the screen off
///     — ship for **android, ios, macos and web only**. Not Linux, not Windows.
///   * `flutter_tts` 4.2.5 can render text to a file with
///     `synthesizeToFile(text, fileName)` on **android, ios, macos, windows and
///     web**. Not Linux.
///   * Piper and speech-dispatcher are **subprocesses**: fine on Linux, macOS
///     and Windows, impossible inside an iOS or Android sandbox.
///
/// There is no overlap that covers everything, so the app runs two pipelines
/// (see [SpeechBackend]) behind the interfaces below. What must *not* fork is
/// the behaviour the reader UI depends on: strict order, a correct highlight
/// index, a cheap stop, and no orphaned audio in the temp directory.
///
/// **What the existing `TtsService` guarantees, restated as types.** This file
/// is the target shape for that engine, not a replacement for its promises:
///
///   | `TtsService` today            | here                                     |
///   |-------------------------------|------------------------------------------|
///   | `onSegment(int? index)`       | [SpeechPipeline.onUnitStarted] carrying a [SpeechUnit] |
///   | `onPageFinished`             | [SpeechPipeline.onQueueFinished]         |
///   | the `_session` int guard      | [SpeechQueue.id] on every status event   |
///   | `stopAfterCurrentSegment()`  | [SpeechQueuePlayer.stopAfterCurrentUnit] |
///   | `canStopCleanly`             | [SpeechQueuePlayer.canStopCleanly]       |
///   | `onBoundaryStop`             | [SpeechPipeline.onBoundaryStop]          |
///   | `setVolume()` for the fade    | [SpeechQueuePlayer.setVolume]            |
///   | temp WAV cleanup              | [SpeechQueuePlayer.released] + [SpeechSynthesiser.discard] |
///
/// Nothing in this file synthesises, plays or touches a plugin. It is
/// abstract classes, plain data and the rules that bind them.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. The unit of speech
// ─────────────────────────────────────────────────────────────────────────────

/// One sentence, and where in the book it lives.
///
/// **This is the smallest thing the app will ever speak, and it is deliberately
/// exactly what the UI highlights.** Merging several sentences into one
/// synthesis call is cheaper and sounds no worse — `TtsService._chunk` does
/// precisely that for the whole-page path — but it destroys the follow-along
/// highlight, because there is then no index to report when the audio for
/// sentences 4, 5 and 6 starts. A pipeline built on this contract renders one
/// unit per sentence and pays the extra process launches.
///
/// **[sentenceIndex] is an address, not a queue position.** It indexes the
/// sentence list of [page] as the reader split it (`PageSpeech.segments`), and
/// it is what `onSegment` must report so the right span lights up. The queue
/// may be rebuilt, reordered, truncated, restarted from the middle after a
/// lock-screen resume, or re-rendered at a new speech rate — none of that moves
/// a sentence on its page, so none of it may change this number. Reporting a
/// queue position instead is the single easiest way to highlight the wrong
/// sentence, and the bug is invisible until the queue is rebuilt.
@immutable
class SpeechUnit {
  const SpeechUnit({
    required this.page,
    required this.sentenceIndex,
    required this.text,
  });

  /// 1-based page number, matching the reader's own page numbering.
  final int page;

  /// Index into that page's sentence list. Drives the highlight and the
  /// auto-scroll; a wrong value here highlights the wrong sentence.
  final int sentenceIndex;

  /// Cleaned, ready to hand to a synthesiser. Cleaning (re-joining hyphenated
  /// line breaks, dropping stranded page numbers) happens before a unit is
  /// built, so a unit is never re-processed and two units are never compared
  /// on differently cleaned text.
  final String text;

  /// Stable identity across every rebuild of a queue.
  ///
  /// A queue assembled twice for the same passage produces equal ids, so
  /// already-rendered audio can be matched to the new queue instead of being
  /// synthesised again — the difference between an instant resume and a
  /// second of silence after every skip.
  String get id => 'p$page.s$sentenceIndex';

  /// Reading order between two units. Ascending page, then ascending sentence.
  ///
  /// Exposed so a queue can be *asserted* sorted rather than assumed. A queue
  /// that arrives out of order scrambles the book and nothing downstream can
  /// detect it.
  int compareTo(SpeechUnit other) => page != other.page
      ? page.compareTo(other.page)
      : sentenceIndex.compareTo(other.sentenceIndex);

  @override
  bool operator ==(Object other) =>
      other is SpeechUnit &&
      other.page == page &&
      other.sentenceIndex == sentenceIndex;

  // Text is deliberately excluded: identity is the position in the book. Two
  // renders of the same sentence at different rates are the same unit.
  @override
  int get hashCode => Object.hash(page, sentenceIndex);

  @override
  String toString() => 'SpeechUnit($id)';
}

/// An ordered run of units, plus the generation counter that supersedes it.
///
/// **[id] is the `_session` guard, made explicit.** Every status event and
/// every completed render carries the id of the queue it belongs to; anything
/// whose id is not the current one is dropped silently. That is what lets a
/// `stop()` or a newer `speak()` return instantly while synthesis processes
/// already launched wind down on their own — without it, an in-flight render
/// completing after a stop resumes playback the user has already ended.
///
/// **[units] must be in reading order.** `Concurrency.mapBounded` preserves
/// input order precisely because a list built from completion order would
/// silently shuffle a book; the same rule applies here, one layer up.
@immutable
class SpeechQueue {
  const SpeechQueue({
    required this.id,
    required this.units,
    this.startAt = 0,
  });

  /// Monotonic per-engine generation. Higher supersedes lower.
  final int id;

  /// Reading order, sorted by [SpeechUnit.compareTo]. Never completion order.
  final List<SpeechUnit> units;

  /// Where playback begins — a skip, a tap on the page, or a sleep-timer
  /// resume lands here. The units before it stay in the queue so a backwards
  /// skip has somewhere to go without a rebuild.
  final int startAt;

  int get length => units.length;
  bool get isEmpty => units.isEmpty;

  SpeechUnit? unitAt(int index) =>
      index >= 0 && index < units.length ? units[index] : null;

  /// Position of [unitId] in this queue, or -1.
  ///
  /// The bridge back from an identity to a position after a rebuild: given the
  /// unit that was playing, find where it now sits so playback can continue
  /// from the same sentence rather than from the top.
  int indexOfUnit(String unitId) =>
      units.indexWhere((unit) => unit.id == unitId);

  /// True when the units are in reading order with no duplicates.
  ///
  /// Cheap enough to assert on construction in debug builds. Order is
  /// load-bearing and an unsorted queue has no other symptom than a book read
  /// out of sequence.
  bool get isOrdered {
    for (var i = 1; i < units.length; i++) {
      if (units[i - 1].compareTo(units[i]) >= 0) return false;
    }
    return true;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Synthesis: text → an audio file
// ─────────────────────────────────────────────────────────────────────────────

/// A voice a [SpeechSynthesiser] can speak with.
///
/// [id] is whatever the engine wants back: a Piper model name
/// (`en_US-lessac-medium`), or a `flutter_tts` voice map's name/locale pair
/// flattened. Deliberately opaque to callers — the UI shows [name] and stores
/// [id].
@immutable
class SpeechVoice {
  const SpeechVoice({
    required this.id,
    required this.name,
    this.locale,
    this.isNeural = false,
  });

  final String id;
  final String name;
  final String? locale;

  /// True for Piper and the platform neural voices; false for espeak-ng. Worth
  /// surfacing because the quality gap over a whole chapter is enormous, and a
  /// user who does not know a better voice exists will not go looking.
  final bool isNeural;

  @override
  String toString() => 'SpeechVoice($id)';
}

/// Audio on disk for exactly one [SpeechUnit].
///
/// **Ownership is the point of this class.** A rendered file is a temp file
/// somebody has to delete, and both failure modes are real: delete it too early
/// and the player is holding an open handle to nothing, never delete it and
/// `/tmp` fills with one WAV per sentence of a book nobody finished. The rule
/// is stated once, here: from the moment a [RenderedSpeech] is handed to
/// [SpeechQueuePlayer.supply] the player owns the file, and it releases it on
/// [SpeechQueuePlayer.released]. Everything else — a render that completed
/// after a stop, a look-ahead render for a queue that was superseded — never
/// reaches the player and is the caller's to [SpeechSynthesiser.discard].
@immutable
class RenderedSpeech {
  const RenderedSpeech({
    required this.unit,
    required this.queueId,
    required this.path,
    required this.voiceId,
    required this.rate,
    this.duration,
  });

  final SpeechUnit unit;

  /// The generation this was rendered for. A render arriving with a stale id is
  /// discarded rather than played.
  final int queueId;

  /// Absolute path to a playable file. Format is the engine's business — WAV
  /// from Piper, whatever `synthesizeToFile` produces on mobile.
  final String path;

  /// Which voice produced it, so a voice change can invalidate look-ahead audio
  /// instead of speaking two sentences in two different voices.
  final String voiceId;

  /// The app's 0.1–1.0 rate this was rendered at.
  ///
  /// Only meaningful when [SpeechSynthesiser.bakesRateIntoAudio] is true. Piper
  /// applies rate as `--length-scale` at synthesis, so a rate change invalidates
  /// everything already rendered ahead — which is exactly why
  /// `ReaderPlayback.setSpeechRate` restarts the current sentence rather than
  /// letting the change land three sentences later.
  final double rate;

  /// Filled in once known. Needed for the lock screen's scrubber and for
  /// [NowPlaying.duration]; null until the player opens the file.
  final Duration? duration;

  /// True when this audio is still valid for the given settings.
  bool matches({required String voiceId, required double rate}) =>
      this.voiceId == voiceId && (this.rate - rate).abs() < 0.001;
}

/// Turns one [SpeechUnit] into one audio file.
///
/// **Deliberately not "speak".** Every background-capable path on mobile is
/// render-then-play: `flutter_tts.speak` cannot be driven by `audio_service`,
/// cannot be seeked, cannot be resumed from a lock screen and stops when the
/// screen does. A file can do all four. The desktop path already works this way
/// because Piper only ever writes WAVs.
///
/// **Implementations and the platforms they serve:**
///
///   * `FlutterTtsSynthesiser` — android, ios, macos, windows (and web, though
///     the app does not target it). Wraps `setVoice` + `setSpeechRate` +
///     `synthesizeToFile`. **Not Linux:** flutter_tts has no Linux
///     implementation and fails silently there, which looks exactly like a
///     broken Play button.
///   * `PiperSynthesiser` — linux, windows, macos. Wraps the existing
///     `PiperTts.synthesise`, one subprocess per unit, one core per process.
///   * `SpeechDispatcherSynthesiser` — linux fallback when Piper is absent.
///     Note it *cannot* implement this interface honestly: `spd-say` speaks,
///     it does not render, so it reports [canRenderToFile] false and the
///     pipeline falls back to whole-page speech with no follow-along.
abstract class SpeechSynthesiser {
  /// For the settings screen: "Piper (neural)", "System voice", "espeak-ng".
  String get engineName;

  /// **The capability probe.** Whether this engine can be used *here, now* —
  /// binary present, at least one voice installed, platform supported.
  ///
  /// Async because answering it means touching the filesystem or the platform
  /// channel. Cache the result; do not call it per sentence. The UI disables
  /// Play on false rather than offering a button that does nothing.
  Future<bool> isAvailable();

  /// Why it is unavailable, in words a user can act on — typically the install
  /// command. Only read when [isAvailable] is false.
  String get unavailableMessage;

  /// False for engines that only speak aloud (`spd-say`). A pipeline needs a
  /// file to get background playback, ordered queueing or a seekable position,
  /// so false means the degraded path: no highlight, no seek, no lock screen.
  bool get canRenderToFile;

  /// True when the speech rate is applied during synthesis and is therefore
  /// frozen into the audio (Piper's `--length-scale`, `flutter_tts`'
  /// `setSpeechRate`). When true, a rate change must invalidate every
  /// look-ahead render; when false the player can retime the audio instead —
  /// see [SpeechQueuePlayer.supportsPlaybackSpeed].
  bool get bakesRateIntoAudio => true;

  /// Voices installed right now. May be empty, which is a legitimate reason for
  /// [isAvailable] to be false.
  Future<List<SpeechVoice>> voices();

  /// Render [unit] to [outputPath].
  ///
  /// **Callers may run several of these at once and must not infer order from
  /// completion.** Renders finish out of order — a short sentence overtakes a
  /// long one, a warm engine overtakes a cold one — and the queue position, not
  /// the completion order, decides what is heard next.
  ///
  /// [outputPath] is chosen by the caller so cleanup is the caller's to reason
  /// about. It should carry the process id as well as [SpeechQueue.id]: the
  /// generation counter restarts at zero in every process, so two running
  /// copies of the app otherwise render to byte-identical paths and eat each
  /// other's audio.
  ///
  /// Throws on failure. A failed unit is skipped by the pipeline rather than
  /// ending playback — one bad sentence must not end a chapter.
  Future<RenderedSpeech> render(
    SpeechUnit unit, {
    required SpeechQueue queue,
    required SpeechVoice voice,
    required double rate,
    required String outputPath,
  });

  /// Delete audio that will never be heard.
  ///
  /// Called for renders that completed after their queue was superseded, and
  /// for the look-ahead window abandoned by a stop. Must tolerate a missing
  /// file, a file still being written, and being called twice for the same
  /// render. Must never throw: it runs in `finally` blocks on the stop path.
  Future<void> discard(RenderedSpeech rendered);

  /// Delete leftovers from earlier runs of this app that no live pipeline owns
  /// — a crash or a kill leaves the last look-ahead window on disk, and nothing
  /// else will ever come back for it. Called once at startup, best-effort.
  Future<void> sweepOrphans();
}

/// How far ahead of the playhead to render, and how much at once.
///
/// **Both halves matter and they pull in opposite directions.** Rendering only
/// the sentence being played means every gap between sentences is a synthesis
/// pause; on a busy machine or a large voice model it is audible, and a
/// paragraph reads like a bad phone line. Rendering the whole chapter up front
/// means ten seconds of spinner before any sound, a saturated CPU behind a page
/// the user is still trying to read, and — the common case — a hundred WAVs
/// deleted unheard when they stop after the first sentence.
///
/// So: a small sliding window, refilled as the playhead advances, capped by a
/// semaphore well below the CPU pool.
@immutable
class SpeechRenderPolicy {
  const SpeechRenderPolicy({
    this.lookAhead = defaultLookAhead,
    this.maxConcurrentRenders = defaultConcurrency,
  });

  /// Units kept rendering ahead of the one playing.
  ///
  /// One is enough only while synthesis is faster than playback; a long
  /// sentence, a bigger model or a busy machine tips that over and the gap is
  /// audible. Two absorbs the wobble. This is the value `TtsService` arrived at.
  static const defaultLookAhead = 2;

  /// Synthesis is CPU-bound — Piper spends a whole core per process — so this
  /// sits far below `Concurrency.cpuPool`. The point of rendering ahead is
  /// unbroken audio, not a busy machine behind a page that has stopped
  /// scrolling smoothly.
  static const defaultConcurrency = 2;

  final int lookAhead;
  final int maxConcurrentRenders;

  /// Clamped so a stored setting cannot turn the window into a chapter.
  SpeechRenderPolicy get sanitised => SpeechRenderPolicy(
        lookAhead: lookAhead.clamp(1, 4),
        maxConcurrentRenders: maxConcurrentRenders.clamp(1, 4),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Playback: an ordered queue of rendered audio
// ─────────────────────────────────────────────────────────────────────────────

/// What the player is doing.
///
/// [preparing] is a state of its own because the first render takes a second or
/// more, and a Play button that stays a spinner with no explanation is the
/// commonest way this pipeline looks broken.
enum SpeechPlaybackState { idle, preparing, playing, paused, completed }

/// A snapshot of the player, carrying the *unit* rather than a queue position.
///
/// **[unit] is what the UI highlights.** The player knows its own queue index
/// and exposes it as [queueIndex] for transport arithmetic only. Anything
/// user-visible reads `unit.sentenceIndex` and `unit.page`, which survive the
/// queue being rebuilt, reordered, truncated or restarted from a lock-screen
/// resume — the queue index does not.
///
/// **[queueId] is the guard.** A status event whose [queueId] is older than the
/// live queue is stale — it belongs to a run that a stop or a newer speak has
/// already superseded — and must be dropped, not rendered.
@immutable
class SpeechPlayerStatus {
  const SpeechPlayerStatus({
    required this.queueId,
    required this.state,
    this.unit,
    this.queueIndex,
    this.position = Duration.zero,
    this.duration,
    this.volume = 1.0,
    this.stopAfterCurrent = false,
  });

  const SpeechPlayerStatus.idle()
      : queueId = 0,
        state = SpeechPlaybackState.idle,
        unit = null,
        queueIndex = null,
        position = Duration.zero,
        duration = null,
        volume = 1.0,
        stopAfterCurrent = false;

  final int queueId;
  final SpeechPlaybackState state;

  /// The unit actually audible now, or null when nothing is.
  ///
  /// Null clears the highlight. Note the trap `ReaderPlayback.noteSpoken`
  /// already documents: a null here must not overwrite the caller's stored
  /// resume position, or pausing (which is a stop on some backends) destroys
  /// the very cursor Play needs.
  final SpeechUnit? unit;

  /// Position of [unit] in the live queue. For transport arithmetic only —
  /// never report this to the UI as a sentence index.
  final int? queueIndex;

  /// Within the current unit.
  final Duration position;
  final Duration? duration;

  final double volume;

  /// True once [SpeechQueuePlayer.stopAfterCurrentUnit] has been asked for and
  /// the current unit has not yet ended.
  final bool stopAfterCurrent;

  bool get isPlaying => state == SpeechPlaybackState.playing;
  bool get isPaused => state == SpeechPlaybackState.paused;
  bool get isPreparing => state == SpeechPlaybackState.preparing;
}

/// Plays rendered units **in queue order**, and says which one is audible.
///
/// **Order is the whole job.** Audio arrives from synthesis out of order; this
/// interface exists so that never reaches the ear. [supply] hands the player
/// audio whenever it happens to be ready, and the player still plays position 0
/// then 1 then 2 — waiting, in [SpeechPlaybackState.preparing], if the next
/// unit's audio has not landed yet. An implementation that plays whatever is
/// ready is not an implementation of this interface.
///
/// **Implementations and the platforms they serve:**
///
///   * `BackgroundQueuePlayer` — android, ios, macos. `just_audio`'s
///     `ConcatenatingAudioSource` inside an `audio_service` `BaseAudioHandler`.
///     This is the only implementation that gives screen-off playback,
///     lock-screen controls and headphone buttons; it is the reason for the
///     render-to-file design. Its `currentIndexStream` maps back to a unit
///     through the queue, never straight to the UI.
///   * `SubprocessQueuePlayer` — linux, windows. One `pw-play`/`ffplay`/`paplay`
///     process per unit, awaited to completion, exactly as `TtsService._play`
///     does today. It gets no lock screen and needs none: the process keeps
///     running with the screen off, and `Wakeful` already prevents idle suspend.
///     Volume scales differ per tool and are handled in `PiperTts.playerArgs`
///     (`pw-play` takes 0.0–1.0, `paplay` takes 0–65536) — a wrong scale is
///     silently clamped, so the fade simply never happens.
abstract class SpeechQueuePlayer {
  /// Status changes. Must emit at least on every unit change, every state
  /// change, and periodically while playing so a lock-screen scrubber moves.
  Stream<SpeechPlayerStatus> get statusStream;

  /// The latest status, for synchronous reads during a build.
  SpeechPlayerStatus get status;

  /// Files the player has finished with and will not open again.
  ///
  /// The other half of the ownership rule stated on [RenderedSpeech]: a
  /// listener deletes what appears here and nothing else. Also emits units
  /// dropped by a [stop] or a [open] that superseded them — otherwise a skip
  /// during playback strands one file per queued unit.
  Stream<RenderedSpeech> get released;

  /// Replace the queue. Supersedes anything playing.
  ///
  /// Takes the whole [SpeechQueue] rather than a list of files because the
  /// player needs [SpeechQueue.id] to stamp its status events, and the units to
  /// report — it starts with no audio at all and waits for [supply].
  Future<void> open(SpeechQueue queue);

  /// Hand over audio for a unit already in the open queue.
  ///
  /// Ignored (and immediately [released]) when [RenderedSpeech.queueId] is not
  /// the open queue's, or when the unit is no longer in it. May arrive in any
  /// order and at any time, including for a unit already played — that is a
  /// backwards skip re-using cached audio, not an error.
  Future<void> supply(RenderedSpeech rendered);

  Future<void> play();
  Future<void> pause();
  Future<void> resume();

  /// Stop and clear. Must be fast: it is on the path of every skip and every
  /// page turn, and it is what a user perceives as the app responding. Audio
  /// still rendering is not waited for — it is released as it settles.
  Future<void> stop();

  /// Seek within the current unit. Backends that cannot report or set a
  /// position report [supportsSeekWithinUnit] false and ignore this.
  Future<void> seek(Duration position);

  /// Move [delta] units through the queue, clamped to its bounds.
  ///
  /// Returns the unit landed on, or null when the queue is empty. Crossing the
  /// end of the queue is *not* handled here: only the reader knows where the
  /// next page starts, so the pipeline reports completion and the reader opens
  /// a new queue.
  Future<SpeechUnit?> skipUnits(int delta);

  /// Jump straight to a unit by identity, not by index.
  ///
  /// The lock-screen resume path and the sleep-timer resume path both come back
  /// with "the sentence on page 42 that was playing", never with a position in
  /// a queue that may since have been rebuilt.
  Future<bool> skipToUnit(String unitId);

  /// Whether this backend can end on a sentence boundary.
  ///
  /// False for anything handed a whole page in one call — `spd-say` has no
  /// boundary to end on and `flutter_tts.speak` gives no reliable per-sentence
  /// completion. For those, an honest hard stop beats pretending.
  bool get canStopCleanly;

  /// Finish the unit being spoken, then stop — the sleep timer's gentle ending.
  ///
  /// Cutting off mid-clause is what makes someone open their eyes. When
  /// [canStopCleanly] is false this degrades to an immediate [stop] rather than
  /// silently never stopping. The moment it takes effect is reported through
  /// [SpeechPipeline.onBoundaryStop], so the caller records where the voice
  /// actually ended instead of guessing.
  void stopAfterCurrentUnit();

  /// 0–1, applied at the player.
  ///
  /// **Not at synthesis**, so the sleep timer's fade costs nothing and does not
  /// invalidate a single unit already rendered ahead. Note `aplay` cannot be
  /// told a level at all: there the fade has no effect rather than failing, and
  /// the session still ends.
  Future<void> setVolume(double volume);

  /// True when the backend can retime audio during playback (`just_audio`'s
  /// `setSpeed`, which preserves pitch on android and ios).
  ///
  /// When true, a speech-rate change is a player call and the look-ahead window
  /// survives it. When false — every subprocess backend — the rate is frozen
  /// into the rendered files and a change means discarding the window and
  /// re-rendering from the current sentence.
  bool get supportsPlaybackSpeed;

  /// Ignored when [supportsPlaybackSpeed] is false.
  Future<void> setSpeed(double speed);

  bool get supportsSeekWithinUnit;

  Future<void> dispose();
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. What a lock screen or notification needs
// ─────────────────────────────────────────────────────────────────────────────

/// The metadata a lock screen, notification or car head unit shows.
///
/// Kept separate from [SpeechPlayerStatus] on purpose. The player knows about
/// units, files and positions; it does not know the book's author or where the
/// cover image is, and it must not have to. The pipeline joins the two.
///
/// **The subprocess backends have no consumer for this** — there is no Linux
/// lock screen to publish to — and that is fine: it is built either way and
/// simply goes nowhere. Making it conditional would mean the mobile path is the
/// only one ever exercised, which is how it rots.
@immutable
class NowPlaying {
  const NowPlaying({
    required this.title,
    required this.book,
    required this.playing,
    this.author,
    this.artwork,
    this.duration,
    this.position = Duration.zero,
    this.page,
    this.pageCount,
  });

  /// The line that reads as the "track": a chapter title where one is known,
  /// otherwise "Page 42". Never the sentence — it would change every few
  /// seconds and turn a lock screen into a strobe.
  final String title;

  /// The book, shown as the album.
  final String book;

  final String? author;

  /// Cover art, as a `file://` URI. Remote URLs are not used: the app is
  /// local-first and a lock screen is not a reason to make a network request.
  final Uri? artwork;

  /// Of the current unit, where known. A per-sentence scrubber is nearly
  /// useless to a listener, but the platform controls expect *something*, and
  /// leaving it null makes some of them hide the progress bar entirely.
  final Duration? duration;
  final Duration position;

  final bool playing;

  final int? page;
  final int? pageCount;
}

/// A button pressed somewhere this app does not draw.
///
/// Lock screen, notification, headphone remote, car head unit, Bluetooth
/// steering-wheel control. These arrive with the screen off and the reader
/// widget possibly disposed, which is why the pipeline — not a `State` — owns
/// the handling.
enum MediaCommand {
  play,
  pause,
  stop,

  /// Conventionally the next/previous *sentence*, matching the app's own skip
  /// controls, so a headphone double-tap does what the on-screen button does.
  next,
  previous,

  /// Carries a position; see [MediaCommandEvent.position].
  seek,

  /// Some head units send this for a long-press. Mapped to a page jump.
  fastForward,
  rewind,
}

/// A [MediaCommand] plus its argument.
@immutable
class MediaCommandEvent {
  const MediaCommandEvent(this.command, {this.position});

  final MediaCommand command;

  /// Set only for [MediaCommand.seek].
  final Duration? position;
}

/// Publishes [NowPlaying] outward and delivers remote commands back.
///
/// **Implementations and the platforms they serve:**
///
///   * `AudioServiceSession` — android, ios, macos. An `audio_service`
///     `BaseAudioHandler`; the notification, the lock screen and the headphone
///     buttons all come from here, and on android it is also what keeps the
///     process alive with the screen off.
///   * `NullMediaSession` — linux, windows. Accepts updates, emits nothing.
///     The desktop process keeps running regardless and `Wakeful` prevents idle
///     suspend, so there is nothing to publish to. (MPRIS would fit this
///     interface later; `MprisControl` already speaks it for *other* players.)
abstract class MediaSession {
  /// Idempotent and called often — every position tick. Implementations must
  /// diff rather than repost unchanged metadata, or android redraws the
  /// notification once a second.
  Future<void> update(NowPlaying state);

  /// Commands from outside the app.
  Stream<MediaCommandEvent> get commands;

  /// Tear down the notification. Leaving one behind after the book is closed is
  /// the sort of thing users uninstall over.
  Future<void> dispose();
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. Which implementation serves which platform
// ─────────────────────────────────────────────────────────────────────────────

/// The two pipelines, and the platforms each one is the only option for.
///
/// This enum exists so the split is a documented decision in one place rather
/// than a `Platform.isLinux` check scattered through the audio layer — which is
/// how the desktop path ends up half-implemented on mobile and vice versa.
enum SpeechBackend {
  /// **android, ios, macos.** `flutter_tts.synthesizeToFile` →
  /// [SpeechQueuePlayer] over `just_audio` → `audio_service`.
  ///
  /// The only configuration that gives playback with the screen off,
  /// lock-screen controls and headphone buttons. Piper cannot be used here:
  /// spawning a subprocess is impossible inside the iOS and Android sandboxes.
  renderAndBackgroundPlay(
    label: 'Rendered speech with background playback',
    hasMediaSession: true,
    usesSubprocesses: false,
  ),

  /// **linux, windows.** Piper (or `spd-say`) subprocesses → one player process
  /// per unit, the pipeline `TtsService` already runs.
  ///
  /// `just_audio` and `audio_service` do not build for Linux or Windows at all,
  /// and neither is needed: a desktop process keeps running with the screen
  /// off, and `Wakeful` already prevents idle suspend. On Linux `flutter_tts`
  /// is not an option either — it has no Linux implementation and fails
  /// silently, which is indistinguishable from a broken Play button.
  desktopSubprocess(
    label: 'Local synthesis with subprocess playback',
    hasMediaSession: false,
    usesSubprocesses: true,
  ),

  /// No workable combination. The UI disables Play and shows
  /// [SpeechSynthesiser.unavailableMessage] rather than offering a button that
  /// does nothing.
  unavailable(
    label: 'No speech engine',
    hasMediaSession: false,
    usesSubprocesses: false,
  );

  const SpeechBackend({
    required this.label,
    required this.hasMediaSession,
    required this.usesSubprocesses,
  });

  final String label;

  /// Whether a real [MediaSession] exists, or the null one is used.
  final bool hasMediaSession;

  /// Whether this backend shells out — which decides whether it can exist on
  /// mobile at all.
  final bool usesSubprocesses;

  /// The backend this platform *can* run. Says nothing about whether an engine
  /// is actually installed — that is [SpeechSynthesiser.isAvailable], and the
  /// resolved backend is [unavailable] only once that has answered false.
  ///
  /// Web is absent deliberately: the app is local-first and its library
  /// scanner needs a filesystem, so it is not a target despite the plugins
  /// supporting it.
  static SpeechBackend forPlatform() {
    if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
      return SpeechBackend.renderAndBackgroundPlay;
    }
    if (Platform.isLinux || Platform.isWindows) {
      return SpeechBackend.desktopSubprocess;
    }
    return SpeechBackend.unavailable;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The composition
// ─────────────────────────────────────────────────────────────────────────────

/// Binds a [SpeechSynthesiser], a [SpeechQueuePlayer] and a [MediaSession] into
/// the thing a reader screen actually drives.
///
/// **It owns the four rules the pieces cannot enforce alone:**
///
///  1. **Order.** Renders are launched concurrently and complete out of order;
///     the pipeline supplies them to the player and the player plays by
///     position. Nothing anywhere infers order from completion.
///  2. **Index.** [onUnitStarted] carries a [SpeechUnit], so the highlight is
///     driven by the sentence's own address on its page and survives the queue
///     being rebuilt, reordered, or restarted from a lock-screen resume.
///  3. **Look-ahead.** [SpeechRenderPolicy] keeps a small window rendering
///     ahead of the playhead and refills it as the playhead advances — never a
///     whole chapter, most of which nobody will hear.
///  4. **Cleanup.** Every rendered file is deleted: the ones the player
///     finishes with (via [SpeechQueuePlayer.released]) and the ones the window
///     abandoned when a stop or a newer queue superseded them. On every exit
///     path — stop, supersede, throw and dispose alike.
///
/// Its callbacks are named to match what `ReaderPlayback` already wires up, so
/// a reader can be moved onto this without changing how it follows along.
abstract class SpeechPipeline {
  SpeechSynthesiser get synthesiser;
  SpeechQueuePlayer get player;
  MediaSession get session;

  SpeechBackend get backend;

  /// The unit now audible, or null when speech stops.
  ///
  /// The direct replacement for `TtsService.onSegment`, carrying the unit
  /// instead of a bare int precisely so the index cannot drift from the page it
  /// belongs to.
  ValueChanged<SpeechUnit?>? onUnitStarted;

  /// The queue ran to its end — the reader's cue to turn the page and continue.
  /// Replaces `TtsService.onPageFinished`.
  ///
  /// Deliberately not fired when a boundary stop ended the run: auto-advance
  /// must stay put where the sleep timer left it.
  VoidCallback? onQueueFinished;

  /// A [SpeechQueuePlayer.stopAfterCurrentUnit] took effect, so the caller can
  /// record where the voice ended rather than guessing.
  VoidCallback? onBoundaryStop;

  /// Speak [queue], from [SpeechQueue.startAt].
  ///
  /// Supersedes any run in flight: the older generation's in-flight renders
  /// exit quietly and their files are discarded. Returns as soon as the run is
  /// established, not when it finishes — completion arrives on
  /// [onQueueFinished].
  Future<void> speak(SpeechQueue queue);

  Future<void> pause();
  Future<void> resume();

  /// Stop, clear the queue, discard the window. Must feel instant: a render
  /// already running cannot be hurried, so its file is deleted as it settles,
  /// long after this has returned.
  Future<void> stop();

  /// Metadata for the lock screen. The pipeline merges this with live position
  /// and playing state before handing it to [session].
  Future<void> setNowPlaying(NowPlaying state);

  SpeechRenderPolicy get policy;
  set policy(SpeechRenderPolicy value);

  Future<void> dispose();
}
