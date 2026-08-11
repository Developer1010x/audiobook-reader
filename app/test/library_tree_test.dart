import 'dart:io';

import 'package:audiobook_reader/models/book.dart';
import 'package:audiobook_reader/models/library_node.dart';
import 'package:audiobook_reader/services/library_service.dart';
import 'package:flutter_test/flutter_test.dart';

Book book(String path) => Book(
      file: File(path),
      title: path.split('/').last.replaceAll('.pdf', ''),
      ext: 'pdf',
      sizeBytes: 1024,
    );

void main() {
  const root = '/lib';

  group('folder tree', () {
    test('nests books by their real directory structure', () {
      final tree = LibraryFolder.build([
        book('/lib/Core-CS/Programming/C++/tour.pdf'),
        book('/lib/Core-CS/Programming/C++/effective.pdf'),
        book('/lib/Career/resume.pdf'),
        book('/lib/loose.pdf'),
      ], root);

      expect(tree.books.map((b) => b.title), ['loose']);
      expect(tree.folders.map((f) => f.name), ['Career', 'Core-CS']);

      final cs = tree.folders.firstWhere((f) => f.name == 'Core-CS');
      final cpp = cs.folders.single.folders.single;
      expect(cpp.name, 'C++');
      expect(cpp.books, hasLength(2));
    });

    test('totalBooks counts everything underneath, not just direct children', () {
      final tree = LibraryFolder.build([
        book('/lib/a/deep/one.pdf'),
        book('/lib/a/two.pdf'),
        book('/lib/b/three.pdf'),
      ], root);

      expect(tree.totalBooks, 3);
      expect(tree.folders.firstWhere((f) => f.name == 'a').totalBooks, 2);
    });

    test('folders are sorted case-insensitively, as are books', () {
      final tree = LibraryFolder.build([
        book('/lib/zebra/b.pdf'),
        book('/lib/Apple/a.pdf'),
        book('/lib/zebra/A.pdf'),
      ], root);

      expect(tree.folders.map((f) => f.name), ['Apple', 'zebra']);
      final zebra = tree.folders.firstWhere((f) => f.name == 'zebra');
      expect(zebra.books.map((b) => b.title), ['A', 'b']);
    });

    test('an empty library produces an empty tree rather than throwing', () {
      final tree = LibraryFolder.build([], root);
      expect(tree.isEmpty, isTrue);
      expect(tree.totalBooks, 0);
    });

    test('books at the root are not lost', () {
      final tree = LibraryFolder.build([book('/lib/only.pdf')], root);
      expect(tree.books, hasLength(1));
      expect(tree.folders, isEmpty);
    });
  });

  group('search', () {
    final books = [
      book('/lib/A_thousand_brains-theory_of_intelligence.pdf'),
      book('/lib/x/A Tour of C++.pdf'),
    ];

    test('matches across separator styles', () {
      // The filename uses underscores and hyphens; the user types spaces.
      expect(LibraryService.search(books, 'thousand brains'), hasLength(1));
      expect(LibraryService.search(books, 'theory of intelligence'), hasLength(1));
    });

    test('is case-insensitive', () {
      expect(LibraryService.search(books, 'TOUR OF C++'), hasLength(1));
    });

    test('an empty query returns everything', () {
      expect(LibraryService.search(books, ''), hasLength(2));
      expect(LibraryService.search(books, '   '), hasLength(2));
    });

    test('no match returns empty rather than everything', () {
      expect(LibraryService.search(books, 'nonexistent'), isEmpty);
    });
  });
}
