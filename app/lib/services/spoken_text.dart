import 'package:pdfrx/pdfrx.dart';

/// One speakable unit of a page — a sentence — plus where it sits on the page.
///
/// Holding the character range lets the reader highlight exactly what is being
/// spoken, and lets a tap on the page resolve to "start from here".
class Segment {
  /// Index into the page's full text.
  final int start;
  final int end;
  final String text;

  const Segment({required this.start, required this.end, required this.text});

  bool contains(int charIndex) => charIndex >= start && charIndex < end;
}

/// A page's text, split into sentences and mapped back to on-page rectangles.
class PageSpeech {
  final PdfPageText pageText;
  final List<Segment> segments;

  const PageSpeech({required this.pageText, required this.segments});

  String get fullText => pageText.fullText;

  bool get isEmpty => segments.isEmpty;

  /// Build from an extracted page.
  ///
  /// Splits on sentence endings rather than fixed lengths, because the
  /// highlight follows these boundaries — a chunk cut mid-clause would both
  /// sound wrong and highlight a meaningless span.
  static PageSpeech build(PdfPageText pageText) {
    final text = pageText.fullText;
    final segments = <Segment>[];

    final pattern = RegExp(r'[^.!?]*[.!?]+[\s"”)\]]*|[^.!?]+$');
    for (final match in pattern.allMatches(text)) {
      final raw = match.group(0);
      if (raw == null) continue;

      // Trim, but keep the offsets pointing at the untrimmed source so the
      // rectangles line up with the characters actually on the page.
      var start = match.start;
      var end = match.end;
      while (start < end && _isSpace(text.codeUnitAt(start))) {
        start++;
      }
      while (end > start && _isSpace(text.codeUnitAt(end - 1))) {
        end--;
      }
      if (end <= start) continue;

      final segmentText = text.substring(start, end);
      // A "sentence" of pure punctuation or a stray page number is not worth
      // speaking or highlighting.
      if (!RegExp(r'[A-Za-z]{2}').hasMatch(segmentText)) continue;

      segments.add(Segment(start: start, end: end, text: segmentText));
    }

    return PageSpeech(pageText: pageText, segments: segments);
  }

  static bool _isSpace(int codeUnit) =>
      codeUnit == 0x20 || codeUnit == 0x0A || codeUnit == 0x0D || codeUnit == 0x09;

  /// Character rectangles covering [segment], merged into lines so the highlight
  /// is a few bars rather than one box per glyph.
  List<PdfRect> rectsFor(Segment segment) {
    final charRects = pageText.charRects;
    if (charRects.isEmpty) return const [];

    final lines = <PdfRect>[];
    PdfRect? current;

    for (var i = segment.start; i < segment.end && i < charRects.length; i++) {
      final rect = charRects[i];
      if (rect.width <= 0 && rect.height <= 0) continue;

      if (current == null) {
        current = rect;
        continue;
      }
      // Same visual line when the vertical span still overlaps; PDF y grows
      // upward, so compare tops.
      final sameLine = (current.top - rect.top).abs() < (current.height / 2);
      if (sameLine) {
        current = current.merge(rect);
      } else {
        lines.add(current);
        current = rect;
      }
    }
    if (current != null) lines.add(current);
    return lines;
  }

  /// The segment nearest to a tapped point, for "start reading here".
  ///
  /// Returns the segment whose characters are closest to [point] in PDF page
  /// coordinates, or null when the page has no text near the tap.
  Segment? segmentAt(PdfPoint point) {
    final charRects = pageText.charRects;
    if (charRects.isEmpty || segments.isEmpty) return null;

    var bestIndex = -1;
    var bestDistance = double.infinity;

    for (var i = 0; i < charRects.length; i++) {
      final rect = charRects[i];
      if (rect.width <= 0 && rect.height <= 0) continue;
      final distance = _distanceTo(rect, point);
      if (distance < bestDistance) {
        bestDistance = distance;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) return null;

    for (final segment in segments) {
      if (segment.contains(bestIndex)) return segment;
    }
    // The tap landed between segments (whitespace); use the next one starting
    // after it, so tapping a gap reads onward rather than doing nothing.
    for (final segment in segments) {
      if (segment.start >= bestIndex) return segment;
    }
    return segments.last;
  }

  static double _distanceTo(PdfRect rect, PdfPoint point) {
    final dx = point.x < rect.left
        ? rect.left - point.x
        : (point.x > rect.right ? point.x - rect.right : 0.0);
    // PDF rects have top > bottom.
    final dy = point.y > rect.top
        ? point.y - rect.top
        : (point.y < rect.bottom ? rect.bottom - point.y : 0.0);
    return dx * dx + dy * dy;
  }
}
