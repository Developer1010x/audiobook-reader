import 'package:audiobook_reader/models/annotation.dart';
import 'package:audiobook_reader/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Annotation make(int page, {String? note, HighlightColor? color}) => Annotation(
        id: 'id-$page',
        page: page,
        quote: 'quoted passage from page $page',
        note: note,
        color: color ?? HighlightColor.yellow,
        createdAt: 1700000000000 + page,
      );

  group('round trip', () {
    test('every field survives encode/decode', () {
      final original = make(4, note: 'matters for the exam', color: HighlightColor.blue);
      final restored = Annotation.decode(Annotation.encode([original])).single;

      expect(restored.id, original.id);
      expect(restored.page, 4);
      expect(restored.quote, original.quote);
      expect(restored.note, 'matters for the exam');
      expect(restored.color, HighlightColor.blue);
    });

    test('decodes in page order', () {
      final encoded = Annotation.encode([make(9), make(2), make(5)]);
      expect(Annotation.decode(encoded).map((a) => a.page), [2, 5, 9]);
    });

    test('returns a growable list — callers mutate it', () {
      // The bug this guards: const [] cannot be added to, which broke bookmarks.
      final list = Annotation.decode(null);
      expect(() => list.add(make(1)), returnsNormally);
    });

    test('corrupt storage yields empty rather than throwing', () {
      expect(Annotation.decode('nonsense'), isEmpty);
      expect(Annotation.decode('{"not":"a list"}'), isEmpty);
      expect(Annotation.decode(''), isEmpty);
    });

    test('an unknown colour name falls back rather than failing', () {
      expect(HighlightColor.from('chartreuse'), HighlightColor.yellow);
      expect(HighlightColor.from(null), HighlightColor.yellow);
    });
  });

  group('hasNote', () {
    test('distinguishes a real note from empty or whitespace', () {
      expect(make(1).hasNote, isFalse);
      expect(make(1, note: '   ').hasNote, isFalse);
      expect(make(1, note: 'something').hasNote, isTrue);
    });
  });

  group('markdown export', () {
    test('quotes the passage and includes the note', () {
      final md = Annotation.toMarkdown('My Book', [
        make(3, note: 'key idea'),
      ]);
      expect(md, contains('# My Book'));
      expect(md, contains('## Page 3'));
      expect(md, contains('> quoted passage from page 3'));
      expect(md, contains('key idea'));
    });

    test('a highlight without a note still exports its quote', () {
      final md = Annotation.toMarkdown('My Book', [make(1)]);
      expect(md, contains('> quoted passage from page 1'));
    });

    test('multi-line quotes are quoted on every line', () {
      final a = Annotation(
        id: 'x',
        page: 1,
        quote: 'first line\nsecond line',
        createdAt: 0,
      );
      final md = Annotation.toMarkdown('B', [a]);
      expect(md, contains('> first line'));
      expect(md, contains('> second line'));
    });
  });

  group('storage', () {
    late SettingsService settings;
    const bookId = '/books/x.pdf';

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await SettingsService.load();
    });

    test('adding then reading back works from empty', () async {
      expect(settings.annotations(bookId), isEmpty);
      await settings.addAnnotation(bookId, make(2));
      expect(settings.annotations(bookId), hasLength(1));
      expect(settings.annotationCount(bookId), 1);
    });

    test('editing replaces in place rather than duplicating', () async {
      await settings.addAnnotation(bookId, make(2));
      final existing = settings.annotations(bookId).single;
      await settings.addAnnotation(bookId, existing.copyWith(note: 'edited'));

      final list = settings.annotations(bookId);
      expect(list, hasLength(1));
      expect(list.single.note, 'edited');
    });

    test('removal works and is per book', () async {
      await settings.addAnnotation(bookId, make(2));
      await settings.addAnnotation('/books/other.pdf', make(2));

      await settings.removeAnnotation(bookId, 'id-2');
      expect(settings.annotations(bookId), isEmpty);
      expect(settings.annotations('/books/other.pdf'), hasLength(1));
    });

    test('survives a reload', () async {
      await settings.addAnnotation(bookId, make(7, note: 'persisted'));
      final reloaded = await SettingsService.load();
      expect(reloaded.annotations(bookId).single.note, 'persisted');
    });
  });
}
