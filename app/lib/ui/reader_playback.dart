import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../services/chapter_index.dart';
import '../services/media_player_service.dart';
import '../services/settings_service.dart';
import '../services/sleep_timer.dart';
import '../services/tts_service.dart';
import '../services/wakeful.dart';
import 'car_mode_screen.dart';
import 'sleep_sheet.dart';
import 'widgets/sleep_chip.dart';

/// Where a sleep timer stopped, in the form it is stored: `"page:sentence"`.
///
/// Deliberately not a `Bookmark`: `addBookmark` replaces same-page entries, so
/// recording this as one would silently eat a bookmark the user placed on
/// purpose.
class ReadingAnchor {
  const ReadingAnchor(this.page, this.sentence);

  final int page;
  final int sentence;

  String encode() => '$page:$sentence';

  /// Null on anything malformed. A value written by an older build, or edited
  /// by hand, must not throw on the way into a book.
  static ReadingAnchor? decode(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final page = int.tryParse(parts[0]);
    final sentence = int.tryParse(parts[1]);
    if (page == null || sentence == null) return null;
    if (page < 1 || sentence < 0) return null;
    return ReadingAnchor(page, sentence);
  }

  ReadingAnchor rewound(int by) =>
      ReadingAnchor(page, (sentence - by).clamp(0, sentence));
}

/// Everything Car Mode and the sleep timer need from a reader.
///
/// The two readers cannot share a base class — one has page geometry and a
/// native viewer, the other a laid-out string — but the playback *cursor*, the
/// sleep endings and the Car Mode lifecycle are identical in both, and
/// duplicating them is exactly how the two screens drift apart under the user.
///
/// The host supplies [speakAt] and the getters below; everything else lives
/// here. It must also call [initPlayback] from `initState` and [disposePlayback]
/// from `dispose`.
mixin ReaderPlayback<T extends StatefulWidget> on State<T> {
  // ── supplied by the host ──

  TtsService get tts;
  SettingsService get settings;
  Book get book;
  MediaPlayerService get music;
  ChapterIndex get chapters;

  String get bookTitle;
  int get page;
  int get pageCount;

  /// Sentences on the current page, or zero while none are split.
  int get sentenceCount;

  /// The sentence being spoken, or null while the list is out of range or being
  /// rebuilt. Opt-in display only, so a stale one is worse than none.
  String? get currentSentence;

  bool get isBookmarkedHere;

  /// Long-running work with no other visible cause, e.g. OCR on a scanned page.
  String? get busyMessage;

  Future<void> togglePlay();

  /// Add a bookmark here, returning false when there already was one. Never
  /// deletes: a mis-aimed second press in a car must not undo the first.
  Future<bool> bookmarkHere();

  /// Speak [pageNumber] from [sentence], turning the page first if needed.
  ///
  /// A negative [sentence] counts back from the end of that page, so -1 is its
  /// last sentence. That is where a backwards skip across a page boundary has to
  /// land, or N back taps would not undo N forward taps.
  ///
  /// With [resume] false the cursor and the highlight move but nothing is
  /// spoken: skipping while paused has to stay paused.
  Future<void> speakAt(int pageNumber, int sentence, {required bool resume});

  /// Chrome the host must put away when Car Mode opens. Called immediately
  /// before the rebuild, so it should mutate fields directly rather than call
  /// `setState` itself.
  void onCarModeChanged(bool active) {}

  // ── state ──

  final SleepTimer _sleep = SleepTimer();

  bool _carMode = false;

  /// The page speech is running on, which is not always [page]: a programmatic
  /// page turn is reported back to us a frame or more later.
  int? _spokenPage;
  int? _lastSpoken;

  int _pendingSkip = 0;
  Timer? _skipDebounce;
  Timer? _rateDebounce;
  DateTime? _anchorSavedAt;

  SleepTimer get sleep => _sleep;

  bool get inCarMode => _carMode;

  /// Where Play picks up on the current page.
  ///
  /// Zero once the page has changed, because the cursor belongs to the page it
  /// was recorded on and a stale index would land anywhere.
  int get resumeSentence => (_spokenPage == page ? _lastSpoken : null) ?? 0;

  // ── lifecycle ──

  /// Call from the host's `initState`, once its [TtsService] exists.
  void initPlayback() {
    _sleep
      ..onExpire = _onSleepExpired
      ..onFadeTick = (volume) => unawaited(tts.setVolume(volume));
    tts.onBoundaryStop = _onBoundaryStop;
    _offerSleepResume();
  }

  /// Call from the host's `dispose`, before the [TtsService] is disposed.
  ///
  /// Car Mode itself needs no teardown — it is an overlay over the reader's own
  /// Scaffold, so nothing is constructed or disposed on the way in or out, and
  /// the speech it drives is the reader's own, stopped by the reader's own
  /// `dispose`. The timers and the inhibitor do need it: they are the only
  /// things here that outlive the widget tree if left alone, and a machine
  /// unable to idle after the reader is gone is the one failure a user would
  /// never trace back to this app.
  void disposePlayback() {
    _skipDebounce?.cancel();
    _rateDebounce?.cancel();
    tts.onBoundaryStop = null;
    _sleep.removeListener(_onSleepTick);
    _sleep.dispose();
    unawaited(Wakeful.release());
  }

  // ── the sleep endings ──

  Future<void> _onSleepExpired() async {
    if (!mounted) return;
    // Nothing has started yet, or the engine speaks a whole page in one process
    // and has no sentence boundary to end on: stopping now is the honest ending.
    if (tts.isPreparing || !tts.canStopCleanly) {
      await tts.stop();
    } else {
      tts.stopAfterCurrentSegment();
    }
    // The fade left the volume down and nothing else restores it until the next
    // speak(). Without this the app is silently mute rather than asleep.
    await tts.setVolume(1.0);
    if (settings.sleepStopsMusic) await music.stop();
    if (settings.sleepPausesMpris) await MprisControl.pause();
    await Wakeful.release();

    // Deliberately no page turn and no stats.recordPage(): the pages after this
    // one were not read, and the cursor stays where the voice stopped.
    final at = _lastSpoken;
    if (at != null) {
      await settings.setSleepStop(book.id, _spokenPage ?? page, at);
    }
    if (mounted) setState(() {});
  }

  /// Speech ended exactly where we asked it to.
  ///
  /// [TtsService.onPageFinished] is deliberately not fired for a boundary stop,
  /// so auto-advance stays put; this only refreshes the transport controls.
  void _onBoundaryStop() {
    if (mounted) setState(() {});
  }

  /// Tell the timer a page has been read out, and report whether that ended the
  /// session. Auto-advance must call this before turning the page.
  ///
  /// The duration ending arrives through [SleepTimer.onExpire]; the end-of-page
  /// and end-of-chapter endings can only be recognised here, because only the
  /// reader knows a page has finished and where the chapters are. Both latch
  /// through the same [SleepTimer.hasExpired] everything else checks.
  bool sleepEndsHere() {
    // Recomputed from where the reader actually is, so end-of-chapter
    // re-targets for free: skip into a new chapter with it armed and it means
    // *that* chapter's end.
    _sleep.pageFinished(isChapterEnd: !chapters.sameSection(page, page + 1));
    return _sleep.hasExpired;
  }

  /// Keep the countdown honest: it may only drain while the voice is running.
  ///
  /// A timer that keeps counting while you fiddle with the voice picker is a
  /// bug. One that expires mid-drive silences the audio for no visible reason,
  /// and the driver's next move is to look at the phone to find out why — a
  /// hazard Car Mode itself would have manufactured.
  ///
  /// Called from the host's TTS listener, so every start, stop and pause routes
  /// through one place rather than a hold/resume pair per call site.
  void syncSleepHold() {
    if (!_sleep.isArmed) return;
    final shouldHold = !tts.isSpeaking || (_carMode && settings.sleepHoldInCar);
    if (shouldHold) {
      _sleep.hold();
    } else {
      _sleep.resume();
    }
  }

  /// Extend the countdown from Car Mode, or start one. False means the cap was
  /// reached, which the caller turns into the "refused" haptic.
  Future<bool> addSleep(Duration extra) async {
    const cap = Duration(hours: 3);
    if (_sleep.mode == SleepMode.duration) {
      if (_sleep.remaining + extra > cap) return false;
      _sleep.extend(extra);
    } else {
      // No countdown to move — an end-of-chapter ending, or nothing armed. The
      // driver asked for minutes, so give them minutes; arm replaces by design.
      _sleep.arm(SleepMode.duration,
          total: extra, fadeSeconds: settings.sleepFadeSeconds);
    }
    syncSleepHold();
    if (mounted) setState(() {});
    return true;
  }

  void cancelSleep() {
    // cancel() lifts any fade in progress through onFadeTick, so the volume
    // comes back on its own.
    _sleep.cancel();
    if (mounted) setState(() {});
  }

  /// A book the timer closed reopens with an offer to pick up where the voice
  /// stopped, rewound a little because nobody remembers the last thing they
  /// heard before falling asleep.
  void _offerSleepResume() {
    final anchor = ReadingAnchor.decode(settings.sleepStop(book.id));
    if (anchor == null) return;
    // Used once, whatever the user does with it: an offer that reappears on
    // every open is a nag, and the position only means anything for the night
    // it was written.
    unawaited(settings.clearSleepStop(book.id));
    final at = anchor.rewound(settings.sleepRewindSentences);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('The sleep timer stopped on page ${at.page}.'),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Resume',
          onPressed: () =>
              unawaited(speakAt(at.page, at.sentence, resume: true)),
        ),
      ));
    });
  }

  // ── the reading cursor ──

  /// Record where a speech run starts.
  ///
  /// The page is passed explicitly because [page] still reports the old one
  /// until the viewer catches up with a programmatic turn.
  void noteSpeechStart(int pageNumber, int sentence) {
    _spokenPage = pageNumber;
    _lastSpoken = sentence;
  }

  /// Record the sentence now being spoken.
  ///
  /// Set-only by design. `stop()` reports a null segment to clear the
  /// highlight, and pause *is* stop on Linux, so letting that null through here
  /// would destroy the very position Play needs to resume from.
  void noteSpoken(int sentence) {
    _lastSpoken = sentence;
    _saveAnchor(sentence);
  }

  /// Persist the position while a timer is armed, so a machine killed overnight
  /// still reopens where the voice stopped.
  ///
  /// Only while armed: otherwise this is a disk write per sentence for a
  /// position `lastPage` already covers. Throttled, because only the last one
  /// written before the machine goes quiet ever matters.
  void _saveAnchor(int sentence) {
    if (!_sleep.isArmed) return;
    final now = DateTime.now();
    final last = _anchorSavedAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _anchorSavedAt = now;
    unawaited(settings.setSleepStop(book.id, _spokenPage ?? page, sentence));
  }

  // ── transport, shared by Car Mode and the ordinary chrome ──

  Future<void> skipSentences(int delta) async {
    if (delta == 0) return;
    _pendingSkip += delta;
    // Every skip throws the whole look-ahead window away and restarts
    // synthesis, so four fast taps would be four full restarts and four gaps of
    // silence. The caller has already given its own feedback, so the control
    // still feels instant; the audio catches up once.
    _skipDebounce?.cancel();
    _skipDebounce = Timer(const Duration(milliseconds: 350), _applySkip);
  }

  Future<void> _applySkip() async {
    final delta = _pendingSkip;
    _pendingSkip = 0;
    if (delta == 0 || !mounted) return;

    final resume = tts.isSpeaking;
    final target = resumeSentence + delta;
    final count = sentenceCount;

    // Nothing split yet, so there is no boundary to reason about; speakAt
    // clamps once the sentences arrive.
    if (count == 0) {
      return speakAt(page, target < 0 ? 0 : target, resume: resume);
    }
    if (target >= 0 && target < count) {
      return speakAt(page, target, resume: resume);
    }
    if (target < 0) {
      if (page <= 1) return speakAt(page, 0, resume: resume);
      // The overflow carries and stays negative, so it counts back from the end
      // of the previous page. That is what makes the skip exactly reversible
      // across a boundary.
      return speakAt(page - 1, target, resume: resume);
    }
    if (page >= pageCount) return speakAt(page, count - 1, resume: resume);
    return speakAt(page + 1, target - count, resume: resume);
  }

  Future<void> jumpPages(int delta) async {
    if (delta == 0 || pageCount <= 0) return;
    final target = (page + delta).clamp(1, pageCount);
    if (target == page) return;
    // A page jump supersedes any sentence skip still waiting to fire.
    _skipDebounce?.cancel();
    _pendingSkip = 0;
    await speakAt(target, 0, resume: tts.isSpeaking);
  }

  /// Change the speech rate and re-start the current sentence at it.
  ///
  /// Piper reads the rate when a chunk is rendered, and up to `lookAhead + 1`
  /// chunks are already rendered or queued — so without the restart the change
  /// lands three sentences later, or never, and the user changes it again and
  /// overshoots. Re-hearing one sentence is much the cheaper mistake.
  Future<void> setSpeechRate(double rate) async {
    await tts.setRate(rate);
    _rateDebounce?.cancel();
    if (tts.isSpeaking) {
      _rateDebounce = Timer(const Duration(milliseconds: 400), () {
        if (mounted) unawaited(speakAt(page, resumeSentence, resume: true));
      });
    }
    if (mounted) setState(() {});
  }

  // ── Car Mode ──

  void enterCarMode() {
    if (_carMode) return;
    onCarModeChanged(true);
    setState(() => _carMode = true);
    // Only while the overlay is up. The countdown is the one thing on it that
    // changes without the reader changing, and off the overlay a listener here
    // would repaint the viewer once a second for a clock.
    _sleep.addListener(_onSleepTick);
    syncSleepHold();
    if (settings.carKeepAwake) unawaited(Wakeful.acquire());
  }

  void exitCarMode() {
    if (!_carMode) return;
    onCarModeChanged(false);
    setState(() => _carMode = false);
    _sleep.removeListener(_onSleepTick);
    syncSleepHold();
    unawaited(Wakeful.release());
  }

  void _onSleepTick() {
    if (mounted) setState(() {});
  }

  /// The driving surface, mounted as a sibling of the reader's own body.
  ///
  /// It is handed the reader's [TtsService] and a set of callbacks, never a way
  /// to build its own: two instances in one process render Piper chunks to
  /// byte-identical temp paths and eat each other's audio.
  Widget carOverlay() => CarModeScreen(
        tts: tts,
        title: bookTitle,
        page: page,
        pageCount: pageCount,
        onPlayPause: () => unawaited(togglePlay()),
        onSkipSentence: (delta) => unawaited(skipSentences(delta)),
        onSkipPage: (delta) => unawaited(jumpPages(delta)),
        onExit: exitCarMode,
        onSetRate: setSpeechRate,
        onBookmark: bookmarkHere,
        onAddSleep: addSleep,
        onCancelSleep: cancelSleep,
        isBookmarked: isBookmarkedHere,
        // Only a countdown has time left to show; the end-of-section endings
        // have no knowable length.
        sleepRemaining:
            _sleep.mode == SleepMode.duration ? _sleep.remaining : null,
        sleepHeld: _sleep.isHeld,
        sentence: currentSentence,
        showSentence: settings.carShowText,
        busy: busyMessage,
        haptics: settings.carHaptics,
      );

  void openSleepSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SleepSheet(
        settings: settings,
        timer: _sleep,
        chapters: chapters,
      ),
    ).then((_) {
      if (!mounted) return;
      syncSleepHold();
      setState(() {});
    });
  }

  /// The countdown for the app bar.
  ///
  /// Only this listens to the timer while the reader is on screen. A listener
  /// at screen level would rebuild the whole viewer and re-run its paint
  /// callbacks once a second, for a clock.
  Widget sleepChip() => ListenableBuilder(
        listenable: _sleep,
        builder: (context, _) => _sleep.isArmed
            ? SleepChip(timer: _sleep, onTap: openSleepSheet)
            : const SizedBox.shrink(),
      );
}
