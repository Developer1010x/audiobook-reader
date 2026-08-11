import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/library_node.dart';
import '../services/library_service.dart';
import '../services/settings_service.dart';
import '../services/recommender.dart';
import '../services/stats_service.dart';
import '../services/theme_controller.dart';
import '../services/text_document.dart';
import 'reader_screen.dart';
import 'settings_screen.dart';
import 'text_reader_screen.dart';
import 'widgets/book_tile.dart';
import 'widgets/reading_stats.dart';

enum LibrarySort {
  title('Title'),
  recent('Recently opened'),
  size('Size');

  const LibrarySort(this.label);
  final String label;
}

class LibraryScreen extends StatefulWidget {
  final SettingsService settings;
  final StatsService stats;
  final ThemeController theme;
  const LibraryScreen({
    super.key,
    required this.settings,
    required this.stats,
    required this.theme,
  });

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Book> _all = [];
  LibraryFolder? _root;
  final List<LibraryFolder> _stack = [];

  String _query = '';
  bool _loading = false;
  String? _error;
  bool _gridView = true;
  bool _favouritesOnly = false;
  LibrarySort _sort = LibrarySort.title;

  /// Suggestions from the local heuristic model. Recomputed after a scan and
  /// after returning from a book, since progress and notes will have moved.
  List<Recommendation> _suggestions = const [];

  LibraryFolder? get _current => _stack.isEmpty ? _root : _stack.last;
  bool get _searching => _query.trim().isNotEmpty;
  bool get _atRoot => _stack.isEmpty;

  @override
  void initState() {
    super.initState();
    final path = widget.settings.libraryPath;
    if (path != null) _scan(path);
  }

  Future<void> _scan(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final books = await LibraryService.scan(path);
      if (!mounted) return;
      setState(() {
        _all = books;
        _root = LibraryFolder.build(books, path);
        _stack.clear();
        _loading = false;
      });
      unawaited(_recompute());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose your book library folder',
    );
    if (path == null) return;
    await widget.settings.setLibraryPath(path);
    await _scan(path);
  }

  void _open(Book book) {
    widget.settings.markOpened(book.id);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TextDocument.handles(book.ext)
            ? TextReaderScreen(
                book: book, settings: widget.settings, stats: widget.stats)
            : ReaderScreen(
                book: book, settings: widget.settings, stats: widget.stats),
      ),
      // Progress and bookmarks may have changed while reading.
    ).then((_) => mounted ? setState(() {}) : null);
  }

  /// Re-run the recommender. Never blocks the UI: the model runs off-thread on
  /// a real library, and a failure here should cost a shelf, not the screen.
  Future<void> _recompute() async {
    if (_all.isEmpty) return;
    try {
      final input = buildRecommenderInput(
        books: _all,
        recentIds: widget.settings.recentBooks,
        favouriteIds: widget.settings.favourites,
        progressOf: (id) {
          final page = widget.settings.lastPage(id);
          final total = widget.settings.pageCount(id);
          if (page == null || total == null || total <= 0) return 0;
          return (page / total).clamp(0.0, 1.0);
        },
        typeOf: (id) =>
            (widget.settings.typeOverride(id) ??
                    widget.settings.cachedClassification(id))
                ?.name,
        annotationsOf: widget.settings.annotationCount,
      );
      final out = await Recommender.suggest(input);
      if (mounted) setState(() => _suggestions = out);
    } catch (_) {
      // A missing shelf is better than a broken library screen.
    }
  }

  Future<void> _toggleFavourite(Book book) async {
    await widget.settings.toggleFavourite(book.id);
    setState(() {});
  }

  /// Books actually started, most recently opened first — the fastest route
  /// back to what you were reading.
  List<Book> get _continueReading {
    final byId = {for (final b in _all) b.id: b};
    return widget.settings.recentBooks
        .map((id) => byId[id])
        .whereType<Book>()
        .where((b) => (widget.settings.lastPage(b.id) ?? 1) > 1)
        .toList();
  }

  List<Book> _sorted(List<Book> books) {
    final list = books.toList();
    switch (_sort) {
      case LibrarySort.title:
        list.sort(
            (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      case LibrarySort.size:
        list.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
      case LibrarySort.recent:
        final order = widget.settings.recentBooks;
        int rank(Book b) {
          final i = order.indexOf(b.id);
          return i < 0 ? order.length : i; // never-opened sink to the bottom
        }

        list.sort((a, b) => rank(a).compareTo(rank(b)));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _stack.removeLast());
      },
      child: Scaffold(
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(slivers: [_appBar(), ..._content()]),
      ),
    );
  }

  Widget _appBar() {
    final theme = Theme.of(context);
    return SliverAppBar(
      floating: true,
      snap: true,
      titleSpacing: _atRoot ? 20 : 4,
      leading: _atRoot
          ? null
          : IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _stack.removeLast()),
            ),
      title: Text(_atRoot ? 'Library' : _stack.last.name),
      actions: [
        if (_all.isNotEmpty) ...[
          IconButton(
            icon: Icon(_favouritesOnly ? Icons.star : Icons.star_border),
            tooltip: _favouritesOnly ? 'Showing favourites' : 'Favourites only',
            isSelected: _favouritesOnly,
            onPressed: () => setState(() => _favouritesOnly = !_favouritesOnly),
          ),
          IconButton(
            icon: Icon(_gridView ? Icons.view_list : Icons.grid_view),
            tooltip: _gridView ? 'List view' : 'Grid view',
            onPressed: () => setState(() => _gridView = !_gridView),
          ),
          PopupMenuButton<LibrarySort>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort by ${_sort.label}',
            initialValue: _sort,
            onSelected: (v) => setState(() => _sort = v),
            itemBuilder: (context) => [
              for (final s in LibrarySort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
        ],
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            switch (value) {
              case 'rescan':
                final path = widget.settings.libraryPath;
                if (path != null) _scan(path);
              case 'folder':
                _pickFolder();
              case 'settings':
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsScreen(
                      settings: widget.settings,
                      theme: widget.theme,
                    ),
                  ),
                ).then((_) => mounted ? setState(() {}) : null);
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'rescan', child: Text('Rescan library')),
            PopupMenuItem(value: 'folder', child: Text('Change folder')),
            PopupMenuItem(value: 'settings', child: Text('Settings')),
          ],
        ),
      ],
      bottom: _all.isEmpty
          ? null
          : PreferredSize(
              preferredSize: Size.fromHeight(_atRoot ? 60 : 90),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: SearchBar(
                      hintText: 'Search all ${_all.length} books',
                      leading: const Icon(Icons.search),
                      elevation: const WidgetStatePropertyAll(0),
                      trailing: [
                        if (_searching)
                          IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() => _query = ''),
                          ),
                      ],
                      onChanged: (v) => setState(() => _query = v),
                    ),
                  ),
                  if (!_atRoot) _breadcrumbs(theme),
                ],
              ),
            ),
    );
  }

  Widget _breadcrumbs(ThemeData theme) => SizedBox(
        height: 30,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            _crumb('Library', () => setState(() => _stack.clear())),
            for (var i = 0; i < _stack.length; i++) ...[
              Icon(Icons.chevron_right,
                  size: 16, color: theme.colorScheme.outline),
              _crumb(
                _stack[i].name,
                i == _stack.length - 1
                    ? null
                    : () => setState(
                        () => _stack.removeRange(i + 1, _stack.length)),
              ),
            ],
          ],
        ),
      );

  Widget _crumb(String label, VoidCallback? onTap) {
    final theme = Theme.of(context);
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: onTap == null
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.primary,
              fontWeight: onTap == null ? FontWeight.w600 : null,
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content() {
    if (_error != null) {
      return [
        _emptySliver(Icons.error_outline, 'Could not read that folder', _error!,
            'Choose another folder', _pickFolder),
      ];
    }
    if (widget.settings.libraryPath == null) {
      return [
        _emptySliver(
          Icons.local_library_outlined,
          'Point the app at your books',
          'Your library stays where it is — the app only reads it, and never '
              'copies or uploads a book.',
          'Choose library folder',
          _pickFolder,
        ),
      ];
    }

    // Search spans the whole library, not the current folder: when hunting a
    // title you rarely remember which folder it is filed under.
    if (_searching) {
      final results = _filtered(LibraryService.search(_all, _query));
      if (results.isEmpty) {
        return [
          _emptySliver(Icons.search_off, 'No match for "$_query"',
              'Search covers all ${_all.length} books.', null, null),
        ];
      }
      return [
        _sectionHeader(
            '${results.length} result${results.length == 1 ? '' : 's'}'),
        _booksSliver(results, showPath: true),
      ];
    }

    final current = _current;
    if (current == null) return [const SliverToBoxAdapter()];

    final books = _filtered(current.books);
    final folders = _favouritesOnly ? <LibraryFolder>[] : current.folders;

    if (folders.isEmpty && books.isEmpty) {
      return [
        _emptySliver(
          _favouritesOnly ? Icons.star_border : Icons.folder_off_outlined,
          _favouritesOnly ? 'No favourites here' : 'Nothing readable here',
          _favouritesOnly
              ? 'Star a book to keep it close at hand.'
              : 'No PDF, EPUB, txt or md files in this folder.',
          null,
          null,
        ),
      ];
    }

    final shelf = _atRoot && !_favouritesOnly ? _continueReading : const <Book>[];

    return [
      if (_atRoot && !_favouritesOnly)
        SliverToBoxAdapter(child: ReadingStats(stats: widget.stats)),
      if (shelf.isNotEmpty) ...[
        _sectionHeader('Continue reading'),
        _shelfSliver(shelf),
      ],
      if (_atRoot && !_favouritesOnly && _suggestions.isNotEmpty) ...[
        _sectionHeader('Suggested for you'),
        _suggestionSliver(),
      ],
      if (folders.isNotEmpty) ...[
        if (shelf.isNotEmpty) _sectionHeader('Folders'),
        _foldersSliver(folders),
      ],
      if (books.isNotEmpty) ...[
        if (folders.isNotEmpty || shelf.isNotEmpty) _sectionHeader('Books'),
        _booksSliver(books),
      ],
      const SliverToBoxAdapter(child: SizedBox(height: 32)),
    ];
  }

  List<Book> _filtered(List<Book> books) {
    final list = _favouritesOnly
        ? books.where((b) => widget.settings.isFavourite(b.id)).toList()
        : books;
    return _sorted(list);
  }

  Widget _sectionHeader(String title) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Text(
            title,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );

  Widget _shelfSliver(List<Book> books) => SliverToBoxAdapter(
        child: SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20),
            itemCount: books.length,
            separatorBuilder: (_, index) => const SizedBox(width: 14),
            itemBuilder: (context, i) => SizedBox(
              width: 98,
              child: BookPoster(
                book: books[i],
                settings: widget.settings,
                onTap: () => _open(books[i]),
                onToggleFavourite: () => _toggleFavourite(books[i]),
                subtitleOverride: _progressLabel(books[i]),
              ),
            ),
          ),
        ),
      );

  /// Suggestions from the local model, each captioned with why it is here.
  ///
  /// The caption is not decoration: an unexplained recommendation is one the
  /// user cannot judge, so they stop trusting the whole shelf.
  Widget _suggestionSliver() {
    final byId = {for (final b in _all) b.id: b};
    final picks = _suggestions
        .map((r) => (book: byId[r.bookId], reason: r.reason))
        .where((e) => e.book != null)
        .toList();
    if (picks.isEmpty) return const SliverToBoxAdapter();

    return SliverToBoxAdapter(
      child: SizedBox(
        height: 208,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          itemCount: picks.length,
          separatorBuilder: (_, index) => const SizedBox(width: 14),
          itemBuilder: (context, i) => SizedBox(
            width: 98,
            child: BookPoster(
              book: picks[i].book!,
              settings: widget.settings,
              onTap: () => _open(picks[i].book!),
              onToggleFavourite: () => _toggleFavourite(picks[i].book!),
              subtitleOverride: picks[i].reason.label,
            ),
          ),
        ),
      ),
    );
  }

  String? _progressLabel(Book book) {
    final page = widget.settings.lastPage(book.id);
    final total = widget.settings.pageCount(book.id);
    if (page == null) return null;
    if (total == null || total == 0) return 'p.$page';
    return '${((page / total) * 100).round()}% · p.$page';
  }

  Widget _foldersSliver(List<LibraryFolder> folders) => SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverGrid(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 260,
            mainAxisExtent: 66,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) => _FolderCard(
              folder: folders[i],
              onTap: () => setState(() => _stack.add(folders[i])),
            ),
            childCount: folders.length,
          ),
        ),
      );

  Widget _booksSliver(List<Book> books, {bool showPath = false}) {
    if (!_gridView) {
      return SliverList.separated(
        itemCount: books.length,
        separatorBuilder: (_, index) => const Divider(height: 1, indent: 78),
        itemBuilder: (context, i) => _BookRow(
          book: books[i],
          settings: widget.settings,
          onTap: () => _open(books[i]),
          onToggleFavourite: () => _toggleFavourite(books[i]),
          subtitle: showPath ? _relativeFolder(books[i]) : null,
        ),
      );
    }

    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 132,
          // Cover (~4:3 tall) plus two label lines.
          mainAxisExtent: 216,
          crossAxisSpacing: 14,
          mainAxisSpacing: 18,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) => BookPoster(
            book: books[i],
            settings: widget.settings,
            onTap: () => _open(books[i]),
            onToggleFavourite: () => _toggleFavourite(books[i]),
            subtitleOverride: showPath ? _relativeFolder(books[i]) : null,
          ),
          childCount: books.length,
        ),
      ),
    );
  }

  String? _relativeFolder(Book book) {
    final root = widget.settings.libraryPath;
    if (root == null) return null;
    final dir = book.path.substring(0, book.path.lastIndexOf('/'));
    if (dir == root) return 'Library';
    return dir.replaceFirst('$root/', '');
  }

  Widget _emptySliver(IconData icon, String title, String message,
          String? actionLabel, VoidCallback? onAction) =>
      SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      size: 44, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(title,
                      style: Theme.of(context).textTheme.titleMedium,
                      textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(color: Theme.of(context).colorScheme.outline),
                  ),
                  if (actionLabel != null) ...[
                    const SizedBox(height: 20),
                    FilledButton(onPressed: onAction, child: Text(actionLabel)),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}

class _FolderCard extends StatelessWidget {
  final LibraryFolder folder;
  final VoidCallback onTap;
  const _FolderCard({required this.folder, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Icon(Icons.folder_rounded, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    Text(
                        '${folder.totalBooks} book${folder.totalBooks == 1 ? '' : 's'}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: theme.colorScheme.outline)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookRow extends StatelessWidget {
  final Book book;
  final SettingsService settings;
  final VoidCallback onTap;
  final VoidCallback onToggleFavourite;
  final String? subtitle;

  const _BookRow({
    required this.book,
    required this.settings,
    required this.onTap,
    required this.onToggleFavourite,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type =
        settings.typeOverride(book.id) ?? settings.cachedClassification(book.id);
    final favourite = settings.isFavourite(book.id);

    return ListTile(
      onTap: onTap,
      leading:
          BookCover(book: book, type: type, width: 40, height: 54, radius: 5),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle ??
            [
              if (type != null) type.label,
              book.ext.toUpperCase(),
              book.sizeLabel,
            ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall,
      ),
      trailing: IconButton(
        icon: Icon(favourite ? Icons.star : Icons.star_border,
            color: favourite ? Colors.amber : null),
        onPressed: onToggleFavourite,
      ),
    );
  }
}
