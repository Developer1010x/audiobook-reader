import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';
import 'concurrency.dart';

/// Renders and caches a small cover image from each book's first page.
///
/// A grid of 428 identical file icons is unreadable; a grid of covers is
/// scannable at a glance. Covers are written to the app cache directory — never
/// into the library, which stays read-only.
class CoverService {
  static Directory? _cacheDir;

  /// In-flight and completed renders, so a rebuilding grid does not re-render
  /// the same cover repeatedly while scrolling.
  static final Map<String, Future<File?>> _pending = {};

  /// Renders that have been asked for but have no slot yet.
  ///
  /// Each render opens a `PdfDocument` and holds a decoded bitmap while it
  /// encodes; letting a fast scroll through a large library start all of them
  /// at once spikes memory and stutters the very grid the covers are for.
  static final Queue<_CoverJob> _queue = ListQueue<_CoverJob>();

  static int _active = 0;

  /// Deliberately far below the CPU pool: this is background decoration, and it
  /// must never compete with the book in front of the user.
  static const _renderSlots = 2;

  static Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  /// Filename keyed by the book's path. A content hash would mean opening the
  /// file to compute it, which is the work we are trying to avoid.
  static String _key(Book book) =>
      sha256.convert(book.path.codeUnits).toString().substring(0, 16);

  /// The cover for [book], rendering it on first request. Returns null when the
  /// PDF cannot be opened — the caller falls back to an icon.
  ///
  /// The render is queued behind at most [Concurrency.cpuPool] others, so the
  /// returned future may sit pending for a while on a busy grid.
  static Future<File?> cover(Book book, {int width = 200}) {
    return _pending.putIfAbsent(book.id, () => _enqueue(book, width));
  }

  /// Warm the cache for the first [limit] books so scrolling finds them ready.
  ///
  /// Best-effort by definition: it never throws, and a book that fails here is
  /// simply retried on demand. Pass the [width] the grid actually uses — the
  /// cache is keyed by book rather than by size, so whichever request lands
  /// first fixes the resolution for the rest.
  static Future<void> prefetch(
    List<Book> books, {
    int limit = 24,
    int width = 200,
  }) async {
    if (books.isEmpty || limit <= 0) return;
    final head = books.take(limit).toList(growable: false);
    try {
      await Concurrency.mapBoundedLenient<Book, bool>(
        head,
        (book, _) async {
          await cover(book, width: width);
          return true;
        },
        concurrency: Concurrency.cpuPool,
      );
    } catch (_) {
      // Warming a cache is never worth surfacing an error for.
    }
  }

  /// Drop every render that has not started yet; ones already running finish.
  ///
  /// For navigating away from the library, where a deep queue would otherwise
  /// keep grinding behind whatever screen the user moved to.
  ///
  /// Cancelled books are evicted from the memo table rather than left memoised
  /// as null, so coming back to the grid renders them instead of showing icons
  /// for the rest of the session.
  static void cancelPending() {
    final cancelled = _queue.toList(growable: false);
    _queue.clear();
    for (final job in cancelled) {
      _pending.remove(job.id);
      if (!job.completer.isCompleted) job.completer.complete(null);
    }
  }

  static Future<File?> _enqueue(Book book, int width) {
    final job = _CoverJob(book.id, book, width);
    _queue.addLast(job);
    _pump();
    return job.completer.future;
  }

  /// Fill the pool from the queue, newest request first.
  ///
  /// While the user flings through the grid the covers under their thumb now
  /// matter more than the ones they have already scrolled past; those keep
  /// their slot in the queue and are picked up once the burst settles.
  static void _pump() {
    // Two, not cpuPool. Each render opens and parses a whole PDF; six at once
    // on 20 MB books starved the document the user was actually trying to open,
    // turning a 0.04 s parse into a 16-second wait.
    while (_active < _renderSlots && _queue.isNotEmpty) {
      _active++;
      unawaited(_run(_queue.removeLast()));
    }
  }

  static Future<void> _run(_CoverJob job) async {
    File? file;
    try {
      file = await _render(job.book, job.width);
    } catch (_) {
      file = null;
    } finally {
      _active--;
    }
    if (!job.completer.isCompleted) job.completer.complete(file);
    _pump();
  }

  /// Serial number for scratch files, so two renders of the same book — which
  /// [clear] can produce by dropping the memo entry while a render is still
  /// running — cannot write to the same temp path.
  static int _tmpSeq = 0;

  /// Write [bytes] to [file] via a temp file and a rename.
  ///
  /// A direct `writeAsBytes` that fails or is killed part-way leaves a
  /// truncated PNG behind, and the `exists && length > 0` check treats that as
  /// a good cover forever after — a book whose cover never comes back, even
  /// across restarts. The rename is atomic, so the cache only ever holds whole
  /// files.
  static Future<File?> _writeAtomically(File file, Uint8List bytes) async {
    final tmp = File('${file.path}.${_tmpSeq++}.tmp');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      // A zero-length leftover from an older truncated write would make rename
      // fail on Windows, where the destination must not exist.
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
      return file;
    } catch (_) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {
        // Nothing left to do; a stray temp file is cleared with the cache.
      }
      return null;
    }
  }

  static Future<File?> _render(Book book, int width) async {
    try {
      final dir = await _dir();
      final file = File(p.join(dir.path, '${_key(book)}.png'));
      if (await file.exists() && await file.length() > 0) return file;

      final doc = await PdfDocument.openFile(book.path);
      try {
        if (doc.pages.isEmpty) return null;
        final page = doc.pages.first;
        final height = (width * page.height / page.width).round();
        final image = await page.render(
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
        );
        if (image == null) return null;
        try {
          final ui = await image.createImage();
          final ByteData? png;
          try {
            png = await ui.toByteData(format: ImageByteFormat.png);
          } finally {
            // Encoding can throw on a huge page; the decoded bitmap has to go
            // back either way or the native allocation outlives the render.
            ui.dispose();
          }
          if (png == null) return null;
          return await _writeAtomically(file, png.buffer.asUint8List());
        } finally {
          image.dispose();
        }
      } finally {
        doc.dispose();
      }
    } catch (_) {
      // A broken or encrypted PDF should degrade to an icon, not crash the grid.
      return null;
    }
  }

  /// Drop every cached cover. Exposed for a settings action.
  static Future<void> clear() async {
    cancelPending();
    _pending.clear();
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _cacheDir = null;
  }
}

/// One queued render, holding the completer handed back to every caller that
/// asked for this book while it waited.
class _CoverJob {
  _CoverJob(this.id, this.book, this.width);

  final String id;
  final Book book;
  final int width;
  final completer = Completer<File?>();
}

/// Re-exported so callers do not need dart:ui directly.
typedef ImageBytes = Uint8List;
