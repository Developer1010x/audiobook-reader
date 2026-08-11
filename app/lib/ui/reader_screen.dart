import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import '../models/annotation.dart';
import '../models/bookmark.dart';
import '../services/classifier.dart';
import '../services/ocr_service.dart';
import '../services/reader_service.dart';
import '../services/piper_tts.dart';
import '../services/spoken_text.dart';
import '../services/settings_service.dart';
import '../services/stats_service.dart';
import '../services/tts_service.dart';
import 'bookmarks_sheet.dart';
import 'notes_sheet.dart';
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

class _ReaderScreenState extends State<ReaderScreen> {
  final _controller = PdfViewerController();
  final _searchField = TextEditingController();
  final _searchFocus = FocusNode();
  late final TtsService _tts;
  PdfTextSearcher? _searcher;

  int _page = 1;
  int _pageCount = 0;
  BookType? _type;
  Classification? _classification;
  bool _ttsAvailable = true;
  bool _searching = false;
  String? _busy;
  bool _showOutline = false;
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

  /// Index of the segment speech started from, so segment 0 of the TTS run maps
  /// back to the right sentence on the page.
  int _segmentOffset = 0;

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
      setState(() => _activeSegment = active);
      if (active != null && _autoScroll) _scrollToSegment(active);
    };
    _tts.voice = widget.settings.voice;
    _resolveType();
    _checkTts();
  }

  Future<void> _checkTts() async {
    final available = await TtsService.isAvailable();
    if (mounted) setState(() => _ttsAvailable = available);
  }

  void _onTts() => setState(() {});

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
    if (_speech != null && _speechPage == page) return _speech;
    try {
      final speech = await ReaderService.pageSpeech(widget.book, page);
      if (!mounted) return null;
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
    await _tts.stop();
    _segmentOffset = from;
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
    try {
      // The controller is the source of truth: _page stays 1 until onPageChanged
      // fires, so pressing Play right after opening would otherwise read page 1.
      final page = _controller.pageNumber ?? _page;
      if (page != _page) setState(() => _page = page);

      // Prefer the sentence-mapped path so the highlight follows along.
      final speech = await _loadSpeech(page);
      if (speech != null && !speech.isEmpty) {
        await _speakFrom(speech, 0, page);
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
        duration: const Duration(milliseconds: 420),
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
    if (!mounted || _page >= _pageCount) return;
    _controller.goToPage(pageNumber: _page + 1);
    final text = await ReaderService.pageText(widget.book, _page + 1);
    if (mounted && text.trim().isNotEmpty) await _tts.speak(text);
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
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SummarySheet(
        book: widget.book,
        settings: widget.settings,
        initialPage: _page,
        pageCount: _pageCount,
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
    _tts.removeListener(_onTts);
    _tts.dispose();
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
      appBar: _searching ? _searchBar(theme) : _titleBar(theme, isTextbook),
      body: Column(
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
                Expanded(child: _viewer(theme)),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _bottomBar(theme, isTextbook),
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
              onChanged: (v) => _tts.setRate(v),
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
