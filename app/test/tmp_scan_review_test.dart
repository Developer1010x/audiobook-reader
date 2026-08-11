import 'dart:io';

import 'package:audiobook_reader/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('scanreview');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  File touch(String rel, {int bytes = 3}) {
    final f = File('${root.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List.filled(bytes, 65));
    return f;
  }

  test('filters, sizes and sort order', () async {
    touch('a/Zebra.pdf', bytes: 10);
    touch('a/apple.PDF', bytes: 20);
    touch('b/notes.md', bytes: 5);
    touch('b/._Zebra.pdf', bytes: 1); // AppleDouble
    touch('b/cover.png', bytes: 1); // unsupported
    touch('deep/x/y/z/thing.epub', bytes: 7);
    touch('t.txt', bytes: 2);

    final books = await LibraryService.scan(root.path);
    expect(books.map((b) => b.title).toList(),
        ['apple', 'notes', 't', 'thing', 'Zebra']);
    expect(books.firstWhere((b) => b.title == 'Zebra').sizeBytes, 10);
    expect(books.firstWhere((b) => b.title == 'apple').sizeBytes, 20);
    expect(books.firstWhere((b) => b.title == 'apple').ext, 'pdf');
    expect(books.every((b) => b.sizeBytes > 0), isTrue);
  });

  test('duplicate titles keep a stable, walk-ordered relative order', () async {
    // 60 files, all the same title, in directories that walk in a known order.
    for (var i = 0; i < 60; i++) {
      touch('d${i.toString().padLeft(3, '0')}/same.pdf', bytes: i + 1);
    }
    final first = await LibraryService.scan(root.path);
    for (var run = 0; run < 6; run++) {
      final again = await LibraryService.scan(root.path);
      expect(again.map((b) => b.path).toList(),
          first.map((b) => b.path).toList(),
          reason: 'run $run diverged from run 0');
      expect(again.map((b) => b.sizeBytes).toList(),
          first.map((b) => b.sizeBytes).toList());
    }
  });

  test('each book keeps its own size (no cross-wiring under concurrency)',
      () async {
    for (var i = 1; i <= 200; i++) {
      touch('f/b$i.pdf', bytes: i);
    }
    final books = await LibraryService.scan(root.path);
    expect(books, hasLength(200));
    for (final b in books) {
      final expected = int.parse(b.title.substring(1));
      expect(b.sizeBytes, expected, reason: b.path);
    }
  });

  test('unreadable file does not fail the scan', () async {
    touch('ok.pdf', bytes: 4);
    final bad = touch('bad.pdf', bytes: 4);
    await Process.run('chmod', ['000', bad.parent.path]);
    try {
      final books = await LibraryService.scan(root.path);
      // Either it is skipped or stat still works; must not throw.
      expect(books.map((b) => b.title), contains('ok'));
      for (final b in books) {
        expect(b.sizeBytes, greaterThanOrEqualTo(0),
            reason: 'negative size leaked from a notFound stat: ${b.path}');
      }
    } finally {
      await Process.run('chmod', ['755', bad.parent.path]);
    }
  });

  test('deleted-between-walk-and-stat does not produce a bogus book', () async {
    touch('gone.pdf', bytes: 9);
    touch('stays.pdf', bytes: 9);
    final f = File('${root.path}/gone.pdf');
    // Race the walk: delete as soon as the first candidate is reported.
    final books = await LibraryService.scan(root.path, onProgress: (n) {
      if (f.existsSync()) f.deleteSync();
    });
    for (final b in books) {
      expect(b.sizeBytes, greaterThanOrEqualTo(0),
          reason: 'stat of a vanished file yielded ${b.sizeBytes}: ${b.path}');
    }
  });

  test('symlinks are not followed and not listed as books', () async {
    touch('real/one.pdf', bytes: 6);
    Link('${root.path}/link').createSync('${root.path}/real');
    final books = await LibraryService.scan(root.path);
    expect(books, hasLength(1));
  });

  test('empty tree returns empty; missing root throws', () async {
    expect(await LibraryService.scan(root.path), isEmpty);
    expect(() => LibraryService.scan('${root.path}/nope'),
        throwsA(isA<FileSystemException>()));
  });

  test('onProgress is monotonic and ends at the book count', () async {
    for (var i = 0; i < 25; i++) {
      touch('p/b$i.pdf');
    }
    final seen = <int>[];
    final books = await LibraryService.scan(root.path, onProgress: seen.add);
    expect(seen.last, books.length);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]),
          reason: 'progress went backwards: $seen');
    }
  });
}
