import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';

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
  static Future<File?> cover(Book book, {int width = 200}) {
    return _pending.putIfAbsent(book.id, () => _render(book, width));
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
          final png = await ui.toByteData(format: ImageByteFormat.png);
          ui.dispose();
          if (png == null) return null;
          await file.writeAsBytes(png.buffer.asUint8List(), flush: true);
          return file;
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
    _pending.clear();
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _cacheDir = null;
  }
}

/// Re-exported so callers do not need dart:ui directly.
typedef ImageBytes = Uint8List;
