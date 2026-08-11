import 'dart:io';
import 'dart:ui' show ImageByteFormat;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';

/// Optical character recognition for scanned pages.
///
/// A large share of the library is scanned — the page is an image, so PDF text
/// extraction returns nothing and both read-aloud and summarising have nothing
/// to work with. OCR fills that gap by rasterising the page and running
/// Tesseract over it.
///
/// **Desktop only for now.** Tesseract is invoked as a subprocess, which works
/// on Linux, macOS and Windows but not on iOS or Android — those need an
/// in-process engine (ML Kit) that is not wired up yet. [isAvailable] reports
/// this honestly rather than failing at the point of use.
///
/// Results are cached to disk: OCR of a single page takes seconds, and a reader
/// revisits pages constantly.
class OcrService {
  /// Rendering width in pixels. Tesseract wants roughly 300 DPI to be accurate;
  /// at typical page proportions this lands in that range. Lower is much faster
  /// but noticeably worse on small print.
  static const _renderWidth = 2000;

  static Directory? _cacheDir;
  static bool? _available;

  static Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'ocr'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  static bool get isSupportedPlatform =>
      Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  /// Whether OCR can actually run here — the platform supports it *and* the
  /// tesseract binary exists.
  static Future<bool> isAvailable() async {
    if (!isSupportedPlatform) return false;
    if (_available != null) return _available!;
    try {
      final result = await Process.run('tesseract', ['--version']);
      return _available = result.exitCode == 0;
    } catch (_) {
      return _available = false;
    }
  }

  static String get unavailableMessage => isSupportedPlatform
      ? 'This page is a scan and needs OCR. Install it with:\n'
          '    sudo apt install tesseract-ocr'
      : 'This page is a scan. OCR is not available on this platform yet.';

  static String _key(Book book, int page) =>
      '${sha256.convert(book.path.codeUnits).toString().substring(0, 16)}_p$page';

  /// Cached OCR text for this page, or null if it has not been run.
  static Future<String?> cached(Book book, int page) async {
    final file = File(p.join((await _dir()).path, '${_key(book, page)}.txt'));
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// OCR a single page, returning the recognised text.
  ///
  /// [onProgress] reports a human-readable stage, since this is slow enough
  /// that the UI must say what is happening.
  static Future<String> recognisePage(
    Book book,
    int page, {
    void Function(String stage)? onProgress,
  }) async {
    final hit = await cached(book, page);
    if (hit != null) return hit;

    if (!await isAvailable()) throw OcrException(unavailableMessage);

    onProgress?.call('Rendering page $page…');
    final dir = await _dir();
    final imageFile = File(p.join(dir.path, '${_key(book, page)}.png'));

    final doc = await PdfDocument.openFile(book.path);
    try {
      if (page < 1 || page > doc.pages.length) {
        throw OcrException('Page $page is out of range.');
      }
      final pdfPage = doc.pages[page - 1];
      final height = (_renderWidth * pdfPage.height / pdfPage.width).round();
      final rendered = await pdfPage.render(
        fullWidth: _renderWidth.toDouble(),
        fullHeight: height.toDouble(),
      );
      if (rendered == null) throw OcrException('Could not render page $page.');
      try {
        final image = await rendered.createImage();
        final png = await image.toByteData(format: ImageByteFormat.png);
        image.dispose();
        if (png == null) throw OcrException('Could not encode page $page.');
        await imageFile.writeAsBytes(png.buffer.asUint8List(), flush: true);
      } finally {
        rendered.dispose();
      }
    } finally {
      doc.dispose();
    }

    onProgress?.call('Reading text from page $page…');
    // Tesseract appends .txt to the output base itself.
    final outBase = p.join(dir.path, _key(book, page));
    final result = await Process.run('tesseract', [imageFile.path, outBase]);

    // The rendered PNG is large and only needed as OCR input; the text is what
    // gets cached.
    try {
      await imageFile.delete();
    } catch (_) {}

    if (result.exitCode != 0) {
      throw OcrException('Tesseract failed: ${result.stderr}');
    }

    final textFile = File('$outBase.txt');
    if (!await textFile.exists()) {
      throw OcrException('Tesseract produced no output for page $page.');
    }
    return textFile.readAsString();
  }

  /// Drop every cached OCR result.
  static Future<void> clear() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _cacheDir = null;
  }
}

class OcrException implements Exception {
  final String message;
  const OcrException(this.message);
  @override
  String toString() => message;
}
