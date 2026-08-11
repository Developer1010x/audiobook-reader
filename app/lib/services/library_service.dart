import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/book.dart';

/// Scans the configured library folder. Metadata only — the same rule the Python
/// version held to: files are read in place, never copied, never moved.
class LibraryService {
  /// Formats the app can open. PDFs render as pages; the rest are flowed text.
  static const supportedExtensions = {'pdf', 'txt', 'md', 'epub'};

  /// Every book under [root], sorted by title.
  ///
  /// Runs off the UI isolate: a deep folder (the real library has 613 PDFs across
  /// nested directories) would otherwise jank the first frame.
  static Future<List<Book>> scan(String root) async {
    final dir = Directory(root);
    if (!await dir.exists()) {
      throw FileSystemException('Library folder not found', root);
    }

    final books = <Book>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);

      // AppleDouble resource forks: "._Book.pdf" is a few KB of macOS metadata,
      // not a book. The real library has 185 of them against 428 actual PDFs.
      if (name.startsWith('._')) continue;

      final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
      if (!supportedExtensions.contains(ext)) continue;

      try {
        final stat = await entity.stat();
        books.add(Book(
          file: entity,
          title: p.basenameWithoutExtension(name),
          ext: ext,
          sizeBytes: stat.size,
        ));
      } on FileSystemException {
        continue; // unreadable file — skip rather than fail the whole scan
      }
    }

    books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return books;
  }

  /// Normalise separators so a search for "thousand brains" matches the real
  /// filename "A_thousand_brains-theory_of_intelligence".
  static String normalise(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), ' ').trim();

  static List<Book> search(List<Book> books, String query) {
    if (query.trim().isEmpty) return books;
    final q = normalise(query);
    return books.where((b) => normalise(b.title).contains(q)).toList();
  }
}
