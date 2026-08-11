import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../services/tts_service.dart';

/// A driving surface for a book that is already playing.
///
/// Everything here exists to keep the eyes on the road: six controls, all in
/// fixed positions, none smaller than a thumb, nothing that scrolls, and no
/// paragraph of book text to read at speed. The reader screen keeps ownership of
/// the book, the position and the speech pipeline — this widget is handed a
/// [TtsService] to *observe* and a set of callbacks to *ask*, and reaches into
/// nothing else. That is what makes it safe to mount as an overlay inside the
/// reader's own `Scaffold` (the mounting that keeps playback running across
/// enter and exit, because nothing is constructed or disposed either way).
///
/// Three rules shape the layout, and each is load-bearing rather than taste:
///
///  * **No control is ever conditionally present or repositioned.** A driver
///    aims by memory. A control that refuses stays where it is, dims, gains a
///    slash and answers with the "refused" haptic — it never disappears.
///  * **Every action is reversible, additive or self-announcing.** The outer
///    columns are symmetric pairs, so the antidote to a mis-hit is its own
///    neighbour; the centre column holds the only two purely additive actions,
///    so the easiest cell to hit by accident is also the most harmless.
///  * **Nothing here deletes anything.** Bookmarking twice is a no-op, not an
///    un-bookmark.
class CarModeScreen extends StatefulWidget {
  const CarModeScreen({
    super.key,
    required this.tts,
    required this.title,
    required this.page,
    required this.pageCount,
    required this.onPlayPause,
    required this.onSkipSentence,
    required this.onSkipPage,
    required this.onExit,
    this.onSetRate,
    this.onBookmark,
    this.onAddSleep,
    this.onCancelSleep,
    this.isBookmarked = false,
    this.sleepRemaining,
    this.sleepHeld = false,
    this.sleepStep = const Duration(minutes: 15),
    this.sentence,
    this.showSentence = false,
    this.busy,
    this.haptics = true,
    this.revision,
  });

  /// Observed for play / preparing / rate. Never constructed here: two
  /// [TtsService] instances in one process would render Piper chunks to
  /// identical temp paths and eat each other's audio.
  final TtsService tts;

  final String title;
  final int page;
  final int pageCount;

  /// Toggle speech. The reader is expected to resume from the last spoken
  /// sentence rather than the top of the page.
  final VoidCallback onPlayPause;

  /// Move by [delta] sentences. Called once per tap, deliberately: coalescing
  /// rapid taps into a single restart belongs to the reader, which owns the
  /// look-ahead window that a restart throws away. The haptic still fires on
  /// every tap, so the control feels instant while the audio catches up once.
  final void Function(int delta) onSkipSentence;

  /// Move by [delta] pages — the hold action on the two skip tiles.
  final void Function(int delta) onSkipPage;

  /// Leave car mode. Must also pop the route if this was pushed as one, since
  /// back and Escape are routed here rather than to the navigator.
  final VoidCallback onExit;

  /// Set the speech rate. Provided by the reader so the change can restart the
  /// current sentence: up to three chunks are already rendered at the old rate,
  /// so a plain `setRate` lands seconds later and the driver taps again and
  /// overshoots. Falls back to [TtsService.setRate] when absent.
  final Future<void> Function(double rate)? onSetRate;

  /// Add a bookmark here. False means there already was one — never a deletion.
  final Future<bool> Function()? onBookmark;

  /// Extend (or start) the sleep timer. False means the cap was reached.
  final Future<bool> Function(Duration extra)? onAddSleep;

  /// Clear the sleep timer — the hold action on the sleep tile.
  final VoidCallback? onCancelSleep;

  final bool isBookmarked;

  /// Time left on the sleep timer, or null when none is armed.
  final Duration? sleepRemaining;

  /// The timer is armed but deliberately not draining — car mode holds it, so a
  /// sleep timer cannot silence the audio mid-drive and send the driver looking
  /// at the phone to find out why.
  final bool sleepHeld;

  final Duration sleepStep;

  /// The sentence being spoken. Shown only when [showSentence] is on, as one
  /// dim ellipsised line — never a paragraph. A block of book text at the
  /// centre of the screen is an invitation to read while driving, and it is the
  /// one element that cannot be made safer by being made bigger.
  final String? sentence;
  final bool showSentence;

  /// Long-running work with no other visible cause, e.g. OCR on a scanned page.
  final String? busy;

  final bool haptics;

  /// Extra change source to repaint on, for the case where this is pushed as a
  /// route: mounted as an overlay it rebuilds with the reader and needs none.
  final Listenable? revision;

  @override
  State<CarModeScreen> createState() => _CarModeScreenState();
}

class _CarModeScreenState extends State<CarModeScreen> {
  /// Which way round the layout is. Sticky, not latched — see
  /// [_resolveLandscape].
  bool? _landscape;

  /// Portrait or landscape, with a dead zone around square.
  ///
  /// Sticky because a control that moves under the thumb because the window was
  /// nudged is worse than a cramped one, and a viewport dragged past square
  /// would otherwise flap the whole layout. Not latched for ever, though: a real
  /// rotation leaves the portrait stack on a landscape viewport, and the two
  /// `FittedBox`es that stop it overflowing do so by shrinking the six to about
  /// 42 dp — under half their floor, and under WCAG 2.5.5's 44 px. The 10 %
  /// margin is wide enough that nothing short of a deliberate reshape crosses
  /// it, and narrow enough that every rotation does.
  bool _resolveLandscape(Size size) {
    final was = _landscape;
    if (size.height <= 0 || size.width <= 0) return was ?? false;
    if (was == null) return _landscape = size.width > size.height;
    final ratio = size.width / size.height;
    if (was && ratio < 0.9) return _landscape = false;
    if (!was && ratio > 1.1) return _landscape = true;
    return was;
  }

  @override
  void initState() {
    super.initState();
    widget.tts.addListener(_onChange);
    widget.revision?.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _say('Car mode. Hold the top bar to exit.');
    });
  }

  @override
  void didUpdateWidget(covariant CarModeScreen old) {
    super.didUpdateWidget(old);
    if (old.tts != widget.tts) {
      old.tts.removeListener(_onChange);
      widget.tts.addListener(_onChange);
    }
    if (old.revision != widget.revision) {
      old.revision?.removeListener(_onChange);
      widget.revision?.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.tts.removeListener(_onChange);
    widget.revision?.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  // ── feedback ──
  //
  // Three distinct signals, because a driver who cannot tell "done" from
  // "nothing happened" looks at the screen — the exact failure this mode exists
  // to prevent. All of them no-op on desktop, which is why the check lives here
  // rather than at every call site.

  void _ok() {
    if (widget.haptics) HapticFeedback.mediumImpact();
  }

  void _stateChanged() {
    if (widget.haptics) HapticFeedback.heavyImpact();
  }

  Future<void> _refused(String why) async {
    _say(why);
    if (!widget.haptics) return;
    await HapticFeedback.selectionClick();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.selectionClick();
  }

  /// One-shot announcements only. The status band is deliberately not a live
  /// region: it would fire on every spoken sentence and fight the narration for
  /// the audio channel.
  ///
  /// Skipped where the platform has no announcement channel — the labels on the
  /// controls still carry every state a screen reader needs.
  void _say(String message) {
    if (!mounted) return;
    if (!MediaQuery.supportsAnnounceOf(context)) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      Directionality.of(context),
    );
  }

  // ── actions ──

  void _playPause() {
    final wasSpeaking = widget.tts.isSpeaking;
    _stateChanged();
    widget.onPlayPause();
    _say(wasSpeaking ? 'Paused' : 'Playing');
  }

  void _skipSentence(int delta) {
    _ok();
    widget.onSkipSentence(delta);
    _say(delta < 0 ? 'Previous sentence' : 'Next sentence');
  }

  void _skipPage(int delta) {
    final count = widget.pageCount;
    // A reader that has not finished opening the book reports no count, and its
    // own page jump refuses outright. Confirming a turn that cannot happen is
    // worse than refusing one: the driver believes the page moved and skips
    // again, and only finds out by looking.
    if (count <= 0) {
      _refused('Still opening the book');
      return;
    }
    final target = widget.page + delta;
    if (target < 1 || target > count) {
      _refused(delta < 0 ? 'Already at the first page' : 'Already at the last page');
      return;
    }
    _ok();
    widget.onSkipPage(delta);
    _say(delta < 0 ? 'Previous page' : 'Next page');
  }

  Future<void> _nudgeRate(int steps) async {
    final index = carSpeedIndex(widget.tts.rate);
    final next = index + steps;
    if (next < 0 || next >= kCarSpeedLadder.length) {
      await _refused(steps < 0 ? 'Already the slowest' : 'Already the fastest');
      return;
    }
    final step = kCarSpeedLadder[next];
    _ok();
    if (widget.onSetRate != null) {
      await widget.onSetRate!(step.rate);
    } else {
      await widget.tts.setRate(step.rate);
    }
    _say('Speed ${step.label}');
  }

  Future<void> _bookmark() async {
    final add = widget.onBookmark;
    if (add == null) {
      await _refused('Bookmarks are unavailable');
      return;
    }
    final added = await add();
    if (!mounted) return;
    if (!added) {
      await _refused('This page is already bookmarked');
      return;
    }
    _ok();
    _say('Bookmarked page ${widget.page}');
  }

  Future<void> _addSleep() async {
    final add = widget.onAddSleep;
    if (add == null) {
      await _refused('Sleep timer is unavailable');
      return;
    }
    final applied = await add(widget.sleepStep);
    if (!mounted) return;
    if (!applied) {
      await _refused('Sleep timer is already at its longest');
      return;
    }
    _ok();
    final left = widget.sleepRemaining;
    _say(left == null
        ? 'Sleep timer set to ${_minutes(widget.sleepStep)} minutes'
        : 'Sleep timer extended');
  }

  Future<void> _cancelSleep() async {
    final cancel = widget.onCancelSleep;
    if (cancel == null) {
      await _refused('Sleep timer is unavailable');
      return;
    }
    // Deliberately not gated on [sleepRemaining]. An end-of-page or
    // end-of-chapter ending is armed and will stop the book, but has no
    // countdown to report, so it arrives here as null — and refusing on that
    // told the driver "no sleep timer running" about a timer that was about to
    // silence the car. Clearing is idempotent, so asking for it when nothing is
    // armed costs nothing; being unable to clear one costs the drive.
    _ok();
    cancel();
    _say('Sleep timer off');
  }

  void _exit() {
    _stateChanged();
    _say('Leaving car mode');
    widget.onExit();
  }

  static int _minutes(Duration d) => d.inMinutes;

  @override
  Widget build(BuildContext context) {
    final palette = CarPalette.of(context);
    // A screen reader synthesises taps that carry no travel, so the raised slop
    // that saves a real thumb on a rough road only gets in its way.
    final slop = MediaQuery.accessibleNavigationOf(context) ? kTouchSlop : kCarSlop;
    final calm = MediaQuery.disableAnimationsOf(context);

    return PopScope(
      // Back must never dump a driver into the library, but it must still work
      // as an exit — that is the gesture a screen-reader user reaches for.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exit();
      },
      child: CallbackShortcuts(
        // Desktop is this app's primary target and a keyboard is the one input
        // that never mis-aims; the on-screen controls stay the whole story.
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _exit,
          const SingleActivator(LogicalKeyboardKey.space): _playPause,
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _skipSentence(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _skipSentence(1),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () => _nudgeRate(-1),
          const SingleActivator(LogicalKeyboardKey.arrowUp): () => _nudgeRate(1),
          const SingleActivator(LogicalKeyboardKey.pageUp): () => _skipPage(-1),
          const SingleActivator(LogicalKeyboardKey.pageDown): () => _skipPage(1),
        },
        child: Focus(
          autofocus: true,
          child: Material(
            color: palette.background,
            child: FocusTraversalGroup(
              policy: OrderedTraversalPolicy(),
              child: SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final size = Size(box.maxWidth, box.maxHeight);
                    final landscape = _resolveLandscape(size);
                    return Stack(
                      children: [
                        // Bottom of the stack, so it only ever sees taps that
                        // missed every control. Stopping without aiming is the
                        // one action worth having a gesture for.
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onDoubleTap: _playPause,
                            child: const SizedBox.expand(),
                          ),
                        ),
                        Positioned.fill(
                          child: _body(size, landscape, palette, slop, calm),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(
      Size size, bool landscape, CarPalette palette, double slop, bool calm) {
    // Tab order runs transport, then the six, then the way out — the reverse of
    // reading order for the last one, deliberately: nobody should land on exit
    // first.
    final band = FocusTraversalOrder(
      order: const NumericFocusOrder(7),
      child: _band(palette, slop, calm),
    );
    final grid = _grid(size, landscape, palette, slop, calm);
    final diameter = carTransportDiameter(size);
    final transport = FocusTraversalOrder(
      order: const NumericFocusOrder(0),
      child: _transport(diameter, palette, slop, calm),
    );

    if (landscape) {
      return Column(
        children: [
          band,
          Expanded(
            child: Row(
              children: [
                SizedBox(
                  width: size.width * 0.42,
                  child: Center(child: transport),
                ),
                Expanded(child: Center(child: grid)),
              ],
            ),
          ),
        ],
      );
    }

    // Both halves are flexible so neither can push the other off the screen:
    // whatever is left after the band is split, and each half shrinks inside its
    // share rather than overflowing. Nothing here may ever scroll.
    return Column(
      children: [
        band,
        Expanded(
          flex: 5,
          child: Center(child: transport),
        ),
        Expanded(
          flex: 4,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Center(child: grid),
          ),
        ),
      ],
    );
  }

  // ── status band ──

  Widget _band(CarPalette palette, double slop, bool calm) {
    final speed = kCarSpeedLadder[carSpeedIndex(widget.tts.rate)].label;
    // Three lines, always three lines, even when the third is empty: a band
    // that changes height as the book plays would shift the transport under a
    // thumb already on its way.
    final under = widget.busy ??
        (widget.showSentence ? widget.sentence : null) ??
        widget.title;

    return _CarPressable(
      slop: slop,
      calm: calm,
      haptics: widget.haptics,
      // 800 ms: Material's 500 is inside the range a hand resting on a mount
      // reaches by accident, and past about 1.2 s a hold reads as broken.
      holdDuration: const Duration(milliseconds: 800),
      holdTicks: true,
      semanticLabel: 'Exit car mode',
      semanticHint: 'Hold for eight hundred milliseconds, or press Escape',
      onHold: _exit,
      builder: (pressed, focused) => Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 88),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
        decoration: BoxDecoration(
          color: pressed || focused ? palette.tilePressed : palette.background,
          border: Border(
            bottom: BorderSide(
              color: focused ? palette.text : palette.border,
              width: focused ? 4 : 2,
            ),
          ),
        ),
        child: MediaQuery.withClampedTextScaling(
          // Clamped, not ignored: the band is allowed to grow with the reader's
          // text size, but past this it would eat the controls it labels.
          maxScaleFactor: 1.6,
          child: LayoutBuilder(
            builder: (context, box) => Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Every line is a single ellipsised line inside a bounded box,
                // which is what makes the band impossible to overflow at any
                // width or text size.
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.pageCount > 0
                            ? 'Page ${widget.page} / ${widget.pageCount}'
                            : 'Page ${widget.page}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 28,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          color: palette.text,
                        ),
                      ),
                      Text(
                        _sleepLine(speed),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 24,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                          color: palette.text,
                        ),
                      ),
                      Text(
                        under.isEmpty ? ' ' : under,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          height: 1.3,
                          color: palette.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: box.maxWidth * 0.34),
                  child: Text(
                    'Hold to exit',
                    textAlign: TextAlign.end,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 20,
                      height: 1.3,
                      color: palette.textDim,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Speed always; the sleep half appears only when armed — and it sits at the
  /// far edge, where nothing is aimed at, so its arrival moves no control.
  String _sleepLine(String speed) {
    final left = widget.sleepRemaining;
    if (left == null) return speed;
    if (widget.sleepHeld) return '$speed · sleep held';
    return '$speed · ${carCountdown(left)}';
  }

  // ── transport ──

  Widget _transport(double diameter, CarPalette palette, double slop, bool calm) {
    final tts = widget.tts;
    final speaking = tts.isSpeaking;
    final preparing = tts.isPreparing;
    final label = preparing ? 'Preparing' : (speaking ? 'Playing' : 'Paused');

    return FittedBox(
      // Insurance, not layout: on a viewport too small for the floors the button
      // shrinks rather than overflowing. An overflow would hide it entirely.
      fit: BoxFit.scaleDown,
      child: _CarPressable(
        slop: slop,
        calm: calm,
        haptics: widget.haptics,
        semanticLabel: speaking ? 'Pause' : 'Play',
        semanticHint: 'Double tap anywhere off a control does the same',
        onTap: _playPause,
        builder: (pressed, focused) => Container(
          width: diameter,
          height: diameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: pressed ? palette.accentPressed : palette.accent,
            border: Border.all(
              color: focused ? palette.text : palette.border,
              width: focused ? 6 : 2,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (preparing && !calm)
                SizedBox(
                  width: diameter * 0.3,
                  height: diameter * 0.3,
                  child: CircularProgressIndicator(
                    strokeWidth: 6,
                    color: palette.onAccent,
                  ),
                )
              else
                Icon(
                  preparing
                      ? Icons.hourglass_top
                      : (speaking ? Icons.pause : Icons.play_arrow),
                  size: diameter * 0.42,
                  color: palette.onAccent,
                ),
              const SizedBox(height: 6),
              // The state is carried by a word as well as a shape: colour and
              // icon alone are a coin-flip in a two-second glance. Kept to one
              // line, so a wide word cannot wrap and push the icon out of its
              // own circle.
              MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: Flexible(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: diameter * 0.08),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: palette.onAccent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── the six ──

  Widget _grid(
      Size size, bool landscape, CarPalette palette, double slop, bool calm) {
    final side = carTileSide(landscape ? size.width * 0.58 : size.width);
    final index = carSpeedIndex(widget.tts.rate);

    Widget tile({
      required IconData icon,
      required String label,
      required String hint,
      required VoidCallback onTap,
      VoidCallback? onHold,
      bool enabled = true,
      int order = 0,
    }) {
      return FocusTraversalOrder(
        order: NumericFocusOrder(order.toDouble()),
        child: _CarTile(
          side: side,
          palette: palette,
          slop: slop,
          calm: calm,
          haptics: widget.haptics,
          icon: icon,
          label: label,
          hint: hint,
          enabled: enabled,
          onTap: onTap,
          onHold: onHold,
        ),
      );
    }

    final rows = <List<Widget>>[
      [
        tile(
          icon: Icons.fast_rewind,
          label: 'Back',
          hint: 'One sentence back. Hold for the previous page',
          onTap: () => _skipSentence(-1),
          onHold: () => _skipPage(-1),
          order: 1,
        ),
        tile(
          icon: widget.isBookmarked ? Icons.bookmark : Icons.bookmark_add_outlined,
          label: 'Bookmark',
          hint: 'Marks this page. Never removes one',
          onTap: _bookmark,
          order: 2,
        ),
        tile(
          icon: Icons.fast_forward,
          label: 'Forward',
          hint: 'One sentence on. Hold for the next page',
          onTap: () => _skipSentence(1),
          onHold: () => _skipPage(1),
          order: 3,
        ),
      ],
      [
        tile(
          icon: Icons.remove,
          label: 'Slower',
          hint: 'Speech speed down one step',
          onTap: () => _nudgeRate(-1),
          enabled: index > 0,
          order: 4,
        ),
        tile(
          icon: Icons.bedtime_outlined,
          label: '+${_minutes(widget.sleepStep)} min',
          hint: widget.sleepRemaining == null
              ? 'Start the sleep timer. Hold to clear it'
              : '${carCountdown(widget.sleepRemaining!)} left. Hold to clear it',
          onTap: _addSleep,
          onHold: _cancelSleep,
          order: 5,
        ),
        tile(
          icon: Icons.add,
          label: 'Faster',
          hint: 'Speech speed up one step',
          onTap: () => _nudgeRate(1),
          enabled: index < kCarSpeedLadder.length - 1,
          order: 6,
        ),
      ],
    ];

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows) ...[
            if (row != rows.first) const SizedBox(height: kCarTileGap),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final cell in row) ...[
                  if (cell != row.first) const SizedBox(width: kCarTileGap),
                  cell,
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── layout, palette and ladder ─────────────────────────────────────────────
//
// Pure and public so they can be checked without a widget tree: the sizes and
// contrasts below are the accessibility claim, and a claim that is only made in
// prose rots.

/// The gap between tiles *is* the aiming error margin, not decoration.
const double kCarTileGap = 24.0;

/// Flutter's default 18 px turns a tap that drifts into a drag, and the button
/// never fires — which on a mounted phone on a rough road is most of them.
/// Raised for touch, and only for touch: firing on touch-*down* would be the
/// naive fix and would convert every brush into an action.
const double kCarSlop = 48.0;

/// Diameter of the play/pause target. Clamped rather than fixed because Linux
/// desktop is the primary target and its window is resized freely.
double carTransportDiameter(Size viewport) {
  final byWidth = viewport.width - 64;
  final byHeight = viewport.height * 0.42;
  return math.min(byWidth, byHeight).clamp(160.0, 280.0);
}

/// Side of one of the six tiles. The 88 floor clears both WCAG 2.5.5 (44 px)
/// and Android Automotive's larger target, with room to spare for a glance.
double carTileSide(double width, {double gap = kCarTileGap}) =>
    ((width - 32 - 2 * gap) / 3).clamp(88.0, 132.0);

/// Minutes above a minute, seconds only in the last one: a digit changing every
/// second in peripheral vision is motion carrying no information 59 times out
/// of 60.
String carCountdown(Duration left) {
  if (left.inSeconds <= 0) return 'ending';
  if (left.inSeconds < 60) return '${left.inSeconds} s';
  return '${left.inMinutes} min';
}

/// One rung of the speed control.
///
/// A ladder rather than a slider: a slider is 110 px of aim in a moving vehicle,
/// and because each change restarts the current sentence it would also produce a
/// restart storm.
class CarSpeedStep {
  const CarSpeedStep(this.rate, this.label);

  /// Value for [TtsService.setRate], inside its 0.1–1.0 clamp.
  final double rate;
  final String label;
}

/// Piper's length scale is `1.5 - rate`, so the audible multiplier is
/// `1 / (1.5 - rate)` — these labels are that, not a linear guess. Off the Piper
/// path the mapping is approximate; one vocabulary beats two.
const List<CarSpeedStep> kCarSpeedLadder = [
  CarSpeedStep(0.25, '0.8×'),
  CarSpeedStep(0.50, '1.0×'),
  CarSpeedStep(0.70, '1.25×'),
  CarSpeedStep(0.833, '1.5×'),
  CarSpeedStep(0.929, '1.75×'),
  CarSpeedStep(1.00, '2.0×'),
];

/// Nearest rung to [rate]. Nearest, not exact: the rate may have come from the
/// reader's own slider, and the ladder still has to say something true.
int carSpeedIndex(double rate) {
  var best = 0;
  var bestGap = double.infinity;
  for (var i = 0; i < kCarSpeedLadder.length; i++) {
    final gap = (kCarSpeedLadder[i].rate - rate).abs();
    if (gap < bestGap) {
      bestGap = gap;
      best = i;
    }
  }
  return best;
}

/// Car mode's colours, chosen for glare and a two-second glance rather than to
/// match the app.
///
/// Text pairs target 7:1 and control borders 3:1 (WCAG 1.4.11). The borders are
/// the reason the tiles are legible at all: a tile *fill* against this
/// background sits nearer 1.3:1 and cannot carry the boundary of a control.
class CarPalette {
  const CarPalette._({
    required this.background,
    required this.tile,
    required this.tilePressed,
    required this.border,
    required this.text,
    required this.textDim,
    required this.textDisabled,
    required this.accent,
    required this.accentPressed,
    required this.onAccent,
  });

  final Color background;
  final Color tile;
  final Color tilePressed;
  final Color border;
  final Color text;
  final Color textDim;
  final Color textDisabled;
  final Color accent;
  final Color accentPressed;
  final Color onAccent;

  static CarPalette of(BuildContext context) => resolve(Theme.of(context).brightness);

  static CarPalette resolve(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  static const dark = CarPalette._(
    background: Color(0xFF000000),
    tile: Color(0xFF14161B),
    tilePressed: Color(0xFF2A2E37),
    border: Color(0xFF8A93A5), // 6.8:1 on black
    text: Color(0xFFFFFFFF), // 21:1
    textDim: Color(0xFFC3C9D4), // 12.6:1
    textDisabled: Color(0xFF99A2B3), // 8.1:1
    accent: Color(0xFFF2F5FA),
    accentPressed: Color(0xFFCBD2DE),
    onAccent: Color(0xFF05070A),
  );

  static const light = CarPalette._(
    background: Color(0xFFFFFFFF),
    tile: Color(0xFFF1F3F7),
    tilePressed: Color(0xFFD8DDE6),
    border: Color(0xFF3D4453), // 9.8:1 on white
    text: Color(0xFF0B0D12), // 19:1
    textDim: Color(0xFF3D4453), // 9.8:1
    textDisabled: Color(0xFF4F5768), // 7.2:1
    accent: Color(0xFF0B0D12),
    accentPressed: Color(0xFF303643),
    onAccent: Color(0xFFFFFFFF),
  );
}

// ── controls ──────────────────────────────────────────────────────────────

/// One of the six. Fixed size, fixed place, and present even when it refuses.
class _CarTile extends StatelessWidget {
  const _CarTile({
    required this.side,
    required this.palette,
    required this.slop,
    required this.calm,
    required this.haptics,
    required this.icon,
    required this.label,
    required this.hint,
    required this.onTap,
    this.onHold,
    this.enabled = true,
  });

  final double side;
  final CarPalette palette;
  final double slop;
  final bool calm;
  final bool haptics;
  final IconData icon;
  final String label;
  final String hint;
  final VoidCallback onTap;
  final VoidCallback? onHold;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? palette.text : palette.textDisabled;
    final iconSize = (side * 0.4).clamp(30.0, 54.0);

    return _CarPressable(
      slop: slop,
      calm: calm,
      haptics: haptics,
      enabled: enabled,
      semanticLabel: label,
      semanticHint: hint,
      onTap: onTap,
      onHold: onHold,
      builder: (pressed, focused) => Container(
        width: side,
        height: side,
        decoration: BoxDecoration(
          color: pressed ? palette.tilePressed : palette.tile,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: focused
                ? palette.text
                : (enabled ? palette.border : palette.textDisabled),
            width: focused ? 5 : 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // At its limit the icon is struck through as well as dimmed: colour
            // alone would leave the state invisible in glare, in monochrome and
            // to a colour-blind driver.
            Stack(
              alignment: Alignment.center,
              children: [
                Icon(icon, size: iconSize, color: foreground),
                if (!enabled)
                  SizedBox(
                    width: iconSize,
                    height: iconSize,
                    child: CustomPaint(
                      painter: _SlashPainter(colour: foreground),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            // The icon carries the meaning, so the grid keeps its shape rather
            // than the label its size: a wrapped label would break the row.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SlashPainter extends CustomPainter {
  const _SlashPainter({required this.colour});

  final Color colour;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = colour
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(size.width * 0.12, size.height * 0.88),
      Offset(size.width * 0.88, size.height * 0.12),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SlashPainter old) => old.colour != colour;
}

/// The press behaviour every car control shares.
///
/// Taps fire on release, with a raised slop tolerance so a thumb that drifts on
/// a bump still counts. The optional hold is driven off the same recogniser, so
/// it inherits that tolerance too — [LongPressGestureRecognizer] does not let
/// its pre-accept tolerance be set, and 18 px of travel is nothing in a car.
class _CarPressable extends StatefulWidget {
  const _CarPressable({
    required this.slop,
    required this.calm,
    required this.haptics,
    required this.semanticLabel,
    required this.semanticHint,
    required this.builder,
    this.onTap,
    this.onHold,
    this.enabled = true,
    this.holdDuration = const Duration(milliseconds: 600),
    this.holdTicks = false,
  });

  final double slop;

  /// Reduced motion: the press feedback becomes an instant change of colour
  /// rather than a scale, and spinners are replaced by a static icon.
  final bool calm;
  final bool haptics;
  final String semanticLabel;
  final String semanticHint;

  /// Called with the press and keyboard-focus states, so each control draws
  /// them in its own shape — a rectangular focus ring around a circle reads as
  /// a rendering bug.
  final Widget Function(bool pressed, bool focused) builder;
  final VoidCallback? onTap;
  final VoidCallback? onHold;

  /// Appearance and semantics only. A control at its limit still fires its
  /// handler — that is what produces the "refused" haptic, and a control that
  /// swallowed the press silently would send the driver looking at the screen.
  final bool enabled;

  final Duration holdDuration;

  /// Haptic ticks on the way to a hold, so its progress is felt rather than
  /// watched. Used by the exit control, where the wait is longest.
  final bool holdTicks;

  @override
  State<_CarPressable> createState() => _CarPressableState();
}

class _CarPressableState extends State<_CarPressable> {
  bool _pressed = false;

  /// Whether to *draw* the focus ring. Follows the focus highlight mode, so a
  /// thumb does not leave rings behind it.
  bool _focused = false;

  /// Whether this control actually holds focus. Tracked separately from
  /// [_focused] because the semantics tree needs the fact, not the highlight
  /// policy: with a screen reader driving, the highlight can be off while focus
  /// is very much here.
  bool _hasFocus = false;

  bool _holdFired = false;
  Timer? _hold;
  final _ticks = <Timer>[];

  @override
  void dispose() {
    _cancelHold();
    super.dispose();
  }

  void _cancelHold() {
    _hold?.cancel();
    _hold = null;
    for (final tick in _ticks) {
      tick.cancel();
    }
    _ticks.clear();
  }

  void _down(TapDownDetails _) {
    setState(() => _pressed = true);
    _holdFired = false;
    if (widget.onHold == null) return;
    if (widget.holdTicks) {
      for (final ms in const [250, 500, 750]) {
        _ticks.add(Timer(Duration(milliseconds: ms), () {
          if (widget.haptics) HapticFeedback.selectionClick();
        }));
      }
    }
    _hold = Timer(widget.holdDuration, () {
      if (!mounted) return;
      _holdFired = true;
      setState(() => _pressed = false);
      widget.onHold!.call();
    });
  }

  void _up(TapUpDetails _) {
    _cancelHold();
    if (mounted) setState(() => _pressed = false);
    // A hold that already fired must not also fire the tap: releasing after
    // "previous page" should not additionally step a sentence.
    if (_holdFired) return;
    widget.onTap?.call();
  }

  void _cancel() {
    _cancelHold();
    if (mounted) setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(_pressed, _focused);

    return Semantics(
      container: true,
      button: true,
      enabled: widget.enabled,
      // The Focus that knows about focus is inside the ExcludeSemantics below,
      // so without these two the semantics tree never learns that Tab moved —
      // and a screen-reader user tabbing the six hears nothing at all.
      focusable: true,
      focused: _hasFocus,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      // The semantic tap bypasses the recogniser entirely, which is why the
      // raised slop can be a touch-only concern.
      onTap: widget.onTap,
      onLongPress: widget.onHold,
      child: ExcludeSemantics(
        child: RawGestureDetector(
          // Slop is fixed when the recogniser is built, so a change of input
          // mode has to rebuild it rather than mutate it.
          key: ValueKey(widget.slop),
          behavior: HitTestBehavior.opaque,
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(
                debugOwner: this,
                preAcceptSlopTolerance: widget.slop,
                postAcceptSlopTolerance: widget.slop,
              ),
              (recogniser) => recogniser
                ..onTapDown = _down
                ..onTapUp = _up
                ..onTapCancel = _cancel,
            ),
          },
          // Tab reaches every control and Enter fires it — Space is left alone
          // because it means play/pause everywhere in this mode, focus or no
          // focus.
          child: FocusableActionDetector(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            },
            onShowFocusHighlight: (shown) {
              if (mounted && shown != _focused) setState(() => _focused = shown);
            },
            onFocusChange: (has) {
              if (mounted && has != _hasFocus) setState(() => _hasFocus = has);
            },
            child: widget.calm
                ? child
                : AnimatedScale(
                    scale: _pressed ? 0.97 : 1.0,
                    duration: const Duration(milliseconds: 90),
                    child: child,
                  ),
          ),
        ),
      ),
    );
  }
}
