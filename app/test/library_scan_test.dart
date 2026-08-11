import 'dart:io';

import 'package:audiobook_reader/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Real filesystem tests for scan().
///
/// scan() previously had **no** coverage at all — library_tree_test only
/// exercises search() and the folder tree with hand-built Books. That gap is
/// how a phantom-file bug survived: File.stat() does not throw on a file that
/// has vanished, it returns size -1, so a deleted file became a Book claiming
/// a negative size and sorted straight to the top of "largest first".
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('abr_scan'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File touch(String relative, {int bytes = 32}) {
    final file = File('${root.path}/$relative')
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 0x41));
    return file;
  }

  group('what counts as a book', () {
    test('picks up every supported format and ignores the rest', () async {
      touch('a.pdf');
      touch('b.epub');
      touch('c.txt');
      touch('d.md');
      touch('notes.docx');
      touch('cover.png');

      final books = await LibraryService.scan(root.path);
      expect(books.map((b) => b.title).toList()..sort(), ['a', 'b', 'c', 'd']);
    });

    test('skips macOS AppleDouble stubs', () async {
      touch('real.pdf');
      touch('._real.pdf');
      final books = await LibraryService.scan(root.path);
      expect(books.map((b) => b.title), ['real']);
    });

    test('matches extensions case-insensitively', () async {
      touch('shouty.PDF');
      final books = await LibraryService.scan(root.path);
      expect(books, hasLength(1));
    });

    test('recurses into nested folders', () async {
      touch('deep/deeper/deepest/found.pdf');
      final books = await LibraryService.scan(root.path);
      expect(books, hasLength(1));
      expect(books.single.path, contains('deepest'));
    });
  });

  group('phantom files', () {
    test('a file that vanishes mid-scan never becomes a book', () async {
      // The exact regression: stat() returns type notFound and size -1 rather
      // than throwing, so without an explicit check this yields a Book with
      // sizeBytes == -1 pointing at nothing.
      final doomed = touch('gone.pdf');
      touch('stays.pdf');

      final books = await LibraryService.scan(
        root.path,
        onProgress: (_) {
          if (doomed.existsSync()) doomed.deleteSync();
        },
      );

      expect(books.map((b) => b.title), isNot(contains('gone')));
      expect(books.every((b) => b.sizeBytes >= 0), isTrue,
          reason: 'no book may report a negative size');
    });

    test('every reported size is real', () async {
      touch('sized.pdf', bytes: 1234);
      final books = await LibraryService.scan(root.path);
      expect(books.single.sizeBytes, 1234);
    });
  });

  group('ordering', () {
    test('results are sorted by title, case-insensitively', () async {
      touch('zebra.pdf');
      touch('Apple.pdf');
      touch('mango.pdf');
      final books = await LibraryService.scan(root.path);
      expect(books.map((b) => b.title), ['Apple', 'mango', 'zebra']);
    });

    test('repeated scans of the same tree agree exactly', () async {
      // Parallel stat could otherwise let equal-titled entries swap places,
      // since Dart's sort is not stable.
      for (var i = 0; i < 40; i++) {
        touch('dir$i/same.pdf', bytes: 10 + i);
      }
      final first = await LibraryService.scan(root.path);
      final second = await LibraryService.scan(root.path);
      expect(first.map((b) => b.path).toList(),
          second.map((b) => b.path).toList());
      expect(first.map((b) => b.sizeBytes).toList(),
          second.map((b) => b.sizeBytes).toList());
    });

    test('each book keeps its own size under a parallel scan', () async {
      // Guards cross-wiring: a bounded map that assigned results by completion
      // order would attach the wrong size to the wrong file.
      for (var i = 0; i < 60; i++) {
        touch('b$i.pdf', bytes: 100 + i);
      }
      final books = await LibraryService.scan(root.path);
      for (final book in books) {
        final index = int.parse(book.title.substring(1));
        expect(book.sizeBytes, 100 + index, reason: book.title);
      }
    });
  });

  group('edge cases', () {
    test('an empty tree yields an empty list', () async {
      expect(await LibraryService.scan(root.path), isEmpty);
    });

    test('a missing root fails clearly rather than returning empty', () async {
      await expectLater(
        LibraryService.scan('${root.path}/does-not-exist'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
