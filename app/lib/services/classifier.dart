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

  /// A research paper announces itself structurally long before its content
  /// differs: abstract, methodology, references, DOIs.
  static final _paperPatterns = <String, RegExp>{
    'abstract': RegExp(r'^\s*abstract\b', caseSensitive: false, multiLine: true),
    'sections': RegExp(
        r'\b(introduction|related work|methodology|experiments?|evaluation|'
        r'results and discussion|conclusions?|references|bibliography)\b',
        caseSensitive: false),
    'citations': RegExp(r'\[\d+(,\s*\d+)*\]|\(\w+ et al\.?,?\s*\d{4}\)'),
    'doi': RegExp(r'\bdoi:|arxiv:|10\.\d{4,}/', caseSensitive: false),
    'academic': RegExp(
        r'\b(we propose|we present|our approach|state[- ]of[- ]the[- ]art|'
        r'baseline|ablation|dataset|hypothesis|statistically significant)\b',
        caseSensitive: false),
  };

  /// Reference documentation reads as instructions to a machine, not a reader.
  static final _docsPatterns = <String, RegExp>{
    'api': RegExp(
        r'\b(parameters?|returns?|arguments?|throws|deprecated|since version|'
        r'default value|see also|usage)\b\s*:?', caseSensitive: false),
    'cli': RegExp(r'^\s*[-]{1,2}[a-z][\w-]*\b|\$\s+\w+', multiLine: true),
    'config': RegExp(r'^\s*[\w.]+\s*[:=]\s*\S', multiLine: true),
    'imperative': RegExp(
        r'\b(install|configure|run the|set the|add the|create a|open the|'
        r'navigate to|click|select)\b', caseSensitive: false),
    'versions': RegExp(r'\bv?\d+\.\d+(\.\d+)?\b'),
  };

  /// Correspondence is short and has a salutation and a sign-off.
  static final _letterPatterns = <String, RegExp>{
    'salutation': RegExp(
        r'^\s*(dear|to whom it may concern|hi|hello|respected)\b',
        caseSensitive: false, multiLine: true),
    'signoff': RegExp(
        r'\b(yours (sincerely|faithfully|truly)|kind regards|best regards|'
        r'regards|sincerely),?\s*\$',
        caseSensitive: false, multiLine: true),
    'letterhead': RegExp(
        r'^\s*(subject|re|ref|date|from|to)\s*:', caseSensitive: false,
        multiLine: true),
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

    double scoreOf(Map<String, RegExp> patterns, String tag) {
      var score = 0.0;
      for (final entry in patterns.entries) {
        final n = entry.value.allMatches(text).length;
        if (n == 0) continue;
        // Diminishing returns: variety of signals should beat one repeated hit.
        score += (n / per1k).clamp(0.0, 3.0);
        hits.add('$tag:${entry.key} ×$n');
      }
      return score;
    }

    final scores = <BookType, double>{
      BookType.textbook: scoreOf(_textbookPatterns, 'textbook'),
      BookType.paper: scoreOf(_paperPatterns, 'paper'),
      BookType.documentation: scoreOf(_docsPatterns, 'docs'),
      BookType.letter: scoreOf(_letterPatterns, 'letter'),
      BookType.storybook: scoreOf(_storyPatterns, 'story'),
    };

    // A letter is defined as much by brevity as by wording; a 400-page book
    // with a "Dear reader" preface is not correspondence.
    if (text.length > 6000) scores[BookType.letter] = 0;

    final total = scores.values.fold(0.0, (a, b) => a + b);
    if (total == 0) {
      return Classification(BookType.storybook, 0.0, ['no clear signals', ...hits]);
    }

    var winner = BookType.storybook;
    var winningScore = 0.0;
    scores.forEach((type, score) {
      if (score > winningScore) {
        winner = type;
        winningScore = score;
      }
    });

    final share = winningScore / total;

    // The bias, unchanged and still the point: a type that unlocks the AI path
    // must clear a real margin, not merely win 51/49. Getting this wrong the
    // expensive way offers a button that spends money and sends text to an API;
    // getting it wrong the cheap way hides a feature the user can turn back on.
    if (winner.usesLlm && share < 0.62) {
      return Classification(
        BookType.storybook,
        0.0,
        ['no type won clearly — defaulted to storybook', ...hits],
      );
    }

    // Confidence is how far ahead the winner is of an even split between the
    // types that actually scored.
    final scoring = scores.values.where((s) => s > 0).length;
    final evenShare = scoring == 0 ? 1.0 : 1.0 / scoring;
    final confidence =
        ((share - evenShare) / (1 - evenShare)).clamp(0.0, 1.0).toDouble();

    return Classification(winner, confidence, hits);
  }
}
