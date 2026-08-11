import 'dart:async';

import 'package:pdfrx/pdfrx.dart';

import '../models/book.dart';

/// Keeps a small number of PDFs open, so the same book is parsed once.
///
/// **The bug this fixes.** Every ReaderService call used to open the document,
/// do its work, and dispose it. Entering a book runs several of those — classify
/// samples five pages, the sentence map loads a page, the viewer opens its own
/// handle — and each open re-parses the cross-reference table. On a 20 MB,
/// 1151-page PDF that turned a 0.04 s parse into a 16-second wait, which reads
/// to the user as "books are not loading".
///
/// Ref-counted rather than a plain LRU: several callers hold the same document
/// concurrently, and disposing under one of them crashes the other. A document
/// is only closed once nobody holds it *and* it has aged out.
class DocumentCache {
  DocumentCache._();

  /// How many idle documents to keep parsed. Two covers the common case —
  /// the book being read, plus the one just left — without holding a lot of
  /// memory on a large library.
  static const _maxIdle = 2;

  static final Map<String, _Entry> _open = {};

  /// Borrow the document for [book] and run [action] with it.
  ///
  /// The handle must never escape [action]: once the borrow returns, the cache
  /// is free to close it.
  static Future<T> use<T>(
    Book book,
    Future<T> Function(PdfDocument doc) action,
  ) async {
    final entry = await _acquire(book.path);
    try {
      return await action(entry.document);
    } finally {
      _release(book.path);
    }
  }

  /// Borrow the document for [book]. Every call MUST be balanced by
  /// [returnHandle], normally in a `finally`.
  ///
  /// Mirrors the shape of openFile/dispose so existing call sites change by two
  /// lines rather than being restructured.
  static Future<PdfDocument> borrow(Book book) async =>
      (await _acquire(book.path)).document;

  static void returnHandle(Book book) => _release(book.path);

  static Future<_Entry> _acquire(String path) async {
    final existing = _open[path];
    if (existing != null) {
      existing.holders++;
      existing.lastUsed = DateTime.now();
      return existing;
    }

    // Register the pending open before awaiting, so two simultaneous callers
    // share one parse instead of racing into two.
    final pending = PdfDocument.openFile(path);
    final entry = _Entry(pending);
    _open[path] = entry;

    try {
      entry.document = await pending;
    } catch (_) {
      _open.remove(path);
      rethrow;
    }
    entry.holders++;
    return entry;
  }

  static void _release(String path) {
    final entry = _open[path];
    if (entry == null) return;
    entry.holders--;
    entry.lastUsed = DateTime.now();
    if (entry.holders <= 0) _trim();
  }

  /// Close the oldest idle documents beyond the keep-alive limit.
  static void _trim() {
    final idle = _open.entries.where((e) => e.value.holders <= 0).toList()
      ..sort((a, b) => a.value.lastUsed.compareTo(b.value.lastUsed));

    final excess = idle.length - _maxIdle;
    for (var i = 0; i < excess; i++) {
      final entry = idle[i];
      _open.remove(entry.key);
      entry.value.dispose();
    }
  }

  /// Drop [book] from the cache once nobody is using it.
  ///
  /// Called when a reader closes, so leaving a book actually frees its memory
  /// rather than waiting for two more books to be opened.
  static void release(Book book) {
    final entry = _open[book.path];
    if (entry == null || entry.holders > 0) return;
    _open.remove(book.path);
    entry.dispose();
  }

  /// Close everything not currently borrowed.
  static void evictIdle() {
    for (final key in _open.keys.toList()) {
      final entry = _open[key]!;
      if (entry.holders > 0) continue;
      _open.remove(key);
      entry.dispose();
    }
  }

  static int get openCount => _open.length;
}

class _Entry {
  _Entry(this._pending) : lastUsed = DateTime.now();

  // ignore: unused_field
  final Future<PdfDocument> _pending;

  late PdfDocument document;
  int holders = 0;
  DateTime lastUsed;

  void dispose() {
    try {
      document.dispose();
    } catch (_) {
      // Already disposed, or never finished opening — either way there is
      // nothing left to release.
    }
  }
}
