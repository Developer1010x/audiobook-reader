import 'package:audiobook_reader/services/recommender.dart';
import 'package:flutter_test/flutter_test.dart';

/// The recommender is a heuristic model, so these test its *judgement*, not
/// just that it runs: does the strongest signal actually win, and does it stay
/// sane on a cold library with no history at all?
void main() {
  BookFacts book(String id, {String? title, String folder = '/lib', int size = 1000}) =>
      BookFacts(
        id: id,
        title: title ?? id,
        folder: folder,
        sizeBytes: size,
        ext: 'pdf',
      );

  RecommenderInput input({
    required List<BookFacts> books,
    Map<String, double> progress = const {},
    List<String> recent = const [],
    Set<String> favourites = const {},
    Map<String, String> types = const {},
    Map<String, int> annotations = const {},
    int limit = 8,
  }) =>
      RecommenderInput(
        books: books,
        progress: progress,
        recentIds: recent,
        favouriteIds: favourites,
        typeByIdName: types,
        annotationCounts: annotations,
        limit: limit,
      );

  group('cold start', () {
    test('an empty library recommends nothing rather than crashing', () {
      expect(Recommender.score(input(books: [])), isEmpty);
    });

    test('with no history at all it still suggests something', () {
      // A brand-new user must not see an empty shelf.
      final out = Recommender.score(input(books: [
        book('a', size: 500),
        book('b', size: 900),
      ]));
      expect(out, isNotEmpty);
    });
  });

  group('unfinished books dominate', () {
    test('a part-read book outranks an untouched one', () {
      final out = Recommender.score(input(
        books: [book('untouched'), book('halfread')],
        progress: {'halfread': 0.35},
      ));
      expect(out.first.bookId, 'halfread');
    });

    test('a finished book is never recommended', () {
      final out = Recommender.score(input(
        books: [book('done'), book('fresh')],
        progress: {'done': 0.98},
      ));
      expect(out.map((r) => r.bookId), isNot(contains('done')));
    });

    test('a barely-started book scores below a properly-started one', () {
      // 3% read is weak evidence of intent; 35% is someone mid-chapter.
      final out = Recommender.score(input(
        books: [book('barely'), book('properly')],
        progress: {'barely': 0.03, 'properly': 0.35},
      ));
      expect(out.first.bookId, 'properly');
    });
  });

  group('taste signals', () {
    test('folder affinity lifts books from a folder being read', () {
      final out = Recommender.score(input(
        books: [
          book('read-me', folder: '/lib/ml'),
          book('elsewhere', folder: '/lib/cooking'),
          book('history', folder: '/lib/ml'),
        ],
        recent: ['history'],
      ));
      expect(out.first.bookId, 'read-me');
    });

    test('title similarity connects related subjects', () {
      final out = Recommender.score(input(
        books: [
          book('x', title: 'Deep Learning with PyTorch', folder: '/a'),
          book('y', title: 'Italian Cooking', folder: '/b'),
          book('seed', title: 'Deep Learning Foundations', folder: '/c'),
        ],
        recent: ['seed'],
      ));
      final ranked = out.map((r) => r.bookId).toList();
      expect(ranked.indexOf('x'), lessThan(ranked.indexOf('y')));
    });

    test('generic words do not make everything look similar', () {
      // "Introduction" and "Guide" are stop words: these share nothing real.
      final out = Recommender.score(input(
        books: [
          book('x', title: 'Introduction to Cooking', folder: '/a'),
          book('seed', title: 'Introduction to Physics', folder: '/b'),
        ],
        recent: ['seed'],
      ));
      final x = out.firstWhere((r) => r.bookId == 'x');
      expect(x.reason, isNot(RecommendationReason.similarTitle));
    });

    test('favourites and annotations count as engagement', () {
      final out = Recommender.score(input(
        books: [book('plain'), book('starred'), book('annotated')],
        favourites: {'starred'},
        annotations: {'annotated': 6},
      ));
      final ids = out.map((r) => r.bookId).toList();
      expect(ids, contains('starred'));
      expect(ids, contains('annotated'));
      // 'plain' carries no signal whatsoever, so it is correctly left out
      // rather than padded onto the end of the shelf.
      expect(ids.indexOf('starred'), lessThan(2));
    });
  });

  group('explanations', () {
    test('every recommendation carries a reason', () {
      final out = Recommender.score(input(
        books: [book('a'), book('b')],
        progress: {'a': 0.3},
      ));
      expect(out.every((r) => r.reason.label.isNotEmpty), isTrue);
    });

    test('the reason matches the dominant signal', () {
      // Half-read with no other signal must be explained by resuming, not by
      // something incidental.
      final out = Recommender.score(input(
        books: [book('a')],
        progress: {'a': 0.4},
      ));
      expect(
        out.single.reason,
        anyOf(RecommendationReason.neglected,
            RecommendationReason.continueReading),
      );
    });
  });

  group('shelf quality', () {
    test('respects the requested limit', () {
      final out = Recommender.score(input(
        books: List.generate(50, (i) => book('b$i', folder: '/f${i % 9}')),
        limit: 5,
      ));
      expect(out.length, lessThanOrEqualTo(5));
    });

    test('does not fill the shelf from a single folder', () {
      // Twenty books in one folder, a few elsewhere: the shelf must not be
      // twenty variations of the same subject.
      final books = [
        ...List.generate(20, (i) => book('same$i', folder: '/one')),
        book('other1', folder: '/two'),
        book('other2', folder: '/three'),
      ];
      final out = Recommender.score(input(books: books, limit: 6));
      final fromOne =
          out.where((r) => r.bookId.startsWith('same')).length;
      expect(fromOne, lessThanOrEqualTo(3));
    });

    test('results are ordered by score, strongest first', () {
      final out = Recommender.score(input(
        books: List.generate(10, (i) => book('b$i', folder: '/f$i')),
        progress: {'b3': 0.35, 'b7': 0.1},
      ));
      for (var i = 1; i < out.length; i++) {
        expect(out[i - 1].score, greaterThanOrEqualTo(out[i].score));
      }
    });
  });

  group('determinism', () {
    test('the same input always produces the same output', () {
      // A shelf that reshuffles on every rebuild feels broken.
      final data = input(
        books: List.generate(30, (i) => book('b$i', folder: '/f${i % 4}')),
        progress: {'b2': 0.3, 'b9': 0.5},
        recent: ['b9', 'b2'],
      );
      final first = Recommender.score(data).map((r) => r.bookId).toList();
      final second = Recommender.score(data).map((r) => r.bookId).toList();
      expect(first, second);
    });
  });
}
