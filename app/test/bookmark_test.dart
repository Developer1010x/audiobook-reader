import 'package:audiobook_reader/models/bookmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Bookmark make(int page, {String? note}) => Bookmark(
        page: page,
        preview: 'preview for page $page',
        note: note,
        createdAt: 1000 + page,
      );

  group('round trip', () {
    test('survives encode/decode with every field intact', () {
      final original = make(7, note: 'come back to this');
      final restored = Bookmark.decode(Bookmark.encode([original])).single;

      expect(restored.page, original.page);
      expect(restored.preview, original.preview);
      expect(restored.note, original.note);
      expect(restored.createdAt, original.createdAt);
    });

    test('decodes in page order regardless of stored order', () {
      final encoded = Bookmark.encode([make(9), make(2), make(5)]);
      expect(Bookmark.decode(encoded).map((b) => b.page), [2, 5, 9]);
    });

    test('a bookmark without a note round-trips as null, not "null"', () {
      final restored = Bookmark.decode(Bookmark.encode([make(1)])).single;
      expect(restored.note, isNull);
    });
  });

  group('corrupt storage', () {
    test('never throws — bookmarks are not worth crashing the reader for', () {
      expect(Bookmark.decode(null), isEmpty);
      expect(Bookmark.decode(''), isEmpty);
      expect(Bookmark.decode('not json at all'), isEmpty);
      expect(Bookmark.decode('{"not":"a list"}'), isEmpty);
      expect(Bookmark.decode('[{"missing":"page"}]'), isEmpty);
    });
  });

  group('copyWith', () {
    test('adds a note without disturbing the position', () {
      final updated = make(4).copyWith(note: 'exam question');
      expect(updated.note, 'exam question');
      expect(updated.page, 4);
      expect(updated.createdAt, 1004);
    });
  });

  group('created', () {
    test('exposes the timestamp as a DateTime', () {
      expect(make(1).created.millisecondsSinceEpoch, 1001);
    });
  });
}
