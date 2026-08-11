/// Playback that survives the screen turning off, on android, ios and macOS.
///
/// **What this is.** The [SpeechQueuePlayer] and the [MediaSession] halves of
/// `speech_pipeline.dart`, implemented once as a single `audio_service`
/// [BaseAudioHandler] driving one `just_audio` [AudioPlayer]. It is handed audio
/// that has *already been synthesised* — this file never speaks, never renders
/// and never touches a text-to-speech engine. It puts files in the right order,
/// keeps the notification honest about what is playing, and tells the app which
/// sentence is audible so the page can follow along.
///
/// **Why the player and the session are one object.** `audio_service` delivers
/// lock-screen, headset and Android Auto commands to an [AudioHandler], and the
/// only sane place to service them is the object that owns the player: the
/// commands arrive with the screen off and the reader widget quite possibly
/// disposed, so anything that routes through a `State` is already too late.
/// Splitting them would mean a handler that forwards every call to a player and
/// a player that calls back to publish state — the same object with a seam
/// through it.
///
/// **The two rules that make the highlight correct.**
///
///  1. *Identity travels with the audio.* Every source appended to `just_audio`
///     carries a [_UnitTag] naming its [SpeechUnit] and the [SpeechQueue.id] it
///     was queued for. What is playing is read back off the tag, never computed
///     from a bare `currentIndex`. A stale event from a playlist that has since
///     been replaced therefore identifies itself as stale instead of pointing at
///     whatever sentence now occupies that slot — the exact bug that silently
///     highlights the wrong line after a page turn.
///  2. *The playlist is a contiguous run.* Renders complete out of order; the
///     playlist only ever grows by the next unit in reading order, so what the
///     player can reach is always the book's order and nothing downstream has to
///     re-sort it.
///
/// **Where it does nothing.** Neither plugin builds for Linux or Windows, so
/// [BackgroundAudioHandler.unavailable] exists: it constructs, reports
/// [available] false, and every method is a no-op. Desktop keeps the subprocess
/// pipeline, which needs no notification because the process keeps running with
/// the screen off anyway.
library;

import 'dart:async';
import 'dart:io' show File;
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'speech_pipeline.dart';

/// Plays rendered speech in queue order, with a lock screen attached.
///
/// Implements both [SpeechQueuePlayer] and [MediaSession] so one instance can
/// fill both slots of a `SpeechPipeline`.
class BackgroundAudioHandler extends BaseAudioHandler
    implements SpeechQueuePlayer, MediaSession {
  BackgroundAudioHandler._()
      : _player = AudioPlayer(
          // A single unreadable file — a truncated render, a synthesiser killed
          // mid-write — must cost one sentence, not the rest of the chapter.
          // The skip lands on the next unit and the tag makes the highlight
          // follow it, so the listener hears a gap rather than silence.
          maxSkipsOnError: 3,
          // Left on deliberately: a phone call or a navigation prompt should
          // duck and resume without the reader knowing. Turning this off means
          // reimplementing audio_session by hand for no gain.
          handleInterruptions: true,
        ),
        _unavailableReason = null {
    _attach();
  }

  /// A handler for a platform where `audio_service` does not exist.
  ///
  /// Constructing must never throw: this is created during app start-up on
  /// Linux and Windows too, where the answer is simply "not here". Every method
  /// below returns early, [status] stays [SpeechPlayerStatus.idle] and
  /// [available] is false, so a caller can hold one without checking the
  /// platform at every call site.
  BackgroundAudioHandler.unavailable([String? reason])
      : _player = null,
        _unavailableReason = reason ??
            'Background playback needs audio_service, which has no '
                '${defaultTargetPlatform.name} implementation.';

  // ── platform ──

  /// Whether this platform can run background playback at all.
  ///
  /// Deferred to [SpeechBackend.forPlatform] rather than re-testing `Platform`
  /// here, so the split stays a single documented decision.
  static bool get isSupported => SpeechBackend.forPlatform().hasMediaSession;

  /// How far [fastForward] and [rewind] move when nothing is listening for the
  /// command. Also the interval published to the platform, so a head unit's
  /// long-press and our own fallback agree.
  static const skipInterval = Duration(seconds: 30);

  static Future<BackgroundAudioHandler>? _starting;

  /// Bring up the media session, or report that this platform has none.
  ///
  /// **Call once, before `runApp`.** `AudioService.init` asserts it has not run
  /// before, installs the platform callbacks and — on Android — is what binds
  /// the foreground service that keeps the isolate alive with the screen off.
  /// The future is cached so a second call during a hot restart or from a second
  /// entry point returns the same handler instead of tripping that assert.
  ///
  /// Never throws. A misconfigured manifest surfaces as a [PlatformException]
  /// from `init`, and taking down app start-up over a missing lock screen is a
  /// worse failure than reading without one — so the error is kept in
  /// [unavailableReason] and printed in debug, and the app gets a handler that
  /// honestly reports itself unavailable.
  static Future<BackgroundAudioHandler> start({
    String androidNotificationChannelId =
        'com.personal.audiobook_reader.speech',
    String androidNotificationChannelName = 'Read aloud',
    Color? notificationColour,
  }) {
    return _starting ??= _start(
      androidNotificationChannelId,
      androidNotificationChannelName,
      notificationColour,
    );
  }

  static Future<BackgroundAudioHandler> _start(
    String channelId,
    String channelName,
    Color? colour,
  ) async {
    if (!isSupported) return BackgroundAudioHandler.unavailable();
    try {
      // Tell the OS this is spoken-word audio before anything plays. On iOS it
      // is what allows sound with the screen locked at all, and it is why a
      // navigation prompt ducks the voice instead of killing the session.
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.speech());

      return await AudioService.init<BackgroundAudioHandler>(
        builder: BackgroundAudioHandler._,
        config: AudioServiceConfig(
          // A channel of our own, named for what it is. Android shows this
          // string in the user's notification settings, so "Notifications" —
          // the package default — is what a user turns off by mistake.
          androidNotificationChannelId: channelId,
          androidNotificationChannelName: channelName,
          androidNotificationChannelDescription:
              'Controls for the book being read aloud.',
          notificationColor: colour,
          androidNotificationIcon: 'mipmap/ic_launcher',
          // The notification *is* the foreground service while speech is
          // running; making it non-dismissable is what stops a tidy-minded
          // swipe from killing playback mid-chapter. Paired with
          // androidStopForegroundOnPause below, which audio_service asserts on:
          // once paused the service drops out of the foreground and the
          // notification becomes swipeable again, so a finished session leaves
          // nothing behind.
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationClickStartsActivity: true,
          androidResumeOnClick: true,
          androidShowNotificationBadge: false,
          // Long-press on a head unit and the seek buttons on a watch use
          // these. Thirty seconds is a paragraph or so of speech; the ten
          // second default is barely a sentence and makes the control feel
          // broken.
          fastForwardInterval: skipInterval,
          rewindInterval: skipInterval,
          // Artwork is a local `file://` cover. Preloading exists to warm a
          // *network* fetch, which this app never makes, and it would put a
          // download manager in the start-up path for nothing.
          preloadArtwork: false,
          // Covers are book-sized scans. Handing a multi-megapixel bitmap to
          // the lock screen is how a media session runs out of binder buffer.
          artDownscaleWidth: 400,
          artDownscaleHeight: 400,
        ),
      );
    } catch (error) {
      debugPrint('audio_service unavailable: $error');
      return BackgroundAudioHandler.unavailable('$error');
    }
  }

  // ── state ──

  /// Null exactly when this handler is the unavailable one.
  final AudioPlayer? _player;

  final String? _unavailableReason;

  /// Broadcast: the pipeline follows it, and so may Car Mode. Dropping events
  /// while nobody listens is harmless — every one of them is a snapshot.
  final _status = StreamController<SpeechPlayerStatus>.broadcast();

  /// Deliberately *not* broadcast. This stream is an ownership transfer, not a
  /// notification: exactly one listener may take the files, and events buffer
  /// until it subscribes so a pipeline that attaches a moment late does not
  /// leak the audio released before it got there.
  late final StreamController<RenderedSpeech> _released =
      StreamController<RenderedSpeech>(onListen: _pendingRelease.clear);

  /// Files released before anyone ever subscribed to [released]. Deleted
  /// directly at [dispose] — see [_release].
  final _pendingRelease = <RenderedSpeech>[];

  final _commands = StreamController<MediaCommandEvent>.broadcast();

  final _subscriptions = <StreamSubscription<dynamic>>[];

  SpeechPlayerStatus _last = const SpeechPlayerStatus.idle();

  SpeechQueue? _queue;

  /// Rendered audio per queue index, whether or not it has reached the playlist.
  /// Same length as the open queue; null where nothing has been supplied yet.
  List<RenderedSpeech?> _slots = <RenderedSpeech?>[];

  /// Queue index of playlist position 0.
  ///
  /// The playlist holds queue indices `[_runStart, _runStart + _appended)` and
  /// nothing else, in order. These two numbers are the whole mapping between
  /// `just_audio` positions and positions in the book.
  ///
  /// **A live playlist only ever grows at the end.** Appending leaves every
  /// existing position where it was; removing from the front does not, and the
  /// player's own `currentIndex` is a platform value that lags the change by a
  /// round trip — so for that moment a stale index, clamped into the shortened
  /// list, names a different sentence. Played audio is therefore held to the end
  /// of the queue rather than trimmed as the playhead advances, which bounds the
  /// temp files at one queue's worth (a page) and releases them at [open] or
  /// [stop].
  int _runStart = 0;
  int _appended = 0;

  /// The unit being played, or the one being waited for while starved. This —
  /// not `player.currentIndex` — is what the app is told about.
  int _playhead = 0;

  /// A deliberate jump is in flight and the player has not confirmed it.
  ///
  /// Set whenever the playlist is rebuilt or seeked across. Until a sequence
  /// event names the unit we jumped to, every other event is ignored: the
  /// platform's index lags a rebuild, and believing it would move the highlight
  /// to whatever sentence now sits at the old position.
  bool _awaitingSeek = false;

  /// When that jump was issued. The confirmation is one platform round trip
  /// away; [_seekSettle] later, a disagreement is no longer lag.
  DateTime? _seekAt;

  static const _seekSettle = Duration(seconds: 2);

  /// Whether the player's current source *is* the playhead.
  ///
  /// Tracked rather than read back, because the only readable answer —
  /// `player.currentIndex` — lags playlist changes. It decides whether resuming
  /// needs a seek, and getting it wrong is audible: seek on every resume and
  /// pause becomes "start this sentence again".
  bool _atPlayhead = false;

  /// Play intent, which outlives a starved playlist. Without it a gap in the
  /// rendered audio would read as a pause and playback would never resume by
  /// itself when the missing render landed.
  bool _wantPlaying = false;

  bool _stopAfterCurrent = false;

  /// The queue ran to its end. Distinct from idle, because it is the reader's
  /// cue to turn the page.
  bool _finished = false;

  /// `just_audio` reports completion repeatedly; the end of a queue must be
  /// acted on once.
  bool _handledCompletion = false;

  double _volume = 1.0;

  NowPlaying? _nowPlaying;
  MediaItem? _publishedItem;

  Timer? _ticker;

  /// A boundary stop took effect — the sleep timer's gentle ending landed.
  ///
  /// **Not part of the [SpeechQueuePlayer] contract**, which has no way to say
  /// this: it offers `stopAfterCurrentUnit()` and a `stopAfterCurrent` flag on
  /// the status, leaving a listener to infer the moment from a flag going true
  /// and then a state going idle — indistinguishable from an ordinary stop that
  /// happened to arrive first. `SpeechPipeline.onBoundaryStop` needs the actual
  /// moment, so it is exposed here and the pipeline should forward it.
  VoidCallback? onBoundaryStop;

  /// A remote control changed the playback speed.
  ///
  /// **Also outside the contract**: [MediaCommand] has no `setSpeed` member, yet
  /// iOS and Android Auto both offer a speed control. The change is applied to
  /// the player here; this callback is how the app's stored rate follows it
  /// instead of silently disagreeing with what is being heard.
  ValueChanged<double>? onSpeedRequested;

  /// False on Linux and Windows, and after a failed `AudioService.init`.
  bool get available => _player != null;

  /// Why [available] is false. Null when it is true.
  String? get unavailableReason => _unavailableReason;

  // ── SpeechQueuePlayer: the queue ──

  @override
  Stream<SpeechPlayerStatus> get statusStream => _status.stream;

  @override
  SpeechPlayerStatus get status => _last;

  @override
  Stream<RenderedSpeech> get released => _released.stream;

  @override
  Future<void> open(SpeechQueue queue) async {
    final player = _player;
    if (player == null) return;
    assert(
      queue.isOrdered,
      'a queue out of reading order reads the book out of order',
    );

    // Everything the previous queue held is audio nobody will hear again: the
    // playlist is about to be replaced and the slots with it. Released before
    // the fields are reset, or the paths are lost and the files stay in /tmp.
    _releaseAll();

    await player.stop();
    await player.clearAudioSources();

    _queue = queue;
    _slots = List<RenderedSpeech?>.filled(queue.length, null);
    _playhead = queue.startAt.clamp(0, queue.isEmpty ? 0 : queue.length - 1);
    _runStart = _playhead;
    _appended = 0;
    _stopAfterCurrent = false;
    _finished = false;
    _handledCompletion = false;
    _awaitingSeek = true;
    _atPlayhead = false;
    _seekAt = DateTime.now();
    // Play intent is deliberately left alone: `speak()` is open-then-play, and
    // clearing it here would make the pipeline's play() race its own open().
    _emit();
  }

  @override
  Future<void> supply(RenderedSpeech rendered) async {
    final queue = _queue;
    if (_player == null || queue == null) {
      _release(rendered);
      return;
    }
    // The generation guard, doing the job the `_session` int does in
    // TtsService: a render that finished after its queue was superseded must
    // never reach the ear, and its file must not be left behind either.
    if (rendered.queueId != queue.id) {
      _release(rendered);
      return;
    }
    // Truncated for a boundary stop: taking more audio now would undo it.
    if (_stopAfterCurrent) {
      _release(rendered);
      return;
    }
    final index = queue.indexOfUnit(rendered.unit.id);
    if (index < 0) {
      _release(rendered);
      return;
    }

    final held = _slots[index];
    if (held != null) {
      // Already queued for playback: the playlist holds an open handle to the
      // held file, so the newcomer is the one to go.
      if (_positionOf(index) != null) {
        _release(rendered);
        return;
      }
      // Not queued yet, so the fresher render wins — this is a re-render after
      // a voice or rate change, and the older file would speak in the old voice.
      _release(held);
    }
    _slots[index] = rendered;
    await _drain();
  }

  /// Append every unit that is ready, in order, and stop at the first gap.
  ///
  /// The gap is the point: a unit whose audio has not landed blocks everything
  /// behind it, which is what keeps playback in reading order no matter what
  /// order the renders complete in.
  Future<void> _drain() async {
    final player = _player;
    final queue = _queue;
    if (player == null || queue == null || _stopAfterCurrent) return;

    // A run always begins at the playhead. Audio for units before it stays in
    // its slot, reachable by a backwards skip, but must not be appended — that
    // would play the page from the wrong sentence.
    if (_appended == 0) _runStart = _playhead;

    var appended = false;
    while (_runStart + _appended < queue.length) {
      final index = _runStart + _appended;
      final rendered = _slots[index];
      if (rendered == null) break;
      await player.addAudioSource(
        AudioSource.file(
          rendered.path,
          tag: _UnitTag(queue.id, index, rendered.unit),
        ),
      );
      _appended++;
      appended = true;
    }
    if (!appended) return;

    // New audio after the player ran out means the end of the playlist is no
    // longer the end of the queue.
    _handledCompletion = false;
    await _ensurePlaying();
    _emit();
  }

  // ── SpeechQueuePlayer: transport ──

  @override
  Future<void> play() async {
    final wasStopped = !_wantPlaying;
    _wantPlaying = true;
    _finished = false;
    _handledCompletion = false;
    // Emitted only on the transition, so a pipeline that reacts to the command
    // by calling play() again cannot bounce it back and forth for ever.
    if (wasStopped) _notify(MediaCommand.play);
    await _ensurePlaying();
    _emit();
  }

  @override
  Future<void> pause() async {
    final wasPlaying = _wantPlaying;
    _wantPlaying = false;
    await _player?.pause();
    if (wasPlaying) _notify(MediaCommand.pause);
    _emit();
  }

  @override
  Future<void> resume() => play();

  @override
  Future<void> stop() async {
    final wasLive = _queue != null || _wantPlaying;
    await _stopInternal();
    // The lock screen's X and a dismissed notification both land here, and the
    // pipeline has to hear about them: it owns the renders still in flight and
    // nothing else will cancel them. Suppressed once already stopped, which is
    // what stops a pipeline echoing the command back into a loop.
    if (wasLive) _notify(MediaCommand.stop);
  }

  Future<void> _stopInternal() async {
    _wantPlaying = false;
    _stopAfterCurrent = false;
    _finished = false;
    _handledCompletion = false;
    _ticker?.cancel();
    _ticker = null;

    final player = _player;
    if (player != null) {
      // stop() rather than pause(): it hands the decoders and the audio focus
      // back, which is the difference between a finished session and one that
      // merely looks finished while holding the device's audio output.
      await player.stop();
      await player.clearAudioSources();
    }
    _releaseAll();
    _queue = null;
    _slots = <RenderedSpeech?>[];
    _runStart = 0;
    _appended = 0;
    _playhead = 0;
    _atPlayhead = false;
    _awaitingSeek = false;
    _emit();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
    _emit();
    // Deliberately not published as a MediaCommand: a seek inside one sentence
    // changes nothing about what is rendered or queued, so there is nothing for
    // the pipeline to do, and echoing it back would fight the user's thumb.
  }

  @override
  Future<SpeechUnit?> skipUnits(int delta) async {
    final queue = _queue;
    if (queue == null || queue.isEmpty) return null;
    // Clamped, not wrapped: only the reader knows where the next page starts,
    // so crossing the end of the queue is reported by staying put and letting
    // the reader open a new one.
    final target = (_playhead + delta).clamp(0, queue.length - 1);
    await _moveTo(target);
    return queue.unitAt(target);
  }

  @override
  Future<bool> skipToUnit(String unitId) async {
    final queue = _queue;
    if (queue == null) return false;
    final index = queue.indexOfUnit(unitId);
    if (index < 0) return false;
    await _moveTo(index);
    return true;
  }

  /// Put the playhead on [index], rebuilding the playlist run if it has to.
  Future<void> _moveTo(int index) async {
    final player = _player;
    final queue = _queue;
    if (player == null || queue == null) return;

    _playhead = index;
    _finished = false;
    _handledCompletion = false;

    final position = _positionOf(index);
    if (position != null) {
      _markSeek();
      await player.seek(Duration.zero, index: position);
    } else {
      // Outside the run — a jump forward past what has been rendered, or back
      // past what the run starts at. Rebuilt from here; audio still held in
      // slots is re-appended by _drain, so a short back-skip costs nothing.
      _awaitingSeek = true;
      _atPlayhead = false;
      _seekAt = DateTime.now();
      await player.clearAudioSources();
      _runStart = index;
      _appended = 0;
      await _drain();
    }
    _emit();
    await _ensurePlaying();
  }

  /// Record that the player has been sent to the playhead.
  void _markSeek() {
    _awaitingSeek = true;
    _atPlayhead = true;
    _seekAt = DateTime.now();
  }

  /// Start, or resume, at the playhead — the one place playback is set going.
  ///
  /// Called after every append and every move, and does nothing unless the app
  /// actually wants sound. When the playhead's audio has not arrived it returns
  /// quietly and the status stays [SpeechPlaybackState.preparing]; the append
  /// that fills the gap calls back in here.
  Future<void> _ensurePlaying() async {
    final player = _player;
    if (player == null || !_wantPlaying) return;
    final position = _positionOf(_playhead);
    if (position == null) return;

    // Note what is *not* consulted here: `player.currentIndex`. It is a platform
    // value that lags every playlist change, and seeking whenever it disagreed
    // with our own bookkeeping would restart the sentence being spoken each time
    // an append landed. [_atPlayhead] is the same question answered from what we
    // told the player, and it is false in exactly the two cases that need a
    // seek: a queue just opened, and a playhead advanced past the end of the
    // audio the player had. Resuming from a pause hits neither, so a pause and a
    // play carry on from where the voice stopped rather than from the top of the
    // sentence.
    //
    // A completed player keeps `playing` true and simply sits at the end of the
    // playlist, so the seek is also what restarts one that ran out of audio.
    if (!_atPlayhead || player.processingState == ProcessingState.completed) {
      _markSeek();
      await player.seek(Duration.zero, index: position);
    }
    if (!player.playing) {
      // Never awaited: just_audio's play() completes when playback *finishes*,
      // so awaiting it here would hang until the end of the chapter.
      unawaited(player.play());
    }
  }

  @override
  bool get canStopCleanly => available;

  @override
  void stopAfterCurrentUnit() {
    final player = _player;
    final queue = _queue;
    if (player == null || queue == null) {
      unawaited(stop());
      return;
    }
    final position = _positionOf(_playhead);
    if (position == null) {
      // Nothing is audible to finish — mid-render, or already stopped. An
      // honest immediate ending beats a promise that never lands.
      unawaited(_stopInternal().then((_) => onBoundaryStop?.call()));
      return;
    }

    _stopAfterCurrent = true;
    _handledCompletion = false;
    // Truncating is what makes the boundary exact. Watching for the sentence to
    // end and stopping then means the next one has already begun — a syllable
    // of the following sentence is precisely what wakes someone up. With
    // nothing behind it in the playlist, the player reaches `completed` at the
    // end of this sentence and stops there on its own.
    final drop = _appended - (position + 1);
    if (drop > 0) {
      unawaited(player.removeAudioSourceRange(position + 1, _appended));
      _appended = position + 1;
    }
    // Everything ahead of the playhead — queued or merely rendered — is audio
    // this session will not reach. _drain is closed for business while the flag
    // is set, so nothing refills behind us.
    for (var i = _playhead + 1; i < _slots.length; i++) {
      final rendered = _slots[i];
      if (rendered == null) continue;
      _slots[i] = null;
      _release(rendered);
    }
    _emit();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    await _player?.setVolume(_volume);
    _emit();
  }

  /// True: `just_audio` retimes live and preserves pitch, so a speech-rate
  /// change costs nothing and the whole rendered-ahead window survives it. The
  /// re-render dance the desktop path has to do does not apply here.
  @override
  bool get supportsPlaybackSpeed => true;

  @override
  Future<void> setSpeed(double speed) async {
    await _player?.setSpeed(speed);
    onSpeedRequested?.call(speed);
    _emit();
  }

  @override
  bool get supportsSeekWithinUnit => true;

  // ── AudioHandler: commands from outside the app ──

  /// Next *sentence*, matching the app's own skip control, so a headphone
  /// double-tap does what the on-screen button does.
  ///
  /// Published rather than actioned, because the end of the queue is the end of
  /// a page and only the reader can open the next one. The local skip is the
  /// fallback for a handler nobody has wired a pipeline to yet — without it the
  /// controls would look dead in exactly the configuration used for testing.
  @override
  Future<void> skipToNext() async {
    if (_notify(MediaCommand.next)) return;
    await skipUnits(1);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_notify(MediaCommand.previous)) return;
    await skipUnits(-1);
  }

  /// A long-press on a head unit. Mapped to a page jump by the reader; the
  /// fallback nudges within the sentence, which is all this layer can honestly
  /// do without knowing where pages begin.
  @override
  Future<void> fastForward() async {
    if (_notify(MediaCommand.fastForward)) return;
    final player = _player;
    if (player == null) return;
    await seek(player.position + skipInterval);
  }

  @override
  Future<void> rewind() async {
    if (_notify(MediaCommand.rewind)) return;
    final player = _player;
    if (player == null) return;
    final target = player.position - skipInterval;
    await seek(target < Duration.zero ? Duration.zero : target);
  }

  /// The app was swiped out of the recents list.
  ///
  /// Deliberately left playing. For a music app the swipe means "done"; for an
  /// audiobook the app is usually swiped away *because* the listener wants the
  /// screen off, and stopping here is how a sleep session ends thirty seconds
  /// after it starts. The notification is still there to stop with.
  @override
  Future<void> onTaskRemoved() async {}

  // ── MediaSession ──

  @override
  Stream<MediaCommandEvent> get commands => _commands.stream;

  @override
  Future<void> update(NowPlaying state) async {
    _nowPlaying = state;
    _publish();
  }

  /// True when somebody is listening, which is what lets the transport commands
  /// choose between publishing and handling a command themselves.
  bool _notify(MediaCommand command, {Duration? position}) {
    if (_commands.isClosed) return false;
    _commands.add(MediaCommandEvent(command, position: position));
    return _commands.hasListener;
  }

  // ── publishing ──

  /// Recompute the status, tell the app, and tell the platform.
  void _emit() {
    _last = _buildStatus();
    if (!_status.isClosed) _status.add(_last);
    _publish();
    _syncTicker();
  }

  SpeechPlayerStatus _buildStatus() {
    final player = _player;
    final queue = _queue;
    if (player == null || queue == null) return const SpeechPlayerStatus.idle();

    final position = _positionOf(_playhead);
    final SpeechPlaybackState state;
    if (_finished) {
      state = SpeechPlaybackState.completed;
    } else if (!_wantPlaying) {
      state = position == null
          ? SpeechPlaybackState.idle
          : SpeechPlaybackState.paused;
    } else if (position != null &&
        player.playing &&
        player.processingState == ProcessingState.ready) {
      state = SpeechPlaybackState.playing;
    } else {
      // Waiting for a render, or for the platform to open the file. A state of
      // its own because a Play button that stays a spinner with no explanation
      // is how this pipeline looks broken.
      state = SpeechPlaybackState.preparing;
    }

    final audible =
        state == SpeechPlaybackState.playing ||
        state == SpeechPlaybackState.paused;
    return SpeechPlayerStatus(
      queueId: queue.id,
      state: state,
      // Only ever the unit actually being heard. Reporting the playhead while
      // starved would highlight a sentence that is not being spoken; the
      // pipeline still knows where to render from, because queueIndex below is
      // always the playhead.
      unit: audible ? queue.unitAt(_playhead) : null,
      queueIndex: _playhead,
      position: player.position,
      duration: player.duration,
      volume: _volume,
      stopAfterCurrent: _stopAfterCurrent,
    );
  }

  /// Push [PlaybackState] and [MediaItem] to the notification and lock screen.
  void _publish() {
    final player = _player;
    if (player == null) return;

    final playing = _last.isPlaying;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        // The collapsed notification has room for three. Previous, play/pause and
        // next — stop is reachable by expanding, and losing skip in a car is
        // worse than losing stop.
        androidCompactActionIndices: const [0, 1, 3],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.setSpeed,
        },
        processingState: switch (_last.state) {
          SpeechPlaybackState.idle => AudioProcessingState.idle,
          SpeechPlaybackState.preparing => AudioProcessingState.loading,
          SpeechPlaybackState.completed => AudioProcessingState.completed,
          _ => AudioProcessingState.ready,
        },
        playing: playing,
        // The platform extrapolates from this pair and the speed, so the scrubber
        // moves smoothly between our updates rather than once a second.
        updatePosition: player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
        // Left null on purpose. audio_service's queue is a *track* list; ours is
        // sentences, and publishing "3 of 41" for a page of prose turns a lock
        // screen into a debugger.
        queueIndex: null,
      ),
    );
    _publishMediaItem();
  }

  void _publishMediaItem() {
    final now = _nowPlaying;
    if (now == null) return;
    final item = MediaItem(
      // Stable per page, so the platform treats a page as one track and does
      // not animate a transition every sentence.
      id: '${now.book}#${now.page ?? 0}',
      title: now.title,
      album: now.book,
      artist: now.author,
      artUri: now.artwork,
      // The player's own figure wins: it is the file actually open, and it is
      // what the scrubber is measuring.
      duration: _player?.duration ?? now.duration,
      displaySubtitle: now.page != null && now.pageCount != null
          ? 'Page ${now.page} of ${now.pageCount}'
          : null,
      extras: <String, dynamic>{'page': now.page, 'pageCount': now.pageCount},
    );
    final published = _publishedItem;
    if (published != null && _sameItem(published, item)) return;
    _publishedItem = item;
    mediaItem.add(item);
  }

  /// MediaItem's own `==` compares ids only, so a page whose duration or cover
  /// changed would compare equal and never reach the lock screen. Everything
  /// this handler sets is compared here instead.
  static bool _sameItem(MediaItem a, MediaItem b) =>
      a.id == b.id &&
      a.title == b.title &&
      a.album == b.album &&
      a.artist == b.artist &&
      a.artUri == b.artUri &&
      a.duration == b.duration &&
      a.displaySubtitle == b.displaySubtitle;

  /// A status every second while playing, and none at all while not.
  ///
  /// The lock screen does not need it — the platform extrapolates position — but
  /// Car Mode's own clock and any progress the app draws do. Driven by a timer
  /// rather than `positionStream` so a paused reader costs nothing.
  void _syncTicker() {
    if (_last.isPlaying) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _emit());
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  // ── listening to the player ──

  void _attach() {
    final player = _player;
    if (player == null) return;
    _subscriptions.addAll([
      player.sequenceStateStream.listen(_onSequenceState),
      player.playerStateStream.listen(_onPlayerState),
      // The lock screen's scrubber needs a length, and it only becomes known
      // once the platform has opened the file.
      player.durationStream.listen((_) => _emit()),
    ]);
  }

  /// What is audible, read off the source rather than computed from an index.
  void _onSequenceState(SequenceState state) {
    final tag = state.currentSource?.tag;
    // Not one of ours, or one of ours from a playlist that has since been
    // replaced. Either way it says nothing about the queue that is open now —
    // and mapping its index onto the live queue is exactly how the wrong
    // sentence gets highlighted after a rebuild.
    if (tag is! _UnitTag || tag.queueId != _queue?.id) return;

    if (_awaitingSeek) {
      // Everything until the jump lands is the player still describing where it
      // used to be. Confirmed by the unit we asked for, and nothing else.
      if (tag.index == _playhead) {
        _awaitingSeek = false;
        return; // the mover has already reported this playhead
      }
      // Unless it has been disagreeing for seconds, which is far longer than a
      // platform round trip: then the confirmation was missed rather than
      // pending, and holding out for it freezes the highlight for the rest of
      // the page — a worse failure than the stale event this guards against.
      final since = _seekAt;
      if (since == null || DateTime.now().difference(since) < _seekSettle) {
        return;
      }
      _awaitingSeek = false;
    }
    if (tag.index == _playhead) return;

    // The player advanced by itself, which is the ordinary case and the only
    // one that may move the highlight.
    _playhead = tag.index;
    _atPlayhead = true;
    _handledCompletion = false;
    _emit();
  }

  void _onPlayerState(PlayerState state) {
    if (state.processingState == ProcessingState.completed) {
      _onCompleted();
      return;
    }
    _emit();
  }

  /// The playlist ran out — which is not the same as the queue running out.
  void _onCompleted() {
    if (_handledCompletion) return;
    _handledCompletion = true;
    final queue = _queue;
    if (queue == null) return;

    if (_stopAfterCurrent) {
      _stopAfterCurrent = false;
      unawaited(_stopInternal().then((_) => onBoundaryStop?.call()));
      return;
    }
    // The first unit the playlist does not hold. Derived from the run rather
    // than from the playhead, because it is true even if a sequence event went
    // missing: what the player ran out of is exactly what was appended.
    final next = _runStart + _appended;
    if (next < queue.length) {
      // Starved, not finished: the next sentence exists but its audio has not
      // arrived. Moving the playhead now is what tells the pipeline which unit
      // to render, and what _drain resumes on when it lands. The player is left
      // parked where it ran out, hence no longer on the playhead.
      _playhead = next;
      _atPlayhead = false;
      _emit();
      unawaited(_ensurePlaying());
      return;
    }
    _finished = true;
    _wantPlaying = false;
    _emit();
  }

  // ── the run, and the files it owns ──

  /// Playlist position of a queue index, or null when it is outside the run.
  int? _positionOf(int queueIndex) {
    final position = queueIndex - _runStart;
    return position >= 0 && position < _appended ? position : null;
  }

  void _releaseAll() {
    for (var i = 0; i < _slots.length; i++) {
      final rendered = _slots[i];
      if (rendered == null) continue;
      _slots[i] = null;
      _release(rendered);
    }
  }

  /// Hand a file back to whoever is deleting them.
  void _release(RenderedSpeech rendered) {
    if (_released.isClosed) {
      _delete(rendered);
      return;
    }
    // Buffered rather than dropped, and remembered until a listener arrives, so
    // a pipeline that never subscribes is a leak we can still close at dispose.
    if (!_released.hasListener) _pendingRelease.add(rendered);
    _released.add(rendered);
  }

  /// Last resort only. Deleting rendered audio belongs to the synthesiser that
  /// wrote it (`SpeechSynthesiser.discard`); this runs when nothing ever claimed
  /// ownership by listening to [released], where the alternative is leaving a
  /// book's worth of WAVs in the temp directory.
  void _delete(RenderedSpeech rendered) {
    unawaited(() async {
      try {
        await File(rendered.path).delete();
      } catch (_) {
        // Already gone, or never written. Both are fine: this runs on the stop
        // path and must never throw.
      }
    }());
  }

  @override
  Future<void> dispose() async {
    // Stopped first, and through the ordinary path: it publishes an idle
    // playback state, which is what takes the notification down. A media
    // notification still sitting there after the book was closed is the sort of
    // thing people uninstall over.
    await _stopInternal();

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _player?.dispose();
    await _status.close();
    await _commands.close();

    // Nothing ever claimed the released files, so nothing else is going to
    // delete them.
    if (!_released.hasListener) {
      for (final rendered in _pendingRelease) {
        _delete(rendered);
      }
    }
    _pendingRelease.clear();
    await _released.close();
  }
}

/// What a queued `just_audio` source *is*, travelling with the source itself.
///
/// The alternative — mapping the player's `currentIndex` onto the live queue —
/// is correct only while the playlist and the queue agree, and they disagree for
/// exactly as long as it takes a replaced playlist's last event to arrive. That
/// window is a page turn, and the symptom is the wrong sentence highlighted with
/// nothing in the logs.
@immutable
class _UnitTag {
  const _UnitTag(this.queueId, this.index, this.unit);

  /// The generation this source was queued for. Anything else is stale.
  final int queueId;

  /// Position in the queue, for transport arithmetic only.
  final int index;

  /// What the app highlights.
  final SpeechUnit unit;

  @override
  String toString() => '_UnitTag(q$queueId, ${unit.id})';
}
