import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/book.dart';
import 'concurrency.dart';

/// A file that passed the name filters and is waiting on its size.
typedef _Candidate = ({File file, String title, String ext});

/// Scans the configured library folder. Metadata only — the same rule the Python
/// version held to: files are read in place, never copied, never moved.
class LibraryService {
  /// Formats the app can open. PDFs render as pages; the rest are flowed text.
  static const supportedExtensions = {'pdf', 'txt', 'md', 'epub'};

  /// Every book under [root], sorted by title.
  ///
  /// Two phases, because only one of them has to be sequential. The directory
  /// walk is a stream and is consumed in order; the per-file `stat` is not, and
  /// doing 784 of them one awaited syscall at a time is the bulk of the delay
  /// before the first frame can render. So the walk only collects candidates,
  /// and the stats go out [Concurrency.ioPool]-wide afterwards.
  ///
  /// [onProgress] reports the running count of candidates during the walk — the
  /// phase whose length is unknown up front — and then the final book count. The
  /// last value can be a shade lower than the previous one when a file turns out
  /// to be unreadable.
  static Future<List<Book>> scan(
    String root, {
    void Function(int found)? onProgress,
  }) async {
    final dir = Directory(root);
    if (!await dir.exists()) {
      throw FileSystemException('Library folder not found', root);
    }

    final candidates = <_Candidate>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);

      // AppleDouble resource forks: "._Book.pdf" is a few KB of macOS metadata,
      // not a book. The real library has 185 of them against 428 actual PDFs.
      if (name.startsWith('._')) continue;

      final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
      if (!supportedExtensions.contains(ext)) continue;

      candidates.add((
        file: entity,
        title: p.basenameWithoutExtension(name),
        ext: ext,
      ));
      onProgress?.call(candidates.length);
    }

    // Order-preserving deliberately, not incidentally: the sort below would mask
    // a completion-order shuffle, leaving books with equal titles to swap places
    // between runs depending on which stat happened to return first.
    final stated = await Concurrency.mapBounded<_Candidate, Book?>(
      candidates,
      (candidate, _) async {
        try {
          final stat = await candidate.file.stat();

          // `File.stat()` does not throw when the file is missing or
          // unreadable — it returns notFound with a size of -1. The catch below
          // is therefore not enough on its own, and it matters more here than
          // it did when the stat ran inline: the walk and the stat are now
          // separated by the whole traversal, so a file genuinely can be
          // deleted in between. Without this guard it becomes a Book of -1
          // bytes that sorts to the top of "Size" and opens onto nothing.
          if (stat.type == FileSystemEntityType.notFound) return null;

          return Book(
            file: candidate.file,
            title: candidate.title,
            ext: candidate.ext,
            sizeBytes: stat.size,
          );
        } on FileSystemException {
          return null; // unreadable file — skip rather than fail the whole scan
        }
      },
      concurrency: Concurrency.ioPool,
    );

    final books = stated.whereType<Book>().toList();
    books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    onProgress?.call(books.length);
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
