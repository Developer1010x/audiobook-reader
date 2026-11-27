import 'dart:io';

import 'package:audiobook_reader/services/library_watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('isRelevant', () {
    test('book formats and folders count', () {
      expect(LibraryWatcher.isRelevant('/l/a.PDF', isDirectory: false), isTrue);
      expect(LibraryWatcher.isRelevant('/l/a.epub', isDirectory: false), isTrue);
      expect(LibraryWatcher.isRelevant('/l/Series', isDirectory: true), isTrue);
    });

    test('partial downloads, other files and dotfiles do not', () {
      expect(LibraryWatcher.isRelevant('/l/a.pdf.part', isDirectory: false),
          isFalse);
      expect(LibraryWatcher.isRelevant('/l/cover.jpg', isDirectory: false),
          isFalse);
      expect(LibraryWatcher.isRelevant('/l/._a.pdf', isDirectory: false),
          isFalse);
      expect(LibraryWatcher.isRelevant('/l/.DS_Store', isDirectory: false),
          isFalse);
    });
  });

  group('watching a real folder', () {
    late Directory root;
    late LibraryWatcher watcher;
    var calls = 0;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('audier_watch_');
      // Created before start(), so Linux's per-directory watch must find it.
      await Directory(p.join(root.path, 'sub')).create();
      calls = 0;
      watcher = LibraryWatcher(root.path,
          onChanged: () => calls++,
          debounce: const Duration(milliseconds: 200));
      await watcher.start();
    });

    tearDown(() async {
      await watcher.close();
      await root.delete(recursive: true);
    });

    Future<void> settle() => Future<void>.delayed(const Duration(seconds: 1));

    test('a burst of book writes in a subfolder costs one rescan', () async {
      for (var i = 0; i < 5; i++) {
        await File(p.join(root.path, 'sub', 'b$i.pdf')).writeAsString('x');
      }
      await settle();
      expect(calls, 1);
    });

    test('a finished download renamed to .pdf counts', () async {
      final part = File(p.join(root.path, 'book.pdf.part'));
      await part.writeAsString('x');
      await settle();
      expect(calls, 0, reason: 'the partial file is not a book yet');
      await part.rename(p.join(root.path, 'book.pdf'));
      await settle();
      expect(calls, 1);
    });

    test('non-book files never trigger a rescan', () async {
      await File(p.join(root.path, 'notes.jpg')).writeAsString('x');
      await settle();
      expect(calls, 0);
    });

    test('nothing fires after close', () async {
      await watcher.close();
      await File(p.join(root.path, 'late.pdf')).writeAsString('x');
      await settle();
      expect(calls, 0);
    });
  });
}
