import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/bookmark.dart';
import '../services/classifier.dart';
import '../services/settings_service.dart';
import '../services/stats_service.dart';
import '../services/text_document.dart';
import '../services/tts_service.dart';
import 'bookmarks_sheet.dart';
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

class _TextReaderScreenState extends State<TextReaderScreen> {
  late final TtsService _tts;
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
      setState(() => _activeSentence = active);
      if (active != null && _autoScroll) _scrollTo(active);
    };
    _tts.onPageFinished = _autoAdvance;
    _load();
  }

  void _onTts() => setState(() {});

  Future<void> _load() async {
    try {
      final doc = await TextDocument.open(widget.book);
      if (!mounted) return;
      final resume = widget.settings.lastPage(widget.book.id) ?? 1;
      setState(() {
        _doc = doc;
        _loading = false;
        _page = resume.clamp(1, doc.pageCount);
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
    final key = _anchors[index];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.35,
      duration: const Duration(milliseconds: 420),
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
    await _tts.stop();
    _sentenceOffset = index;
    setState(() => _activeSentence = index);
    await _tts.speakSegments(
      _sentences.sublist(index).map((s) => s.text).toList(),
    );
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
    await _speakFrom(0);
  }

  void _autoAdvance() {
    final doc = _doc;
    if (doc == null || _page >= doc.pageCount) return;
    _goToPage(_page + 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => _speakFrom(0));
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
    _tts.removeListener(_onTts);
    _tts.dispose();
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
      appBar: AppBar(
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
        actions: [
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
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: 'All bookmarks',
            onPressed: _openBookmarks,
          ),
          IconButton(
            icon: Icon(_autoScroll
                ? Icons.vertical_align_center
                : Icons.swipe_vertical_outlined),
            tooltip: _autoScroll
                ? 'Auto-scroll follows the voice'
                : 'Auto-scroll off',
            isSelected: _autoScroll,
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
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
                PopupMenuItem(value: size, child: Text('${size.round()} pt')),
            ],
          ),
        ],
      ),
      body: _body(theme),
      bottomNavigationBar: doc == null ? null : _bottomBar(theme),
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
              onChanged: (v) => _tts.setRate(v),
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
