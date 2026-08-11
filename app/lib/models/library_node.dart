import 'package:path/path.dart' as p;

import 'book.dart';

/// A folder in the library tree, holding its own books and subfolders.
///
/// The library is deeply nested (Core-CS/Programming/Languages/C++/…), so a flat
/// list of every book throws away the structure the user already organised by.
class LibraryFolder {
  final String name;
  final String path;
  final List<LibraryFolder> folders;
  final List<Book> books;

  LibraryFolder({
    required this.name,
    required this.path,
    List<LibraryFolder>? folders,
    List<Book>? books,
  })  : folders = folders ?? [],
        books = books ?? [];

  /// Books in this folder and everything under it.
  int get totalBooks =>
      books.length + folders.fold(0, (sum, f) => sum + f.totalBooks);

  bool get isEmpty => totalBooks == 0;

  /// Build a tree from a flat scan result, rooted at [rootPath].
  ///
  /// Folders containing no books at any depth are dropped — the library has
  /// plenty of directories holding only notes or code, and showing them as empty
  /// folders would be noise.
  static LibraryFolder build(List<Book> books, String rootPath) {
    final root = LibraryFolder(name: p.basename(rootPath), path: rootPath);

    for (final book in books) {
      final relative = p.relative(p.dirname(book.path), from: rootPath);
      final segments = relative == '.' ? <String>[] : p.split(relative);

      var current = root;
      var currentPath = rootPath;
      for (final segment in segments) {
        currentPath = p.join(currentPath, segment);
        final existing =
            current.folders.where((f) => f.name == segment).firstOrNull;
        if (existing != null) {
          current = existing;
        } else {
          final child = LibraryFolder(name: segment, path: currentPath);
          current.folders.add(child);
          current = child;
        }
      }
      current.books.add(book);
    }

    _sort(root);
    return root;
  }

  static void _sort(LibraryFolder folder) {
    folder.folders.removeWhere((f) => f.isEmpty);
    folder.folders.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    folder.books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    for (final child in folder.folders) {
      _sort(child);
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
