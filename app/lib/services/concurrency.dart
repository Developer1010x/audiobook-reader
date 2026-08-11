import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Shared parallelism primitives.
///
/// Two distinct problems, often confused:
///
/// **Concurrency** is for work that *waits* — reading files, HTTP calls,
/// subprocesses. Dart's single thread handles many of these at once happily,
/// but unbounded fan-out is its own bug: 784 simultaneous `stat` calls or 40
/// parallel Tesseract processes will thrash a machine harder than doing them in
/// sequence. Hence [mapBounded].
///
/// **Parallelism** is for work that *computes* — classification scoring, EPUB
/// parsing, JSON encoding. Awaiting does not help there; the UI thread is
/// simply busy, and the app janks. That work belongs on another isolate, hence
/// [runOffThread].
class Concurrency {
  /// Cores available, leaving headroom for the UI isolate and the OS.
  static int get cores => Platform.numberOfProcessors;

  /// Sensible pool size for CPU-bound subprocess work (OCR, synthesis).
  ///
  /// Saturating every core makes the interface stutter while the user is still
  /// trying to read, which defeats the point.
  static int get cpuPool => max(1, min(cores - 2, 6));

  /// Sensible pool size for IO-bound work (file stats, page reads).
  ///
  /// Higher than [cpuPool] because these mostly wait rather than compute.
  static int get ioPool => max(2, min(cores * 2, 16));

  /// Run [worker] over [items] with at most [concurrency] in flight,
  /// **preserving input order** in the result.
  ///
  /// Order matters more than it looks: pages, chunks and sentences are all
  /// ordered, and a result list shuffled by completion time would silently
  /// scramble a book.
  static Future<List<R>> mapBounded<T, R>(
    List<T> items,
    Future<R> Function(T item, int index) worker, {
    int? concurrency,
    bool Function()? isCancelled,
  }) async {
    if (items.isEmpty) return <R>[];
    final limit = max(1, min(concurrency ?? ioPool, items.length));

    final results = List<R?>.filled(items.length, null);
    var next = 0;

    Future<void> drain() async {
      while (true) {
        if (isCancelled?.call() ?? false) return;
        final index = next++;
        if (index >= items.length) return;
        results[index] = await worker(items[index], index);
      }
    }

    await Future.wait(List.generate(limit, (_) => drain()));
    return results.cast<R>();
  }

  /// Like [mapBounded], but drops items whose worker threw.
  ///
  /// For best-effort passes — one unreadable page should not fail a whole
  /// chapter.
  static Future<List<R>> mapBoundedLenient<T, R>(
    List<T> items,
    Future<R> Function(T item, int index) worker, {
    int? concurrency,
    bool Function()? isCancelled,
  }) async {
    final results = await mapBounded<T, R?>(
      items,
      (item, index) async {
        try {
          return await worker(item, index);
        } catch (_) {
          return null;
        }
      },
      concurrency: concurrency,
      isCancelled: isCancelled,
    );
    return results.whereType<R>().toList();
  }

  /// Run a pure, CPU-bound function on another isolate.
  ///
  /// Use for anything that would otherwise block a frame: parsing, scoring,
  /// large string work, JSON of any size. The argument and result must be
  /// sendable — plain data, not handles or closures over widgets.
  ///
  /// Falls back to running inline in debug-less environments where spawning is
  /// unavailable (some test harnesses), so callers never need a second path.
  static Future<R> runOffThread<M, R>(
    ComputeCallback<M, R> callback,
    M message, {
    String? debugLabel,
  }) async {
    try {
      return await compute(callback, message, debugLabel: debugLabel);
    } catch (_) {
      return callback(message);
    }
  }

  /// Only move work off-thread when it is big enough to be worth the copy.
  ///
  /// Isolate hand-off costs a serialisation of the payload both ways; for a
  /// short string that is more expensive than just doing the work.
  static const offThreadThresholdChars = 20000;

  static bool worthOffloading(int chars) => chars >= offThreadThresholdChars;
}
