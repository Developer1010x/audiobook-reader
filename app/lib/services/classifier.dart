import '../models/book.dart';

/// Decides whether a book is a textbook or a storybook from its own text.
///
/// No LLM is used here — that would defeat the point, since the whole reason to
/// classify is to avoid calling a model unless one is needed. These are cheap
/// signals over a text sample, and they are deliberately biased:
///
///   **Ties go to storybook.** A storybook misread as a textbook would offer an
///   LLM button that quietly costs money and sends text to an API; a textbook
///   misread as a storybook merely hides a feature the user can turn back on.
///   The cheap mistake is the one we make.
class Classification {
  final BookType type;
  final double confidence; // 0..1
  final List<String> signals; // human-readable reasons, shown in the UI

  const Classification(this.type, this.confidence, this.signals);
}

class BookClassifier {
  /// Markers of instructional writing. Presence is weak on its own — a novel may
  /// say "for example" — so scoring is by *density and variety*, not any one hit.
  static final _textbookPatterns = <String, RegExp>{
    'exercises': RegExp(r'\b(exercise|problem set|homework|quiz)\b\s*\d*', caseSensitive: false),
    'figures': RegExp(r'\b(figure|fig\.|table|listing)\s*\d+[.:]', caseSensitive: false),
    'equations': RegExp(r'[=∑∫√±≤≥≠]|\b\d+\s*[+\-*/^]\s*\d+'),
    'citations': RegExp(r'\[\d+\]|\(\w+,?\s*\d{4}\)'),
    'sections': RegExp(r'^\s*\d+\.\d+\s+\w', multiLine: true),
    'instructional': RegExp(
      r'\b(chapter summary|in this chapter|we will|note that|recall that|'
      r'definition|theorem|lemma|proof|algorithm|syntax|parameter)\b',
      caseSensitive: false,
    ),
    'code': RegExp(r'[{};]\s*$|\b(function|class|def|import|return|void|int|var)\b', multiLine: true),
  };

  /// Markers of narrative prose.
  static final _storyPatterns = <String, RegExp>{
    'dialogue': RegExp(r'[""“”].{3,}?[""“”]|^\s*[-—]\s+\w', multiLine: true),
    'narrative': RegExp(
      r'\b(he said|she said|they said|whispered|murmured|laughed|'
      r'once upon|the next morning|years later|his eyes|her voice)\b',
      caseSensitive: false,
    ),
    'pastTense': RegExp(r'\b(walked|looked|turned|smiled|sighed|wondered|remembered)\b',
        caseSensitive: false),
  };

  /// Classify from a text sample (a few pages spread through the book).
  ///
  /// [sample] should come from the middle of the book, not page 1 — front matter
  /// and copyright pages look identical for every kind of book.
  static Classification classify(String sample) {
    final text = sample.trim();
    if (text.length < 200) {
      // Too little text to judge — usually a scanned book. Default to storybook
      // so nothing is sent anywhere; the user can override.
      return const Classification(
        BookType.storybook,
        0.0,
        ['too little extractable text to classify (likely scanned)'],
      );
    }

    // Per 1000 characters, so a long sample doesn't automatically look technical.
    final per1k = text.length / 1000.0;
    final hits = <String>[];
    var textbookScore = 0.0;
    var storyScore = 0.0;

    for (final entry in _textbookPatterns.entries) {
      final n = entry.value.allMatches(text).length;
      if (n == 0) continue;
      final density = n / per1k;
      // Diminishing returns: variety of signals should beat one repeated hit.
      textbookScore += density.clamp(0.0, 3.0);
      hits.add('${entry.key} ×$n');
    }
    for (final entry in _storyPatterns.entries) {
      final n = entry.value.allMatches(text).length;
      if (n == 0) continue;
      storyScore += (n / per1k).clamp(0.0, 3.0);
      hits.add('${entry.key} ×$n');
    }

    final total = textbookScore + storyScore;
    if (total == 0) {
      return Classification(BookType.storybook, 0.0, ['no clear signals', ...hits]);
    }

    final textbookShare = textbookScore / total;
    // The bias: a textbook must clear a real margin, not merely win 51/49.
    final isTextbook = textbookShare > 0.62;
    final confidence = ((textbookShare - 0.5).abs() * 2).clamp(0.0, 1.0);

    return Classification(
      isTextbook ? BookType.textbook : BookType.storybook,
      confidence,
      hits,
    );
  }
}
