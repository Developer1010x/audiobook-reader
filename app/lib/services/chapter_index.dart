import 'package:pdfrx/pdfrx.dart';

import 'text_document.dart';

/// Where each chapter starts, in page numbers.
///
/// Built once when a book opens so "stop at the end of the chapter" and
/// chapter-skip controls can answer instantly, without re-walking a PDF outline
/// on every page turn.
///
/// Both sources are lossy in the same way: a PDF outline and an EPUB spine give
/// *starts*, never extents. A chapter therefore runs until the next one begins,
/// which is right for every book that does not interleave sections.
class ChapterIndex {
  const ChapterIndex(this.starts, this.titles, this.pageCount);

  /// Page numbers where chapters begin, ascending, 1-based.
  final List<int> starts;

  /// Title per entry in [starts]; same length.
  final List<String> titles;

  final int pageCount;

  static const ChapterIndex empty = ChapterIndex([], [], 0);

  bool get hasChapters => starts.length > 1;

  int get length => starts.length;

  /// Index of the chapter containing [page], or -1 when there are none.
  ///
  /// Binary search rather than a scan: this is called on every page turn while
  /// audio is playing, and a linear walk over a 60-chapter reference book is
  /// wasted work in the read-aloud path.
  int indexOf(int page) {
    if (starts.isEmpty) return -1;
    var low = 0;
    var high = starts.length - 1;
    var found = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (starts[mid] <= page) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return found;
  }

  String? titleFor(int page) {
    final index = indexOf(page);
    return index < 0 ? null : titles[index];
  }

  /// Whether two pages sit in the same chapter.
  ///
  /// This is what "stop at the end of the chapter" hangs on: the sleep timer
  /// asks whether the *next* page is still the same section, and stops when it
  /// is not. With no chapter data it answers true, so a book without an outline
  /// simply never triggers an end-of-chapter stop rather than stopping after
  /// every page.
  bool sameSection(int a, int b) {
    if (!hasChapters) return true;
    if (b > pageCount) return false;
    return indexOf(a) == indexOf(b);
  }

  /// First page of the chapter after the one containing [page], or null when
  /// this is the last chapter.
  int? nextChapterStart(int page) {
    final index = indexOf(page);
    if (index < 0 || index + 1 >= starts.length) return null;
    return starts[index + 1];
  }

  /// Start of the current chapter, or of the previous one when already at the
  /// top — matching what a "previous chapter" button is expected to do.
  int? previousChapterStart(int page) {
    final index = indexOf(page);
    if (index < 0) return null;
    if (starts[index] < page) return starts[index];
    return index > 0 ? starts[index - 1] : null;
  }

  /// Build from a PDF outline.
  ///
  /// Only top-level entries are used: nested sub-sections would make "next
  /// chapter" jump a paragraph at a time, which is not what the control means.
  /// Entries without a resolvable page are dropped rather than guessed at.
  static ChapterIndex fromPdfOutline(List<PdfOutlineNode> outline, int pageCount) {
    final starts = <int>[];
    final titles = <String>[];

    for (final node in outline) {
      final page = node.dest?.pageNumber;
      if (page == null || page < 1 || page > pageCount) continue;
      // Two outline entries can point at the same page; keep the first.
      if (starts.isNotEmpty && starts.last == page) continue;
      starts.add(page);
      titles.add(node.title.trim().isEmpty ? 'Untitled' : node.title.trim());
    }

    if (starts.isEmpty) return ChapterIndex(const [], const [], pageCount);
    return _sorted(starts, titles, pageCount);
  }

  /// Build from the chapter list an EPUB or text document already produced.
  static ChapterIndex fromTextChapters(
    List<TextChapter> chapters,
    int pageCount,
  ) {
    final starts = <int>[];
    final titles = <String>[];
    for (final chapter in chapters) {
      final page = chapter.firstPage;
      if (page < 1 || page > pageCount) continue;
      if (starts.isNotEmpty && starts.last == page) continue;
      starts.add(page);
      titles.add(chapter.title.trim().isEmpty ? 'Untitled' : chapter.title.trim());
    }
    if (starts.isEmpty) return ChapterIndex(const [], const [], pageCount);
    return _sorted(starts, titles, pageCount);
  }

  /// An outline is not guaranteed to be in page order — a badly built PDF can
  /// list sections out of sequence, and the binary search above assumes sorted.
  static ChapterIndex _sorted(
    List<int> starts,
    List<String> titles,
    int pageCount,
  ) {
    final pairs = [
      for (var i = 0; i < starts.length; i++) (page: starts[i], title: titles[i])
    ]..sort((a, b) => a.page.compareTo(b.page));

    return ChapterIndex(
      [for (final p in pairs) p.page],
      [for (final p in pairs) p.title],
      pageCount,
    );
  }
}
