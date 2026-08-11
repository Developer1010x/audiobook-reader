import 'dart:math';

import '../models/book.dart';
import 'concurrency.dart';

/// Why a book was recommended, so the shelf can explain itself.
///
/// An unexplained recommendation is untrustworthy — the user cannot tell a good
/// suggestion from a random one, so they learn to ignore the whole shelf.
enum RecommendationReason {
  continueReading('Pick up where you left off'),
  sameShelf('More from this folder'),
  similarTitle('Similar to what you have been reading'),
  sameKind('Another textbook like the ones you study'),
  neglected('Started but not touched in a while'),
  quickWin('Short — finishable in a sitting'),
  unexplored('From a folder you have not opened yet');

  const RecommendationReason(this.label);
  final String label;
}

class Recommendation {
  const Recommendation({
    required this.bookId,
    required this.score,
    required this.reason,
  });

  final String bookId;
  final double score;
  final RecommendationReason reason;
}

/// Everything the recommender needs, as plain sendable data.
///
/// The model runs on another isolate over the whole library, so nothing here
/// may be a `File`, a widget or a service handle.
class RecommenderInput {
  const RecommenderInput({
    required this.books,
    required this.progress,
    required this.recentIds,
    required this.favouriteIds,
    required this.typeByIdName,
    required this.annotationCounts,
    required this.limit,
  });

  /// id, title, folder path, size, extension.
  final List<BookFacts> books;

  /// bookId -> fraction read, 0..1.
  final Map<String, double> progress;

  /// Most recently opened first.
  final List<String> recentIds;

  final Set<String> favouriteIds;

  /// bookId -> 'textbook' | 'storybook'.
  final Map<String, String> typeByIdName;

  /// bookId -> how many highlights it has.
  final Map<String, int> annotationCounts;

  final int limit;
}

/// The subset of a [Book] the model actually reads.
class BookFacts {
  const BookFacts({
    required this.id,
    required this.title,
    required this.folder,
    required this.sizeBytes,
    required this.ext,
  });

  final String id;
  final String title;
  final String folder;
  final int sizeBytes;
  final String ext;
}

/// Suggests what to read next, using only signals already on this machine.
///
/// **Deliberately not an LLM.** Recommending from a personal library needs no
/// language model: the useful signals are behavioural (what you opened, what
/// you abandoned, what you highlight) and lexical (how titles and folders
/// relate). A model would be slower, would need the library's contents sent
/// somewhere, and would not be more accurate at "you left this at 32%".
///
/// The scoring is a small weighted heuristic over normalised features, closer
/// to a hand-tuned linear model than to a rule list — every signal contributes
/// a bounded amount, so no single one can dominate.
class Recommender {
  /// Weights. Tuned so that resuming something half-read beats novelty, because
  /// an abandoned book at 40% is almost always the better suggestion.
  static const _wUnfinished = 3.2;
  static const _wFolderAffinity = 2.0;
  static const _wTitleSimilarity = 1.8;
  static const _wTypeMatch = 1.1;
  static const _wFavourite = 1.4;
  static const _wAnnotated = 1.2;
  static const _wShort = 0.7;
  static const _wNovelty = 0.5;

  /// Words that carry no signal in a technical library and would otherwise
  /// make everything look similar to everything.
  static const _stopWords = {
    'the', 'a', 'an', 'and', 'or', 'of', 'to', 'in', 'for', 'with', 'on',
    'introduction', 'guide', 'handbook', 'edition', 'vol', 'volume', 'part',
    'complete', 'beginners', 'beginner', 'advanced', 'using', 'learn',
    'learning', 'practical', 'modern', 'essential', 'fundamentals', 'pdf',
    'book', 'notes', 'copy', 'final', 'draft', 'new', 'ed',
  };

  /// Run the model off the UI thread — it is a full pass over the library.
  static Future<List<Recommendation>> suggest(RecommenderInput input) {
    // Worth an isolate once the library is real; a handful of books is faster
    // done inline than copied across.
    if (input.books.length < 60) return Future.value(score(input));
    return Concurrency.runOffThread(score, input, debugLabel: 'recommend');
  }

  /// Pure scoring pass. Static and side-effect free so it can cross isolates.
  static List<Recommendation> score(RecommenderInput input) {
    if (input.books.isEmpty) return const [];

    final byId = {for (final b in input.books) b.id: b};

    // ── build a taste profile from what has actually been read ──
    //
    // Weighted by recency: the tenth-most-recent book says less about what you
    // want now than the last one did.
    final folderAffinity = <String, double>{};
    final termWeights = <String, double>{};
    final typeCounts = <String, double>{};

    for (var i = 0; i < input.recentIds.length; i++) {
      final book = byId[input.recentIds[i]];
      if (book == null) continue;

      final recency = 1.0 / (1 + i * 0.45);
      folderAffinity[book.folder] = (folderAffinity[book.folder] ?? 0) + recency;

      for (final term in _terms(book.title)) {
        termWeights[term] = (termWeights[term] ?? 0) + recency;
      }
      final type = input.typeByIdName[book.id];
      if (type != null) typeCounts[type] = (typeCounts[type] ?? 0) + recency;
    }

    // Favourites express taste even when never opened.
    for (final id in input.favouriteIds) {
      final book = byId[id];
      if (book == null) continue;
      folderAffinity[book.folder] = (folderAffinity[book.folder] ?? 0) + 0.6;
      for (final term in _terms(book.title)) {
        termWeights[term] = (termWeights[term] ?? 0) + 0.4;
      }
    }

    final maxFolder = _maxOf(folderAffinity);
    final maxTerm = _maxOf(termWeights);
    final preferredType = _argMax(typeCounts);

    // Folders never opened at all — used for a small novelty nudge, so the
    // shelf does not collapse onto one subject forever.
    final touchedFolders = folderAffinity.keys.toSet();

    final median = _medianSize(input.books);
    final results = <Recommendation>[];

    for (final book in input.books) {
      final read = input.progress[book.id] ?? 0.0;

      // Finished, or as good as. Nothing to recommend.
      if (read >= 0.92) continue;

      var total = 0.0;
      var reason = RecommendationReason.unexplored;
      var best = 0.0;

      void consider(double contribution, RecommendationReason candidate) {
        total += contribution;
        // The headline reason is whichever signal contributed most, so the
        // explanation always matches the real driver.
        if (contribution > best) {
          best = contribution;
          reason = candidate;
        }
      }

      // Started but unfinished — the strongest signal there is. Peaks around a
      // third read: barely-started books are weaker evidence of intent, and
      // nearly-finished ones need no nudge.
      if (read > 0.02) {
        final shape = 1.0 - (read - 0.35).abs() / 0.65;
        consider(
          _wUnfinished * shape.clamp(0.0, 1.0),
          read < 0.15
              ? RecommendationReason.continueReading
              : RecommendationReason.neglected,
        );
      }

      // Same folder as recent reading. The book's own visit is discounted for
      // the same reason as title similarity: affinity should mean "others like
      // this were read", not "this was read".
      final selfFolder = _selfContribution(book, input);
      final folder = (folderAffinity[book.folder] ?? 0) - selfFolder;
      if (folder > 0 && maxFolder > 0) {
        consider(_wFolderAffinity * (folder / maxFolder).clamp(0.0, 1.0),
            RecommendationReason.sameShelf);
      }

      // Lexical overlap with recent titles — a crude but effective stand-in for
      // subject similarity when there is no metadata beyond a filename.
      if (maxTerm > 0) {
        final terms = _terms(book.title);
        if (terms.isNotEmpty) {
          // A book that is itself in the profile would otherwise match its own
          // terms perfectly and top the shelf for no reason but being recent.
          // Its own contribution is removed so similarity means similarity *to
          // other things*.
          final selfWeight = _selfContribution(book, input);

          var overlap = 0.0;
          for (final term in terms) {
            final weight = (termWeights[term] ?? 0) - selfWeight;
            if (weight <= 0) continue;
            overlap += weight / maxTerm;
          }
          // Normalised by length so a long title does not win by having more
          // words to match with.
          consider(
            _wTitleSimilarity * (overlap / sqrt(terms.length)).clamp(0.0, 1.0),
            RecommendationReason.similarTitle,
          );
        }
      }

      // Same kind of book as the user mostly reads.
      if (preferredType != null &&
          input.typeByIdName[book.id] == preferredType) {
        consider(_wTypeMatch, RecommendationReason.sameKind);
      }

      if (input.favouriteIds.contains(book.id)) {
        consider(_wFavourite, RecommendationReason.continueReading);
      }

      // Books the user annotates are books the user engages with.
      final notes = input.annotationCounts[book.id] ?? 0;
      if (notes > 0) {
        consider(_wAnnotated * min(1.0, notes / 5.0),
            RecommendationReason.continueReading);
      }

      // A short unread book is an easy win worth surfacing.
      if (read == 0 && book.sizeBytes > 0 && book.sizeBytes < median) {
        consider(_wShort * (1 - book.sizeBytes / median),
            RecommendationReason.quickWin);
      }

      // Gentle pull towards untouched corners of the library.
      if (!touchedFolders.contains(book.folder) && read == 0) {
        consider(_wNovelty, RecommendationReason.unexplored);
      }

      if (total <= 0) continue;
      results.add(Recommendation(
        bookId: book.id,
        score: total,
        reason: reason,
      ));
    }

    results.sort((a, b) => b.score.compareTo(a.score));

    // Spread across folders so the shelf is not six books from one directory.
    final seenFolders = <String, int>{};
    final spread = <Recommendation>[];
    for (final r in results) {
      final folder = byId[r.bookId]?.folder ?? '';
      final count = seenFolders[folder] ?? 0;
      if (count >= 2 && spread.length < input.limit) continue;
      seenFolders[folder] = count + 1;
      spread.add(r);
      if (spread.length >= input.limit) break;
    }
    return spread;
  }

  /// How much a book contributed to the taste profile itself.
  ///
  /// Recency weighting must match the profile-building loop exactly, or the
  /// subtraction leaves a residue and the self-match creeps back.
  static double _selfContribution(BookFacts book, RecommenderInput input) {
    var weight = 0.0;
    final index = input.recentIds.indexOf(book.id);
    if (index >= 0) weight += 1.0 / (1 + index * 0.45);
    if (input.favouriteIds.contains(book.id)) weight += 0.4;
    return weight;
  }

  /// Title into meaningful lowercase terms.
  ///
  /// Filenames are messy — underscores, hyphens, page counts, "(alt copy)" —
  /// so this strips aggressively and keeps only words that could carry subject
  /// meaning.
  static Set<String> _terms(String title) {
    final cleaned = title
        .toLowerCase()
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'[^a-z0-9+#]+'), ' ');
    return cleaned
        .split(' ')
        .where((w) => w.length > 2 && !_stopWords.contains(w))
        .where((w) => !RegExp(r'^\d+$').hasMatch(w))
        .toSet();
  }

  static double _maxOf(Map<String, double> m) =>
      m.isEmpty ? 0 : m.values.reduce(max);

  static String? _argMax(Map<String, double> m) {
    if (m.isEmpty) return null;
    var bestKey = m.keys.first;
    var bestValue = m[bestKey]!;
    for (final entry in m.entries) {
      if (entry.value > bestValue) {
        bestKey = entry.key;
        bestValue = entry.value;
      }
    }
    return bestKey;
  }

  static double _medianSize(List<BookFacts> books) {
    final sizes = books.map((b) => b.sizeBytes).where((s) => s > 0).toList()
      ..sort();
    if (sizes.isEmpty) return 1;
    return sizes[sizes.length ~/ 2].toDouble();
  }
}

/// Builds the model's input from live app state.
///
/// Kept out of [Recommender] so the model itself stays pure and testable with
/// hand-made data.
RecommenderInput buildRecommenderInput({
  required List<Book> books,
  required List<String> recentIds,
  required Set<String> favouriteIds,
  required double Function(String id) progressOf,
  required String? Function(String id) typeOf,
  required int Function(String id) annotationsOf,
  int limit = 8,
}) {
  final facts = <BookFacts>[];
  final progress = <String, double>{};
  final types = <String, String>{};
  final notes = <String, int>{};

  for (final book in books) {
    final folder = book.path.contains('/')
        ? book.path.substring(0, book.path.lastIndexOf('/'))
        : '';
    facts.add(BookFacts(
      id: book.id,
      title: book.title,
      folder: folder,
      sizeBytes: book.sizeBytes,
      ext: book.ext,
    ));
    final read = progressOf(book.id);
    if (read > 0) progress[book.id] = read;
    final type = typeOf(book.id);
    if (type != null) types[book.id] = type;
    final count = annotationsOf(book.id);
    if (count > 0) notes[book.id] = count;
  }

  return RecommenderInput(
    books: facts,
    progress: progress,
    recentIds: recentIds,
    favouriteIds: favouriteIds,
    typeByIdName: types,
    annotationCounts: notes,
    limit: limit,
  );
}
