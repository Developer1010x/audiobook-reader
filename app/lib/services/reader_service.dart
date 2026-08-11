import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import 'classifier.dart';
import 'ocr_service.dart';
import 'spoken_text.dart';

/// Text extraction from a PDF. The page *rendering* is handled by PdfViewer in
/// the UI (which is what makes diagrams visible); this service exists for the
/// text that TTS and the summariser consume.
class ReaderService {
  /// Text of a single page (1-based).
  ///
  /// When the page carries no embedded text it is a scan, and [ocrFallback]
  /// decides whether to spend seconds running OCR or return empty and let the
  /// caller decide. Extraction is tried first every time — it is instant, and
  /// far more accurate than OCR when the text is really there.
  static Future<String> pageText(
    Book book,
    int pageNumber, {
    bool ocrFallback = false,
    void Function(String stage)? onProgress,
  }) async {
    final doc = await PdfDocument.openFile(book.path);
    String extracted;
    try {
      if (pageNumber < 1 || pageNumber > doc.pages.length) {
        throw RangeError('Page $pageNumber out of range (1..${doc.pages.length})');
      }
      final text = await doc.pages[pageNumber - 1].loadStructuredText();
      extracted = text.fullText;
    } finally {
      doc.dispose();
    }

    if (extracted.trim().isNotEmpty) return extracted;

    // Already-OCRed pages come back instantly, so check the cache even when the
    // caller did not ask to run OCR now.
    final cached = await OcrService.cached(book, pageNumber);
    if (cached != null && cached.trim().isNotEmpty) return cached;

    if (!ocrFallback) return extracted;
    return OcrService.recognisePage(book, pageNumber, onProgress: onProgress);
  }

  /// The page's text split into sentences, each mapped to its rectangles on the
  /// page — the basis for tap-to-start and the follow-along highlight.
  static Future<PageSpeech> pageSpeech(Book book, int pageNumber) async {
    final doc = await PdfDocument.openFile(book.path);
    try {
      if (pageNumber < 1 || pageNumber > doc.pages.length) {
        throw RangeError('Page $pageNumber out of range (1..${doc.pages.length})');
      }
      return PageSpeech.build(await doc.pages[pageNumber - 1].loadStructuredText());
    } finally {
      doc.dispose();
    }
  }

  /// True when the page has no embedded text and would need OCR.
  static Future<bool> needsOcr(Book book, int pageNumber) async {
    final text = await pageText(book, pageNumber);
    return text.trim().isEmpty;
  }

  /// Text of pages [start]..[end] inclusive, for chapter-sized summarising.
  static Future<String> rangeText(
    Book book,
    int start,
    int end, {
    bool ocrFallback = false,
    void Function(String stage)? onProgress,
  }) async {
    final doc = await PdfDocument.openFile(book.path);
    final int first, last;
    final buffer = StringBuffer();
    final scanned = <int>[];
    try {
      last = end.clamp(1, doc.pages.length);
      first = start.clamp(1, last);
      for (var i = first; i <= last; i++) {
        final text = await doc.pages[i - 1].loadStructuredText();
        if (text.fullText.trim().isEmpty) {
          scanned.add(i); // handled below, after the document is closed
        } else {
          buffer.writeln(text.fullText);
          buffer.writeln();
        }
      }
    } finally {
      doc.dispose();
    }

    // OCR reopens the document per page, so it must not run while this handle
    // is still held.
    for (final page in scanned) {
      final cached = await OcrService.cached(book, page);
      if (cached != null && cached.trim().isNotEmpty) {
        buffer.writeln(cached);
        buffer.writeln();
      } else if (ocrFallback) {
        onProgress?.call('Reading scanned page $page of $last…');
        try {
          buffer.writeln(
            await OcrService.recognisePage(book, page, onProgress: onProgress),
          );
          buffer.writeln();
        } on OcrException {
          continue; // one bad page should not sink the whole range
        }
      }
    }
    return buffer.toString();
  }

  static Future<int> pageCount(Book book) async {
    final doc = await PdfDocument.openFile(book.path);
    try {
      return doc.pages.length;
    } finally {
      doc.dispose();
    }
  }

  /// Auto-detect whether this is a textbook or a storybook.
  ///
  /// Samples from the *middle* of the book rather than the front: title pages,
  /// copyright notices and tables of contents look alike in every book, so page 1
  /// carries almost no signal. Only a handful of pages are read, so this stays
  /// fast enough to run on first open.
  static Future<Classification> classify(Book book) async {
    final doc = await PdfDocument.openFile(book.path);
    try {
      final n = doc.pages.length;
      if (n == 0) {
        return const Classification(BookType.storybook, 0.0, ['empty document']);
      }

      // Five samples spread across the middle 60% of the book.
      final samples = <int>[];
      for (var i = 1; i <= 5; i++) {
        final page = (n * (0.2 + 0.6 * (i / 6))).round().clamp(1, n);
        if (!samples.contains(page)) samples.add(page);
      }

      final buffer = StringBuffer();
      for (final page in samples) {
        try {
          final text = await doc.pages[page - 1].loadStructuredText();
          buffer.writeln(text.fullText);
        } catch (_) {
          continue; // a single unreadable page shouldn't fail classification
        }
      }
      return BookClassifier.classify(buffer.toString());
    } finally {
      doc.dispose();
    }
  }
}
