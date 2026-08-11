import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import 'classifier.dart';
import 'document_cache.dart';
import 'concurrency.dart';
import 'ocr_service.dart';
import 'spoken_text.dart';

/// Isolate entry point for classification scoring.
///
/// [Classification] itself carries a [BookType] enum, and enum identity across
/// an isolate hand-off is a guarantee not worth leaning on, so the result
/// crosses as primitives and is rebuilt by the caller.
Map<String, Object?> _scoreSample(String sample) {
  final result = BookClassifier.classify(sample);
  return {
    'type': result.type.name,
    'confidence': result.confidence,
    'signals': result.signals,
  };
}

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
    final doc = await DocumentCache.borrow(book);
    String extracted;
    try {
      if (pageNumber < 1 || pageNumber > doc.pages.length) {
        throw RangeError('Page $pageNumber out of range (1..${doc.pages.length})');
      }
      final text = await doc.pages[pageNumber - 1].loadStructuredText();
      extracted = text.fullText;
    } finally {
      DocumentCache.returnHandle(book);
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
    return DocumentCache.use(book, (doc) async {
      if (pageNumber < 1 || pageNumber > doc.pages.length) {
        throw RangeError('Page $pageNumber out of range (1..${doc.pages.length})');
      }
      return PageSpeech.build(
          await doc.pages[pageNumber - 1].loadStructuredText());
    });
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
    final doc = await DocumentCache.borrow(book);
    final int first, last;
    // One slot per page, so text that arrives late — OCR finishing in whatever
    // order the pages happen to complete — still lands in page order.
    final List<String?> parts;
    final scanned = <int>[];
    try {
      last = end.clamp(1, doc.pages.length);
      first = start.clamp(1, last);
      parts = List<String?>.filled(last - first + 1, null);
      // These reads share one document handle, so they stay sequential:
      // concurrent page access on a single pdfrx document is not a guarantee
      // the library makes. Extraction is cheap anyway — OCR below is the part
      // worth parallelising.
      for (var i = first; i <= last; i++) {
        final text = await doc.pages[i - 1].loadStructuredText();
        if (text.fullText.trim().isEmpty) {
          scanned.add(i); // handled below, after the document is closed
        } else {
          parts[i - first] = text.fullText;
        }
      }
    } finally {
      DocumentCache.returnHandle(book);
    }

    if (scanned.isNotEmpty) {
      // OCR reopens the document per page, so it must not run while the handle
      // above is still held. Each page costs seconds of render plus a Tesseract
      // subprocess, so pages go through the CPU pool rather than one at a time.
      // Nothing slow happens unless OCR may actually run, so stay quiet
      // otherwise; a cache lookup is not worth a stage message.
      final report = ocrFallback ? onProgress : null;
      var done = 0;
      report?.call('Reading ${scanned.length} scanned page(s)…');
      // Per-page detail only makes sense when nothing overlaps; with several
      // pages in flight the stage line would flicker between them.
      final detail = scanned.length == 1 ? onProgress : null;

      // mapBounded, not mapBoundedLenient: results are matched back to pages by
      // index, so a dropped entry would shift every page after it.
      final recognised = await Concurrency.mapBounded<int, String?>(
        scanned,
        (page, _) async {
          try {
            final cached = await OcrService.cached(book, page);
            if (cached != null && cached.trim().isNotEmpty) return cached;
            if (!ocrFallback) return null;
            return await OcrService.recognisePage(book, page, onProgress: detail);
          } on OcrException {
            return null; // one bad page should not sink the whole range
          } finally {
            done++;
            report?.call('Read $done of ${scanned.length} scanned page(s)…');
          }
        },
        concurrency: Concurrency.cpuPool,
      );

      for (var i = 0; i < scanned.length; i++) {
        parts[scanned[i] - first] = recognised[i];
      }
    }

    final buffer = StringBuffer();
    for (final part in parts) {
      if (part == null) continue;
      buffer.writeln(part);
      buffer.writeln();
    }
    return buffer.toString();
  }

  static Future<int> pageCount(Book book) async {
    return DocumentCache.use(book, (doc) async => doc.pages.length);
  }

  /// Auto-detect whether this is a textbook or a storybook.
  ///
  /// Samples from the *middle* of the book rather than the front: title pages,
  /// copyright notices and tables of contents look alike in every book, so page 1
  /// carries almost no signal. Only a handful of pages are read, so this stays
  /// fast enough to run on first open.
  static Future<Classification> classify(Book book) async {
    final doc = await DocumentCache.borrow(book);
    final String sample;
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

      // Sequential on purpose: one document handle is shared here, and pdfrx
      // makes no promise about concurrent page access on it. Five reads are
      // cheap; the scoring below is the part that can cost a frame.
      final buffer = StringBuffer();
      for (final page in samples) {
        try {
          final text = await doc.pages[page - 1].loadStructuredText();
          buffer.writeln(text.fullText);
        } catch (_) {
          continue; // a single unreadable page shouldn't fail classification
        }
      }
      sample = buffer.toString();
    } finally {
      DocumentCache.returnHandle(book);
    }

    // A dozen regexes over several pages of text. On a short sample the isolate
    // hand-off costs more than the scan, so only a big one goes off-thread.
    if (!Concurrency.worthOffloading(sample.length)) {
      return BookClassifier.classify(sample);
    }
    final scored = await Concurrency.runOffThread(
      _scoreSample,
      sample,
      debugLabel: 'classify',
    );
    return Classification(
      BookType.values.byName(scored['type'] as String),
      scored['confidence'] as double,
      (scored['signals'] as List).cast<String>(),
    );
  }
}
