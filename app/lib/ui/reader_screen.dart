import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../models/annotation.dart';
import '../models/bookmark.dart';
import '../services/chapter_index.dart';
import '../services/classifier.dart';
import '../services/document_cache.dart';
import '../services/ocr_service.dart';
import '../services/reader_service.dart';
import '../services/piper_tts.dart';
import '../services/spoken_text.dart';
import '../services/settings_service.dart';
import '../services/sleep_timer.dart';
import '../services/stats_service.dart';
import '../services/media_player_service.dart';
import '../services/tts_service.dart';
import 'bookmarks_sheet.dart';
import 'music_sheet.dart';
import 'notes_sheet.dart';
import 'reader_playback.dart';
import 'summary_sheet.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  final SettingsService settings;
  final StatsService stats;
  const ReaderScreen({
    super.key,
    required this.book,
    required this.settings,
    required this.stats,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with ReaderPlayback<ReaderScreen> {
  final _controller = PdfViewerController();
  final _searchField = TextEditingController();
  final _searchFocus = FocusNode();
  late final TtsService _tts;
  final _music = MediaPlayerService();
  PdfTextSearcher? _searcher;

  int _page = 1;
  int _pageCount = 0;
  BookType? _type;
  Classification? _classification;
  bool _ttsAvailable = true;
  bool _searching = false;
  String? _busy;
  bool _showOutline = false;

  /// AI assist is a docked panel, not a sheet over the page.
  ///
  /// A summary is meant to be read *against* the passage it came from, so
  /// covering the passage to show it defeats the feature. It sits on the left
  /// beside the contents panel, where a reader already expects a sidebar.
  bool _showAi = false;
  late bool _night = widget.settings.nightMode;

  /// When on, tapping the page starts reading from that sentence.
  bool _readFromTap = true;

  /// When on, the view follows the spoken sentence down the page.
  bool _autoScroll = true;

  List<PdfOutlineNode> _outline = const [];

  /// The current page's text split into sentences, used for both the
  /// follow-along highlight and tap-to-start.
  PageSpeech? _speech;
  int? _speechPage;
  int? _activeSegment;

  /// The page whose sentences the reader currently wants. A load that finishes
  /// after this has moved on is dropped rather than installed.
  int? _speechWanted;

  /// Index of the segment speech started from, so segment 0 of the TTS run maps
  /// back to the right sentence on the page.
  int _segmentOffset = 0;

  /// First pages of the book's sections, for the "end of chapter" sleep ending.
  ChapterIndex _chapters = ChapterIndex.empty;

  /// Where to reopen the book. Read once in initState, because the viewer needs
  /// it as an initial value rather than a live one.
  late final int _resumePage = widget.settings.lastPage(widget.book.id) ?? 1;

  @override
  void initState() {
    super.initState();
    _tts = TtsService()..addListener(_onTts);
    _tts.onPageFinished = _continueToNextPage;
    _tts.onSegment = (index) {
      if (!mounted) return;
      final active = index == null ? null : _segmentOffset + index;
      // Before the setState, and only when non-null: stop() clears the
      // highlight by reporting null, and that must not clear the resume point.
      if (active != null) noteSpoken(active);
      setState(() => _activeSegment = active);
      if (active != null && _autoScroll) _scrollToSegment(active);
    };
    _tts.voice = widget.settings.voice;
    initPlayback();
    _resolveType();
    _checkTts();
  }

  Future<void> _checkTts() async {
    final available = await TtsService.isAvailable();
    if (mounted) setState(() => _ttsAvailable = available);
  }

  void _onTts() {
    // Every start, stop and pause passes through here, so this is the one place
    // the sleep countdown needs holding and releasing.
    syncSleepHold();
    setState(() {});
  }

  // ── the ReaderPlayback seam ──
  //
  // Car Mode and the sleep timer reach the book only through these. Car Mode
  // never constructs a TtsService: two instances in one process render Piper
  // chunks to byte-identical temp paths and eat each other's audio.

  @override
  TtsService get tts => _tts;

  @override
  SettingsService get settings => widget.settings;

  @override
  Book get book => widget.book;

  @override
  MediaPlayerService get music => _music;

  @override
  ChapterIndex get chapters => _chapters;

  @override
  String get bookTitle => widget.book.title;

  @override
  int get page => _page;

  @override
  int get pageCount => _pageCount;

  @override
  int get sentenceCount =>
      _speechPage == _page ? (_speech?.segments.length ?? 0) : 0;

  @override
  String? get currentSentence {
    final speech = _speech;
    final index = _activeSegment;
    // Null rather than a guess while the list is being rebuilt: the display is
    // opt-in and a stale sentence is worse than none.
    if (speech == null || index == null || _speechPage != _page) return null;
    if (index < 0 || index >= speech.segments.length) return null;
    return speech.segments[index].text;
  }

  @override
  bool get isBookmarkedHere =>
      widget.settings.isBookmarked(widget.book.id, _page);

  @override
  String? get busyMessage => _busy;

  @override
  Future<void> togglePlay() => _speakCurrentPage();

  @override
  Future<bool> bookmarkHere() async {
    final id = widget.book.id;
    final target = _controller.pageNumber ?? _page;
    // Adds only, never removes: a mis-aimed second press in a car must not
    // throw away the bookmark the first one made.
    if (widget.settings.isBookmarked(id, target)) return false;
    var preview = '';
    try {
      preview = (await ReaderService.pageText(widget.book, target))
          .replaceAll('\n', ' ')
          .trim();
    } catch (_) {}
    await widget.settings.addBookmark(
      id,
      Bookmark(
        page: target,
        preview: preview,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) setState(() {});
    return true;
  }

  @override
  Future<void> speakAt(int pageNumber, int sentence,
      {required bool resume}) async {
    final target = _pageCount > 0 ? pageNumber.clamp(1, _pageCount) : pageNumber;
    // Only once the viewer is laid out — goToPage throws before that.
    if (_pageCount > 0 && target != (_controller.pageNumber ?? _page)) {
      _controller.goToPage(pageNumber: target);
    }
    final speech = await _loadSpeech(target);
    if (!mounted || speech == null || speech.isEmpty) return;
    // A negative index counts back from the end of the page.
    final index = (sentence < 0 ? speech.segments.length + sentence : sentence)
        .clamp(0, speech.segments.length - 1);
    if (!resume) {
      // Skipping while paused moves the cursor and stays paused.
      _segmentOffset = index;
      noteSpeechStart(target, index);
      setState(() => _activeSegment = index);
      return;
    }
    await _speakFrom(speech, index, target);
  }

  @override
  void onCarModeChanged(bool active) {
    if (!active) return;
    // Search and the contents panel have no place behind a driving overlay, and
    // a live searcher keeps repainting matches nobody can see.
    if (_searching) {
      _searcher?.resetTextSearch();
      _searchField.clear();
      _searching = false;
    }
    _showOutline = false;
  }

  Future<void> _resolveType() async {
    final override = widget.settings.typeOverride(widget.book.id);
    if (override != null) {
      setState(() => _type = override);
      return;
    }
    final cached = widget.settings.cachedClassification(widget.book.id);
    if (cached != null) {
      setState(() => _type = cached);
      return;
    }
    try {
      final result = await ReaderService.classify(widget.book);
      if (!mounted) return;
      await widget.settings.cacheClassification(widget.book.id, result.type);
      setState(() {
        _type = result.type;
        _classification = result;
      });
    } catch (_) {
      if (mounted) setState(() => _type = BookType.storybook);
    }
  }

  // ── reading position ──

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null) return;
    setState(() {
      _page = pageNumber;
      // Also supersedes any sentence load still in flight for the page just
      // left, so it cannot install itself over this one.
      _speechWanted = pageNumber;
      if (_speechPage != pageNumber) {
        _speech = null;
        _activeSegment = null;
      }
    });
    // Persist as you read, so closing the app mid-chapter loses nothing.
    widget.settings.setLastPage(widget.book.id, pageNumber);
    widget.stats.recordPage();
  }

  Future<void> _jumpToPage() async {
    final controller = TextEditingController(text: '$_page');
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            helperText: '1 – $_pageCount',
          ),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('Go'),
          ),
        ],
      ),
    );
    if (target != null && target >= 1 && target <= _pageCount) {
      _controller.goToPage(pageNumber: target);
    }
  }

  // ── speech ──

  /// Load and cache the current page's sentence map.
  Future<PageSpeech?> _loadSpeech(int page) async {
    // Recorded before the cache hit, not after: returning a cached page while
    // a load for a *different* one is still in flight would otherwise leave
    // that load's page as the one wanted, and it would install itself over the
    // page now being read — killing the highlight for the rest of it.
    _speechWanted = page;
    if (_speech != null && _speechPage == page) return _speech;
    try {
      final speech = await ReaderService.pageSpeech(widget.book, page);
      // Superseded while it loaded. Installing it now would leave _speech — and
      // with it the highlight and the auto-scroll — describing a page the reader
      // has already left, which auto-scroll would then yank back to.
      if (!mounted || _speechWanted != page) return null;
      setState(() {
        _speech = speech;
        _speechPage = page;
      });
      return speech;
    } catch (_) {
      return null;
    }
  }

  /// Start reading from a tapped point on the page.
  Future<void> _speakFromTap(Offset localPosition) async {
    final hit = _controller.getPdfPageHitTestResult(
      localPosition,
      useDocumentLayoutCoordinates: false,
    );
    if (hit == null) return;

    final speech = await _loadSpeech(hit.page.pageNumber);
    if (speech == null || speech.isEmpty) return;

    final segment = speech.segmentAt(hit.offset);
    if (segment == null) return;

    final from = speech.segments.indexOf(segment);
    await _speakFrom(speech, from, hit.page.pageNumber);
  }

  /// Speak [speech] starting at segment [from].
  Future<void> _speakFrom(PageSpeech speech, int from, int page) async {
    if (!_ttsAvailable) {
      _snack(TtsService.unavailableMessage);
      return;
    }
    // Every path into speech funnels through here, so this is the one place the
    // expiry latch is cleared. Scattering that across the entry points would
    // leave the next one added needing to remember.
    sleep.clearExpiry();
    await _tts.stop();
    _segmentOffset = from;
    noteSpeechStart(page, from);
    setState(() => _activeSegment = from);
    final segments =
        speech.segments.sublist(from).map((s) => s.text).toList();
    await _tts.speakSegments(segments);
  }

  Future<void> _speakCurrentPage() async {
    if (_tts.isSpeaking) {
      await _tts.stop();
      return;
    }
    if (!_ttsAvailable) {
      _snack(TtsService.unavailableMessage);
      return;
    }
    // The OCR fallback below is the one play path that never reaches
    // _speakFrom, so the expiry latch has to be cleared here as well.
    sleep.clearExpiry();
    try {
      // The controller is the source of truth: _page stays 1 until onPageChanged
      // fires, so pressing Play right after opening would otherwise read page 1.
      final page = _controller.pageNumber ?? _page;
      if (page != _page) setState(() => _page = page);

      // Prefer the sentence-mapped path so the highlight follows along.
      final speech = await _loadSpeech(page);
      if (speech != null && !speech.isEmpty) {
        // From the cursor, not the top: pause is stop on Linux, so restarting
        // at sentence 0 would re-read the whole page after every pause.
        await _speakFrom(
          speech,
          resumeSentence.clamp(0, speech.segments.length - 1),
          page,
        );
        return;
      }

      // A scanned page has no embedded text, so fall through to OCR rather than
      // refusing to read. It takes seconds, hence the progress banner.
      var text = await ReaderService.pageText(widget.book, page);
      if (text.trim().isEmpty) {
        if (!await OcrService.isAvailable()) {
          _snack(OcrService.unavailableMessage);
          return;
        }
        setState(() => _busy = 'Scanned page — running OCR…');
        text = await ReaderService.pageText(
          widget.book,
          page,
          ocrFallback: true,
          onProgress: (stage) {
            if (mounted) setState(() => _busy = stage);
          },
        );
        if (mounted) setState(() => _busy = null);
      }
      if (text.trim().isEmpty) {
        _snack('OCR found no text on this page.');
        return;
      }
      _segmentOffset = 0;
      noteSpeechStart(page, 0);
      await _tts.speak(text);
    } catch (e) {
      if (mounted) setState(() => _busy = null);
      _snack('$e');
    }
  }

  /// Run OCR on the current page and show what it found, so the user can check
  /// quality before trusting read-aloud or a summary built on it.
  Future<void> _runOcr() async {
    if (!await OcrService.isAvailable()) {
      _snack(OcrService.unavailableMessage);
      return;
    }
    setState(() => _busy = 'Running OCR on page $_page…');
    try {
      final text = await OcrService.recognisePage(
        widget.book,
        _page,
        onProgress: (stage) {
          if (mounted) setState(() => _busy = stage);
        },
      );
      if (!mounted) return;
      setState(() => _busy = null);
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          builder: (context, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
            children: [
              Text('OCR — page $_page',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('${text.trim().length} characters recognised',
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 16),
              SelectableText(
                text.trim().isEmpty ? '(nothing recognised)' : text.trim(),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _busy = null);
      _snack('$e');
    }
  }

  /// Scroll the spoken sentence into view.
  ///
  /// Sentence rectangles are in PDF page space, so they are converted to
  /// document space before scrolling. Only the vertical position matters —
  /// yanking horizontally while zoomed in would be disorienting.
  void _scrollToSegment(int index) {
    // Car Mode covers the viewer, so this would be a 420 ms animation per
    // sentence with nothing on screen to show for it.
    if (inCarMode) return;
    final speech = _speech;
    if (speech == null || _speechPage == null) return;
    if (index < 0 || index >= speech.segments.length) return;

    final rects = speech.rectsFor(speech.segments[index]);
    if (rects.isEmpty) return;

    try {
      final pageIndex = _speechPage! - 1;
      final layout = _controller.layout.pageLayouts[pageIndex];
      final page = _controller.pages[pageIndex];
      final target = rects.first
          .toRectInDocument(page: page, pageRect: layout)
          .inflate(28);
      _controller.ensureVisible(
        target,
        // One 420 ms slide per sentence is the most repetitive motion in the
        // app; a reader who has asked the system to stop animating gets the
        // same position without the travel.
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 420),
      );
    } catch (_) {
      // Layout not ready yet — the next segment will scroll instead.
    }
  }

  /// Paint a highlight over the sentence currently being spoken, so the eye can
  /// follow the voice. Drawn per page, so only the visible page costs anything.
  void _paintSpokenSegment(Canvas canvas, Rect pageRect, PdfPage page) {
    final speech = _speech;
    final active = _activeSegment;
    if (speech == null || active == null) return;
    if (_speechPage != page.pageNumber) return;
    if (active < 0 || active >= speech.segments.length) return;

    final paint = Paint()
      ..color = Theme.of(context).colorScheme.primary.withValues(alpha: 0.28);

    for (final rect in speech.rectsFor(speech.segments[active])) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          rect
              .toRect(page: page, scaledPageSize: pageRect.size)
              .translate(pageRect.left, pageRect.top)
              .inflate(1.5),
          const Radius.circular(2),
        ),
        paint,
      );
    }
  }

  Future<void> _toggleBookmark() async {
    final id = widget.book.id;
    // The controller is authoritative; _page lags until onPageChanged fires.
    final page = _controller.pageNumber ?? _page;
    if (page != _page) setState(() => _page = page);

    if (widget.settings.isBookmarked(id, page)) {
      await widget.settings.removeBookmark(id, page);
    } else {
      // Capture the page's opening words so the bookmark list is readable.
      var preview = '';
      try {
        preview = (await ReaderService.pageText(widget.book, page))
            .replaceAll('\n', ' ')
            .trim();
      } catch (_) {}
      await widget.settings.addBookmark(
        id,
        Bookmark(
          page: page,
          preview: preview,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  /// Highlight the sentence currently spoken (or the first on the page), since
  /// the PDF viewer's own selection is not exposed to us here.
  Future<void> _annotateCurrent() async {
    final speech = await _loadSpeech(_controller.pageNumber ?? _page);
    if (speech == null || speech.isEmpty) {
      _snack('No selectable text on this page.');
      return;
    }
    final index = _activeSegment ?? 0;
    final quote = speech
        .segments[index.clamp(0, speech.segments.length - 1)]
        .text
        .trim();

    if (!mounted) return;
    final edit = await showAnnotationEditor(context: context, quote: quote);
    if (edit == null) return;
    await widget.settings.addAnnotation(
      widget.book.id,
      Annotation(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        page: _controller.pageNumber ?? _page,
        quote: quote,
        note: edit.note,
        color: edit.color,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) setState(() {});
  }

  /// Background audio — the fallback when speech is unavailable or unwanted.
  void _openMusic() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MusicSheet(settings: widget.settings, player: _music),
    );
  }

  void _openNotes() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => NotesSheet(
        book: widget.book,
        settings: widget.settings,
        onGoToPage: (page) => _controller.goToPage(pageNumber: page),
      ),
    ).then((_) => mounted ? setState(() {}) : null);
  }

  void _openBookmarks() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => BookmarksSheet(
        book: widget.book,
        settings: widget.settings,
        onGoToPage: (page) => _controller.goToPage(pageNumber: page),
      ),
    );
  }

  Future<void> _pickVoice() async {
    final voices = _tts.availableVoices;
    if (voices.isEmpty) {
      _snack(PiperTts.installMessage);
      return;
    }
    final current = _tts.voice ?? voices.first;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Voice'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 10),
            child: Text(
              'Engine: ${TtsService.engineName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final v in voices)
            RadioListTile<String>(
              value: v,
              // ignore: deprecated_member_use
              groupValue: current,
              title: Text(v, style: const TextStyle(fontSize: 13)),
              subtitle: Text(_describeVoice(v),
                  style: const TextStyle(fontSize: 11)),
              // ignore: deprecated_member_use
              onChanged: (value) => Navigator.pop(context, value),
            ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
            child: Text(
              'More voices:\n'
              '  ~/.local/share/piper-venv/bin/python -m piper.download_voices <name>',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
    if (chosen == null) return;
    setState(() => _tts.voice = chosen);
    await widget.settings.setVoice(chosen);
  }

  /// Turn `en_GB-alba-medium` into something readable.
  static String _describeVoice(String name) {
    final parts = name.split('-');
    if (parts.length < 2) return name;
    final locale = parts.first.replaceAll('_', '-');
    final quality = parts.length > 2 ? parts.last : '';
    return quality.isEmpty ? locale : '$locale · $quality quality';
  }

  Future<void> _continueToNextPage() async {
    // The latch covers the window between this firing and speech restarting:
    // a timer expiring in there would stop an engine that is already idle, and
    // the queued advance would speak anyway — all night.
    if (!mounted || sleep.hasExpired) return;
    // TtsService reports "stopped" one line before it reports "page finished",
    // so _onTts has already run syncSleepHold and held the timer by the time we
    // get here — and SleepTimer.pageFinished is ignored while held. Lift that
    // for the endings with no clock to freeze, or they never fire at all and
    // the book reads on all night. Car Mode's hold is deliberate and stays: it
    // exists so a section ending cannot silence the audio mid-drive.
    if (sleep.mode != SleepMode.duration &&
        !(inCarMode && widget.settings.sleepHoldInCar)) {
      sleep.resume();
    }
    // The page has been read out, so the end-of-page and end-of-chapter endings
    // land here. The latch they set is the same one the duration ending sets.
    if (sleepEndsHere()) return;
    // Captured before any await: goToPage can fire onPageChanged in between,
    // and reading _page + 1 a second time would then fetch the page after next.
    final next = _page + 1;
    if (next > _pageCount) return;
    _controller.goToPage(pageNumber: next);

    // Prefer the sentence-mapped path. Falling through to speak() would hand
    // Piper 350-character chunks while _segmentOffset still holds a sentence
    // offset, so onSegment would report indices into a different list.
    final speech = await _loadSpeech(next);
    if (!mounted || sleep.hasExpired) return;
    if (speech != null && !speech.isEmpty) return _speakFrom(speech, 0, next);

    final text = await ReaderService.pageText(widget.book, next);
    if (!mounted || sleep.hasExpired) return;
    if (text.trim().isEmpty) return;
    // No sentence map for this page, so onSegment will report chunk indices;
    // zero the offset rather than add them to a stale sentence position.
    _segmentOffset = 0;
    noteSpeechStart(next, 0);
    await _tts.speak(text);
  }

  // ── chrome ──

  Future<void> _changeType() async {
    final chosen = await showDialog<BookType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Book type'),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Text(
              'A storybook is only read aloud — no AI model is ever contacted. '
              'A textbook additionally offers summaries, which do call a model.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          for (final t in BookType.values)
            RadioListTile<BookType>(
              value: t,
              // ignore: deprecated_member_use
              groupValue: _type,
              title: Text(t.label),
              subtitle: Text(t.usesLlm ? 'Read aloud + AI summary' : 'Read aloud only'),
              // ignore: deprecated_member_use
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (chosen == null) return;
    await widget.settings.setTypeOverride(widget.book.id, chosen);
    setState(() => _type = chosen);
  }

  void _openSummary() {
    setState(() {
      _showAi = !_showAi;
      // The two side panels would halve the page between them; opening one
      // closes the other.
      if (_showAi) _showOutline = false;
    });
  }

  /// The docked assistant. Width is capped so the page never becomes a column.
  Widget _aiPanel(ThemeData theme) {
    final width = (MediaQuery.sizeOf(context).width * 0.34).clamp(320.0, 520.0);
    return SizedBox(
      width: width,
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text('AI assist', style: theme.textTheme.titleSmall),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => setState(() => _showAi = false),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SummarySheet(
                book: widget.book,
                settings: widget.settings,
                initialPage: _page,
                pageCount: _pageCount,
                embedded: true,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleNight() {
    setState(() => _night = !_night);
    widget.settings.setNightMode(_night);
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    DocumentCache.release(widget.book);
    // Before the engine goes: the sleep timer and the keep-awake inhibitor do
    // not ride on the TTS session, so nothing else would ever cancel them.
    disposePlayback();
    _tts.removeListener(_onTts);
    _tts.dispose();
    _music.dispose();
    _searcher?.dispose();
    _searchField.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isTextbook = _type == BookType.textbook;

    return Scaffold(
      // Car Mode is the whole screen or it is not a driving surface. It brings
      // its own PopScope and Escape binding, so back exits the overlay rather
      // than dumping a driver back into the library.
      appBar: _carModeBar(theme, isTextbook),
      body: Stack(
        // The body slot grows by both bars on the way into Car Mode, so the
        // viewer below relayouts once each way. That is the price of the
        // overlay being the whole screen: leaving either bar up would put a
        // strip of ordinary reader chrome along the edge of a driving surface.
        fit: StackFit.expand,
        children: [
          // Behind the overlay the reader is scenery. Painting over it is not
          // enough: a screen reader would still walk the whole page of book
          // text before reaching the six controls, and a tap landing in a
          // safe-area inset — where Car Mode's own hit-test layer stops — would
          // fall through to tap-to-read and restart the book somewhere else.
          ExcludeSemantics(
            excluding: inCarMode,
            child: IgnorePointer(
              ignoring: inCarMode,
              child: _readerBody(theme),
            ),
          ),
          // A sibling of the reader's body, never a child of it: night mode
          // wraps the viewer in an inverting ColorFilter, and a driving UI
          // rendered photo-negative is worse than no driving UI.
          if (inCarMode) Positioned.fill(child: carOverlay()),
        ],
      ),
      bottomNavigationBar: inCarMode ? null : _bottomBar(theme, isTextbook),
    );
  }

  PreferredSizeWidget? _carModeBar(ThemeData theme, bool isTextbook) {
    if (inCarMode) return null;
    return _searching ? _searchBar(theme) : _titleBar(theme, isTextbook);
  }

  Widget _readerBody(ThemeData theme) {
    return Column(
      children: [
        if (_busy != null)
          Material(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _busy!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(
          child: Row(
            children: [
              if (_showOutline && _outline.isNotEmpty) _outlinePanel(theme),
              if (_showAi) _aiPanel(theme),
              Expanded(child: _viewer(theme)),
            ],
          ),
        ),
      ],
    );
  }

  PreferredSizeWidget _titleBar(ThemeData theme, bool isTextbook) {
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium),
          if (_pageCount > 0)
            Text('Page $_page of $_pageCount',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
      actions: [
        sleepChip(),
        if (_outline.isNotEmpty)
          IconButton(
            icon: Icon(_showOutline ? Icons.menu_open : Icons.toc),
            tooltip: 'Contents',
            onPressed: () => setState(() => _showOutline = !_showOutline),
          ),
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'Search in book',
          onPressed: () {
            setState(() => _searching = true);
            _searchFocus.requestFocus();
          },
        ),
        IconButton(
          icon: Icon(widget.settings.isBookmarked(widget.book.id, _page)
              ? Icons.bookmark
              : Icons.bookmark_border),
          tooltip: 'Bookmark this page',
          onPressed: _toggleBookmark,
        ),
        // Everything below is used occasionally, so it lives in a menu rather
        // than competing for space with search and bookmarks.
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'car':
                enterCarMode();
              case 'sleep':
                openSleepSheet();
              case 'music':
                _openMusic();
              case 'highlight':
                _annotateCurrent();
              case 'notes':
                _openNotes();
              case 'bookmarks':
                _openBookmarks();
              case 'voice':
                _pickVoice();
              case 'tap':
                setState(() => _readFromTap = !_readFromTap);
              case 'autoscroll':
                setState(() => _autoScroll = !_autoScroll);
              case 'ocr':
                _runOcr();
              case 'night':
                _toggleNight();
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'car',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.directions_car_outlined),
                title: Text('Car Mode'),
                subtitle: Text('Six large controls, nothing to read',
                    style: TextStyle(fontSize: 11)),
              ),
            ),
            PopupMenuItem(
              value: 'sleep',
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.bedtime_outlined),
                title: const Text('Sleep timer'),
                subtitle: Text(
                  _chapters.hasChapters
                      ? 'Duration, end of page, or end of chapter'
                      : 'Duration, or end of page',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'music',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.library_music_outlined),
                title: Text('Background audio'),
              ),
            ),
            const PopupMenuItem(
              value: 'highlight',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.format_quote),
                title: Text('Highlight this sentence'),
              ),
            ),
            const PopupMenuItem(
              value: 'notes',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.edit_note),
                title: Text('Highlights and notes'),
              ),
            ),
            const PopupMenuItem(
              value: 'bookmarks',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.bookmarks_outlined),
                title: Text('All bookmarks'),
              ),
            ),
            PopupMenuItem(
              value: 'voice',
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('Voice'),
                subtitle: Text(TtsService.engineName,
                    style: const TextStyle(fontSize: 11)),
              ),
            ),
            CheckedPopupMenuItem(
              value: 'tap',
              checked: _readFromTap,
              child: const Text('Tap to read from here'),
            ),
            CheckedPopupMenuItem(
              value: 'autoscroll',
              checked: _autoScroll,
              child: const Text('Follow the voice'),
            ),
            const PopupMenuItem(
              value: 'ocr',
              child: ListTile(
                dense: true,
                leading: Icon(Icons.document_scanner_outlined),
                title: Text('Run OCR on this page'),
              ),
            ),
            CheckedPopupMenuItem(
              value: 'night',
              checked: _night,
              child: const Text('Night mode'),
            ),
          ],
        ),
        if (_type != null)
          Padding(
            padding: const EdgeInsets.only(right: 8, left: 4),
            child: ActionChip(
              avatar: Icon(
                isTextbook ? Icons.school_outlined : Icons.auto_stories_outlined,
                size: 16,
              ),
              label: Text(_type!.label),
              onPressed: _changeType,
              tooltip: _classification == null
                  ? 'Change book type'
                  : 'Auto-detected: ${_classification!.signals.take(3).join(", ")}',
            ),
          ),
      ],
    );
  }

  PreferredSizeWidget _searchBar(ThemeData theme) {
    final searcher = _searcher;
    final matches = searcher?.matches.length ?? 0;
    final current = searcher?.currentIndex;
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          _searcher?.resetTextSearch();
          _searchField.clear();
          setState(() => _searching = false);
        },
      ),
      title: TextField(
        controller: _searchField,
        focusNode: _searchFocus,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Search in this book',
          border: InputBorder.none,
        ),
        onChanged: (v) => _searcher?.startTextSearch(v, caseInsensitive: true),
        onSubmitted: (_) => _searcher?.goToNextMatch(),
      ),
      actions: [
        if (_searchField.text.isNotEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                matches == 0
                    ? 'none'
                    : '${current == null ? "–" : current + 1}/$matches',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_up),
          tooltip: 'Previous match',
          onPressed: matches == 0 ? null : () => _searcher?.goToPrevMatch(),
        ),
        IconButton(
          icon: const Icon(Icons.keyboard_arrow_down),
          tooltip: 'Next match',
          onPressed: matches == 0 ? null : () => _searcher?.goToNextMatch(),
        ),
      ],
    );
  }

  Widget _outlinePanel(ThemeData theme) {
    return Container(
      width: 280,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          right: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                Text('Contents', style: theme.textTheme.titleSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => _showOutline = false),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                for (final node in _outline) ..._outlineTiles(node, 0, theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _outlineTiles(PdfOutlineNode node, int depth, ThemeData theme) {
    return [
      InkWell(
        onTap: node.dest == null ? null : () => _controller.goToDest(node.dest),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16.0 + depth * 14, 7, 12, 7),
          child: Text(
            node.title,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: depth == 0 ? FontWeight.w600 : FontWeight.normal,
              color: depth == 0
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      for (final child in node.children) ..._outlineTiles(child, depth + 1, theme),
    ];
  }

  Widget _viewer(ThemeData theme) {
    final viewer = PdfViewer.file(
      widget.book.path,
      controller: _controller,
      params: PdfViewerParams(
        backgroundColor: _night ? const Color(0xFF101014) : theme.colorScheme.surfaceDim,
        onViewerReady: (document, controller) async {
          final outline = await document.loadOutline();
          if (!mounted) return;
          setState(() {
            _pageCount = document.pages.length;
            _outline = outline;
            _chapters =
                ChapterIndex.fromPdfOutline(outline, document.pages.length);
            _searcher = PdfTextSearcher(controller)..addListener(_onSearch);
          });
          widget.settings.setPageCount(widget.book.id, document.pages.length);
          widget.settings.markOpened(widget.book.id);
          // Restore the reading position once the document is actually laid out.
          if (_resumePage > 1 && _resumePage <= document.pages.length) {
            controller.goToPage(pageNumber: _resumePage);
          }
        },
        onPageChanged: _onPageChanged,
        pagePaintCallbacks: [
          if (_searcher != null) _searcher!.pageTextMatchPaintCallback,
          _paintSpokenSegment,
        ],
        viewerOverlayBuilder: (context, size, handleLinkTap) => [
          // Tap anywhere in the text to start reading from that sentence.
          // Must be translucent and forward taps, or links stop working.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTapUp: (details) {
              handleLinkTap(details.localPosition);
              if (_readFromTap) _speakFromTap(details.localPosition);
            },
          ),
          PdfViewerScrollThumb(
            controller: _controller,
            orientation: ScrollbarOrientation.right,
            thumbSize: const Size(40, 25),
            thumbBuilder: (context, thumbSize, pageNumber, controller) => Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  '$pageNumber',
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    // Night mode inverts the rendered page. Inverting hue twice keeps colour
    // images looking sane rather than photo-negative.
    return _night
        ? ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              -1, 0, 0, 0, 255, //
              0, -1, 0, 0, 255, //
              0, 0, -1, 0, 255, //
              0, 0, 0, 1, 0, //
            ]),
            child: viewer,
          )
        : viewer;
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  Widget _bottomBar(ThemeData theme, bool isTextbook) {
    return BottomAppBar(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton.filledTonal(
            icon: _tts.isPreparing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(_tts.isSpeaking ? Icons.stop : Icons.play_arrow),
            tooltip: !_ttsAvailable
                ? 'No speech engine installed'
                : _tts.isSpeaking
                    ? 'Stop reading'
                    : 'Read this page aloud · ${TtsService.engineName}',
            onPressed: _speakCurrentPage,
          ),
          SizedBox(
            width: 110,
            child: Slider(
              value: _tts.rate,
              min: 0.1,
              max: 1.0,
              onChanged: (v) => setSpeechRate(v),
            ),
          ),
          const VerticalDivider(indent: 14, endIndent: 14),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous page',
            onPressed: _page <= 1
                ? null
                : () => _controller.goToPage(pageNumber: _page - 1),
          ),
          TextButton(
            onPressed: _pageCount == 0 ? null : _jumpToPage,
            child: Text(_pageCount == 0 ? '—' : '$_page / $_pageCount'),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next page',
            onPressed: _page >= _pageCount
                ? null
                : () => _controller.goToPage(pageNumber: _page + 1),
          ),
          const VerticalDivider(indent: 14, endIndent: 14),
          IconButton(
            icon: const Icon(Icons.zoom_out),
            tooltip: 'Zoom out',
            onPressed: () => _controller.zoomDown(),
          ),
          IconButton(
            icon: const Icon(Icons.zoom_in),
            tooltip: 'Zoom in',
            onPressed: () => _controller.zoomUp(),
          ),
          const Spacer(),
          if (isTextbook)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text("AI assist"),
              onPressed: _openSummary,
            ),
        ],
      ),
    );
  }
}
