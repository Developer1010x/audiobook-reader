import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/annotation.dart';
import '../models/bookmark.dart';
import '../services/chapter_index.dart';
import '../services/classifier.dart';
import '../services/settings_service.dart';
import '../services/sleep_timer.dart';
import '../services/stats_service.dart';
import '../services/text_document.dart';
import '../services/media_player_service.dart';
import '../services/tts_service.dart';
import 'bookmarks_sheet.dart';
import 'music_sheet.dart';
import 'notes_sheet.dart';
import 'reader_playback.dart';
import 'summary_sheet.dart';

/// Reader for `.txt`, `.md` and `.epub`.
///
/// These have no fixed page geometry, so unlike the PDF reader there is nothing
/// to render — the text is laid out by Flutter. That makes follow-along
/// highlighting *easier* than in the PDF: each sentence is a TextSpan, so the
/// spoken one can simply be styled, and tapping one starts reading there.
class TextReaderScreen extends StatefulWidget {
  final Book book;
  final SettingsService settings;
  final StatsService stats;
  const TextReaderScreen({
    super.key,
    required this.book,
    required this.settings,
    required this.stats,
  });

  @override
  State<TextReaderScreen> createState() => _TextReaderScreenState();
}

class _TextReaderScreenState extends State<TextReaderScreen>
    with ReaderPlayback<TextReaderScreen> {
  late final TtsService _tts;
  final _music = MediaPlayerService();
  final _scroll = ScrollController();

  TextDocument? _doc;
  String? _error;
  bool _loading = true;

  int _page = 1;
  BookType? _type;
  int? _activeSentence;
  int _sentenceOffset = 0;
  double _fontSize = 17;
  late bool _night = widget.settings.nightMode;

  /// First pages of the book's sections, for the "end of chapter" sleep ending.
  ChapterIndex _chapters = ChapterIndex.empty;

  List<_Sentence> _sentences = const [];

  /// One key per sentence, so the spoken one can be scrolled into view.
  final Map<int, GlobalKey> _anchors = {};

  /// Auto-scroll can be turned off — it fights the user if they are reading
  /// ahead of the voice.
  bool _autoScroll = true;

  @override
  void initState() {
    super.initState();
    _tts = TtsService()..addListener(_onTts);
    _tts.voice = widget.settings.voice;
    _tts.onSegment = (index) {
      if (!mounted) return;
      final active = index == null ? null : _sentenceOffset + index;
      // Before the setState, and only when non-null: stop() clears the
      // highlight by reporting null, and that must not clear the resume point.
      if (active != null) noteSpoken(active);
      setState(() => _activeSentence = active);
      if (active != null && _autoScroll) _scrollTo(active);
    };
    _tts.onPageFinished = _autoAdvance;
    initPlayback();
    _load();
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
  int get pageCount => _doc?.pageCount ?? 0;

  @override
  int get sentenceCount => _sentences.length;

  @override
  String? get currentSentence {
    final index = _activeSentence;
    // Null rather than a guess: _splitSentences rebuilds this list on every page
    // turn, and an index into the old one would be a RangeError.
    if (index == null || index < 0 || index >= _sentences.length) return null;
    return _sentences[index].text;
  }

  @override
  bool get isBookmarkedHere =>
      widget.settings.isBookmarked(widget.book.id, _page);

  @override
  String? get busyMessage => _loading ? 'Opening ${widget.book.title}…' : null;

  @override
  Future<void> togglePlay() => _togglePlay();

  @override
  Future<bool> bookmarkHere() async {
    final current = _currentPage;
    if (current == null) return false;
    // Adds only, never removes: a mis-aimed second press in a car must not
    // throw away the bookmark the first one made.
    if (widget.settings.isBookmarked(widget.book.id, _page)) return false;
    await widget.settings.addBookmark(
      widget.book.id,
      Bookmark(
        page: _page,
        preview: current.text.replaceAll('\n', ' ').trim(),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (mounted) setState(() {});
    return true;
  }

  @override
  Future<void> speakAt(int pageNumber, int sentence,
      {required bool resume}) async {
    final doc = _doc;
    if (doc == null) return;
    final target = pageNumber.clamp(1, doc.pageCount);
    // _goToPage re-splits synchronously, so the new page's sentences are in
    // place by the time the index below is clamped against them.
    if (target != _page) _goToPage(target);
    if (_sentences.isEmpty) return;
    // A negative index counts back from the end of the page.
    final index = (sentence < 0 ? _sentences.length + sentence : sentence)
        .clamp(0, _sentences.length - 1);
    if (!resume) {
      // Skipping while paused moves the cursor and stays paused.
      _sentenceOffset = index;
      noteSpeechStart(target, index);
      setState(() => _activeSentence = index);
      return;
    }
    await _speakFrom(index);
  }

  Future<void> _load() async {
    try {
      final doc = await TextDocument.open(widget.book);
      if (!mounted) return;
      final resume = widget.settings.lastPage(widget.book.id) ?? 1;
      setState(() {
        _doc = doc;
        _loading = false;
        _page = resume.clamp(1, doc.pageCount);
        _chapters = ChapterIndex.fromTextChapters(doc.chapters, doc.pageCount);
      });
      widget.settings.setPageCount(widget.book.id, doc.pageCount);
      widget.settings.markOpened(widget.book.id);
      _resolveType();
      _splitSentences();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Classify from the middle of the book, matching the PDF path — front matter
  /// looks the same in every book.
  void _resolveType() {
    final doc = _doc;
    if (doc == null) return;
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
    final middle = doc.pages
        .skip((doc.pageCount * 0.2).floor())
        .take(5)
        .map((p) => p.text)
        .join('\n');
    final result = BookClassifier.classify(middle);
    widget.settings.cacheClassification(widget.book.id, result.type);
    setState(() => _type = result.type);
  }

  void _splitSentences() {
    final text = _currentPage?.text ?? '';
    final matches = RegExp(r'[^.!?]*[.!?]+[\s"”)\]]*|[^.!?]+$').allMatches(text);
    final sentences = <_Sentence>[];
    for (final match in matches) {
      final raw = match.group(0) ?? '';
      if (raw.trim().isEmpty) continue;
      final index = sentences.length;
      sentences.add(_Sentence(
        start: match.start,
        end: match.end,
        text: raw,
        recognizer: TapGestureRecognizer()..onTap = () => _speakFrom(index),
      ));
    }
    for (final old in _sentences) {
      old.recognizer.dispose();
    }
    _anchors
      ..clear()
      ..addEntries([
        for (var i = 0; i < sentences.length; i++) MapEntry(i, GlobalKey()),
      ]);
    setState(() {
      _sentences = sentences;
      _activeSentence = null;
    });
  }

  /// Bring the spoken sentence into view, keeping it about a third down the
  /// viewport rather than jammed against the top edge — that is where the eye
  /// naturally sits when following along.
  void _scrollTo(int index) {
    // Car Mode covers the text, so this would be a 420 ms animation per
    // sentence with nothing on screen to show for it.
    if (inCarMode) return;
    final key = _anchors[index];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      // One 420 ms slide per sentence is the most repetitive motion in the app;
      // a reader who has asked the system to stop animating gets the same
      // position without the travel.
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  TextPage? get _currentPage {
    final doc = _doc;
    if (doc == null || doc.pages.isEmpty) return null;
    return doc.pages[(_page - 1).clamp(0, doc.pageCount - 1)];
  }

  void _goToPage(int page) {
    final doc = _doc;
    if (doc == null) return;
    final target = page.clamp(1, doc.pageCount);
    setState(() => _page = target);
    widget.settings.setLastPage(widget.book.id, target);
    widget.stats.recordPage();
    _splitSentences();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _speakFrom(int index) async {
    if (_sentences.isEmpty) return;
    // Every path into speech funnels through here, so this is the one place the
    // expiry latch is cleared. Scattering that across the entry points would
    // leave the next one added needing to remember.
    sleep.clearExpiry();
    await _tts.stop();
    _sentenceOffset = index;
    noteSpeechStart(_page, index);
    setState(() => _activeSentence = index);
    await _tts.speakSegments(
      _sentences.sublist(index).map((s) => s.text).toList(),
    );
  }

  /// Start reading at the sentence containing [offset] in the page text.
  Future<void> _speakFromOffset(int offset) async {
    for (var i = 0; i < _sentences.length; i++) {
      if (offset < _sentences[i].end) {
        await _speakFrom(i);
        return;
      }
    }
  }

  Future<void> _togglePlay() async {
    if (_tts.isSpeaking) {
      await _tts.stop();
      return;
    }
    if (!await TtsService.isAvailable()) {
      _snack(TtsService.unavailableMessage);
      return;
    }
    if (_sentences.isEmpty) return;
    // From the cursor, not the top: pause is stop on Linux, so restarting at
    // sentence 0 would re-read the whole page after every pause.
    await _speakFrom(resumeSentence.clamp(0, _sentences.length - 1));
  }

  void _autoAdvance() {
    final doc = _doc;
    // The latch covers the window between this firing and speech restarting:
    // the page turn below waits a whole frame, and a timer expiring in there
    // would stop an engine that is already idle while the queued advance speaks
    // anyway — all night.
    if (!mounted || doc == null || sleep.hasExpired) return;
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
    if (_page >= doc.pageCount) return;
    _goToPage(_page + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || sleep.hasExpired) return;
      unawaited(_speakFrom(0));
    });
  }

  Future<void> _toggleBookmark() async {
    final page = _currentPage;
    if (page == null) return;
    final id = widget.book.id;
    if (widget.settings.isBookmarked(id, _page)) {
      await widget.settings.removeBookmark(id, _page);
    } else {
      await widget.settings.addBookmark(
        id,
        Bookmark(
          page: _page,
          preview: page.text.replaceAll('\n', ' ').trim(),
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    setState(() {});
  }

  /// Turn the current selection into a highlight, optionally with a note.
  Future<void> _annotate(String quote) async {
    if (quote.trim().isEmpty) return;
    final edit = await showAnnotationEditor(context: context, quote: quote);
    if (edit == null) return;
    await widget.settings.addAnnotation(
      widget.book.id,
      Annotation(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        page: _page,
        quote: quote.trim(),
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
        onGoToPage: _goToPage,
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
        onGoToPage: _goToPage,
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    // Before the engine goes: the sleep timer and the keep-awake inhibitor do
    // not ride on the TTS session, so nothing else would ever cancel them.
    disposePlayback();
    _tts.removeListener(_onTts);
    _tts.dispose();
    _music.dispose();
    _scroll.dispose();
    for (final sentence in _sentences) {
      sentence.recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final doc = _doc;
    final bookmarked =
        doc != null && widget.settings.isBookmarked(widget.book.id, _page);

    return Scaffold(
      backgroundColor: _night ? const Color(0xFF101014) : null,
      // Car Mode is the whole screen or it is not a driving surface. It brings
      // its own PopScope and Escape binding, so back exits the overlay rather
      // than dumping a driver back into the library.
      appBar: inCarMode ? null : _titleBar(theme, doc, bookmarked),
      body: Stack(
        // The body slot grows by both bars on the way into Car Mode, so the
        // text below relayouts once each way. That is the price of the overlay
        // being the whole screen: leaving either bar up would put a strip of
        // ordinary reader chrome along the edge of a driving surface.
        fit: StackFit.expand,
        children: [
          // Behind the overlay the reader is scenery. Painting over it is not
          // enough: a screen reader would still walk the whole page of book
          // text before reaching the six controls, and a tap landing in a
          // safe-area inset — where Car Mode's own hit-test layer stops — would
          // fall through to a sentence recogniser and restart the book there.
          ExcludeSemantics(
            excluding: inCarMode,
            child: IgnorePointer(ignoring: inCarMode, child: _body(theme)),
          ),
          // A sibling of the reader's body, never a child of it.
          if (inCarMode) Positioned.fill(child: carOverlay()),
        ],
      ),
      bottomNavigationBar: doc == null || inCarMode ? null : _bottomBar(theme),
    );
  }

  PreferredSizeWidget _titleBar(
      ThemeData theme, TextDocument? doc, bool bookmarked) {
    return AppBar(
      backgroundColor: _night ? const Color(0xFF101014) : null,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium),
          if (doc != null)
            Text('Page $_page of ${doc.pageCount} · ${widget.book.ext.toUpperCase()}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
      // Only the controls reached for mid-sentence stay as icons. The rest moved
      // into a menu when Car Mode and the sleep timer arrived: nine actions
      // overflow the bar on a phone, and an overflowing bar quietly hides
      // whichever one was added last.
      actions: [
        sleepChip(),
        if (doc != null && doc.chapters.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.toc),
            tooltip: 'Contents',
            onPressed: _openChapters,
          ),
        IconButton(
          icon: Icon(bookmarked ? Icons.bookmark : Icons.bookmark_border),
          tooltip: bookmarked ? 'Remove bookmark' : 'Bookmark this page',
          onPressed: _toggleBookmark,
        ),
        IconButton(
          icon: Icon(_night ? Icons.light_mode : Icons.dark_mode),
          tooltip: _night ? 'Normal colours' : 'Night mode',
          onPressed: () {
            setState(() => _night = !_night);
            widget.settings.setNightMode(_night);
          },
        ),
        PopupMenuButton<double>(
          icon: const Icon(Icons.format_size),
          tooltip: 'Text size',
          onSelected: (v) => setState(() => _fontSize = v),
          itemBuilder: (context) => [
            for (final size in [14.0, 17.0, 20.0, 24.0, 28.0])
              CheckedPopupMenuItem(
                value: size,
                checked: size == _fontSize,
                child: Text('${size.round()} pt'),
              ),
          ],
        ),
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
              case 'notes':
                _openNotes();
              case 'bookmarks':
                _openBookmarks();
              case 'autoscroll':
                setState(() => _autoScroll = !_autoScroll);
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
            PopupMenuItem(
              value: 'notes',
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.edit_note),
                title: const Text('Highlights and notes'),
                trailing: Text(
                    '${widget.settings.annotationCount(widget.book.id)}'),
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
            CheckedPopupMenuItem(
              value: 'autoscroll',
              checked: _autoScroll,
              child: const Text('Follow the voice'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: theme.colorScheme.outline),
              const SizedBox(height: 12),
              Text('Could not open this file',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      );
    }

    final page = _currentPage;
    if (page == null) return const Center(child: Text('Empty document.'));

    final base = TextStyle(
      fontSize: _fontSize,
      height: 1.65,
      color: _night ? const Color(0xFFD8D8DC) : theme.colorScheme.onSurface,
    );
    final highlight = base.copyWith(
      backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.28),
    );

    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Center(
          child: ConstrainedBox(
            // A comfortable measure — long lines are hard to track by eye.
            constraints: const BoxConstraints(maxWidth: 720),
            child: SelectableText.rich(
              contextMenuBuilder: (context, editable) {
                final value = editable.textEditingValue;
                final selected = value.selection.textInside(value.text);
                return AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: editable.contextMenuAnchors,
                  buttonItems: [
                    ...editable.contextMenuButtonItems,
                    ContextMenuButtonItem(
                      label: 'Highlight',
                      onPressed: () {
                        ContextMenuController.removeAny();
                        _annotate(selected);
                      },
                    ),
                    ContextMenuButtonItem(
                      label: 'Read from here',
                      onPressed: () {
                        ContextMenuController.removeAny();
                        _speakFromOffset(value.selection.start);
                      },
                    ),
                  ],
                );
              },
              TextSpan(
                children: [
                  for (var i = 0; i < _sentences.length; i++)
                    TextSpan(
                      text: _sentences[i].text,
                      style: i == _activeSentence ? highlight : base,
                      // Tap a sentence to start reading from exactly there.
                      recognizer: _sentences[i].recognizer,
                    ),
                ],
              ),
              style: base,
            ),
          ),
        ),
      ),
    );
  }

  void _openChapters() {
    final doc = _doc;
    if (doc == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (context, controller) => ListView(
          controller: controller,
          children: [
            for (final chapter in doc.chapters)
              ListTile(
                dense: true,
                title: Text(chapter.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Text('p.${chapter.firstPage}'),
                onTap: () {
                  Navigator.pop(context);
                  _goToPage(chapter.firstPage);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    final doc = _doc!;
    return BottomAppBar(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton.filledTonal(
            icon: _tts.isPreparing
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(_tts.isSpeaking ? Icons.stop : Icons.play_arrow),
            tooltip: 'Read aloud · ${TtsService.engineName}',
            onPressed: _togglePlay,
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
            onPressed: _page <= 1 ? null : () => _goToPage(_page - 1),
          ),
          Text('$_page / ${doc.pageCount}'),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _page >= doc.pageCount ? null : () => _goToPage(_page + 1),
          ),
          const Spacer(),
          if (_type == BookType.textbook)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('AI assist'),
              onPressed: () => showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                showDragHandle: true,
                builder: (_) => SummarySheet(
                  book: widget.book,
                  settings: widget.settings,
                  initialPage: _page,
                  pageCount: doc.pageCount,
                  textProvider: (start, end) => Future.value(
                    doc.pages
                        .where((p) => p.number >= start && p.number <= end)
                        .map((p) => p.text)
                        .join('\n\n'),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Sentence {
  final int start;
  final int end;
  final String text;

  /// Owned by the screen and disposed with it — a recognizer leaked per rebuild
  /// would accumulate for every page turn.
  final TapGestureRecognizer recognizer;

  _Sentence({
    required this.start,
    required this.end,
    required this.text,
    required this.recognizer,
  });
}
