import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:audiobook_reader/models/book.dart';
import 'package:audiobook_reader/services/text_document.dart';
import 'package:flutter_test/flutter_test.dart';

Book bookFor(File file, String ext) => Book(
      file: file,
      title: 'test',
      ext: ext,
      sizeBytes: file.lengthSync(),
    );

/// Build a minimal but structurally real EPUB: container.xml → OPF → spine.
File writeEpub(Directory dir, {required List<(String title, String body)> chapters}) {
  final archive = Archive();

  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.add(ArchiveFile(name, bytes.length, bytes));
  }

  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');

  final manifest = StringBuffer();
  final spine = StringBuffer();
  for (var i = 0; i < chapters.length; i++) {
    manifest.writeln('<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>');
    spine.writeln('<itemref idref="c$i"/>');
    add('OEBPS/c$i.xhtml', '''
<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>${chapters[i].$1}</title>
<style>body { color: red; }</style></head>
<body><h1>${chapters[i].$1}</h1><p>${chapters[i].$2}</p>
<script>var noise = "should not be read";</script></body></html>''');
  }

  add('OEBPS/content.opf', '''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
  <metadata/>
  <manifest>$manifest</manifest>
  <spine>$spine</spine>
</package>''');

  final file = File('${dir.path}/test.epub')
    ..writeAsBytesSync(ZipEncoder().encode(archive)!);
  return file;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('abr_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('format support', () {
    test('handles the text formats and leaves PDF to the PDF reader', () {
      expect(TextDocument.handles('txt'), isTrue);
      expect(TextDocument.handles('md'), isTrue);
      expect(TextDocument.handles('epub'), isTrue);
      expect(TextDocument.handles('pdf'), isFalse);
    });
  });

  group('plain text', () {
    test('reads a txt file into at least one page', () async {
      final file = File('${tmp.path}/a.txt')
        ..writeAsStringSync('Hello there.\n\nSecond paragraph.');
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pageCount, greaterThanOrEqualTo(1));
      expect(doc.pages.first.text, contains('Hello there.'));
      expect(doc.pages.map((p) => p.text).join(), contains('Second paragraph.'));
    });

    test('paginates long text across multiple pages', () async {
      final paragraph = '${'word ' * 60}\n\n';
      final file = File('${tmp.path}/long.txt')
        ..writeAsStringSync(paragraph * 30);
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pageCount, greaterThan(1));
    });

    test('page numbers are sequential from 1', () async {
      final file = File('${tmp.path}/n.txt')
        ..writeAsStringSync(('${'x' * 500}\n\n') * 12);
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pages.first.number, 1);
      for (var i = 0; i < doc.pageCount; i++) {
        expect(doc.pages[i].number, i + 1);
      }
    });

    test('a file with no blank lines still yields a page', () async {
      final file = File('${tmp.path}/one.txt')..writeAsStringSync('Just one line');
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pageCount, 1);
      expect(doc.pages.first.text, 'Just one line');
    });

    test('non-UTF8 bytes fall back to latin-1 instead of throwing', () async {
      // 0xE9 is 'é' in Latin-1 but invalid alone in UTF-8.
      final file = File('${tmp.path}/latin.txt')
        ..writeAsBytesSync([...utf8.encode('caf'), 0xE9]);
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pages.first.text, 'café');
    });

    test('an empty file produces no pages rather than crashing', () async {
      final file = File('${tmp.path}/empty.txt')..writeAsStringSync('');
      final doc = await TextDocument.open(bookFor(file, 'txt'));
      expect(doc.pages, isEmpty);
    });
  });

  group('epub', () {
    test('reads chapters in spine order', () async {
      final file = writeEpub(tmp, chapters: [
        ('Chapter One', 'The first chapter body.'),
        ('Chapter Two', 'The second chapter body.'),
      ]);
      final doc = await TextDocument.open(bookFor(file, 'epub'));

      final all = doc.pages.map((p) => p.text).join('\n');
      expect(all, contains('The first chapter body.'));
      expect(all, contains('The second chapter body.'));
      expect(all.indexOf('first chapter'), lessThan(all.indexOf('second chapter')));
    });

    test('exposes chapter titles with their starting pages', () async {
      final file = writeEpub(tmp, chapters: [
        ('Chapter One', 'Body one.'),
        ('Chapter Two', 'Body two.'),
      ]);
      final doc = await TextDocument.open(bookFor(file, 'epub'));
      expect(doc.chapters, hasLength(2));
      expect(doc.chapters.first.title, 'Chapter One');
      expect(doc.chapters.first.firstPage, 1);
      expect(doc.chapters.last.firstPage, greaterThanOrEqualTo(1));
    });

    test('strips script and style content, which is not readable text', () async {
      final file = writeEpub(tmp, chapters: [('T', 'Real body text.')]);
      final doc = await TextDocument.open(bookFor(file, 'epub'));
      final all = doc.pages.map((p) => p.text).join();
      expect(all, contains('Real body text.'));
      expect(all, isNot(contains('should not be read')));
      expect(all, isNot(contains('color: red')));
    });

    test('a non-EPUB file fails with a clear message', () async {
      final file = File('${tmp.path}/fake.epub')..writeAsStringSync('not a zip');
      await expectLater(
        TextDocument.open(bookFor(file, 'epub')),
        throwsA(isA<Exception>()),
      );
    });

    test('an EPUB with no readable text is rejected, not silently empty', () async {
      final file = writeEpub(tmp, chapters: []);
      await expectLater(
        TextDocument.open(bookFor(file, 'epub')),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
