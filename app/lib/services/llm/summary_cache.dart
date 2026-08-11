import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ai_mode.dart';
import 'summary_length.dart';

/// Disk cache for completed summaries.
///
/// Re-opening a summary you already generated should be instant and free. The
/// key covers everything that changes the answer — the source text itself, the
/// mode, the length, the provider and the model — so changing any of them
/// correctly misses rather than serving a stale answer for different settings.
class SummaryCache {
  static Directory? _dir;

  /// Bound on stored entries; oldest are evicted first.
  static const _maxEntries = 300;

  static Future<Directory> _directory() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'summaries'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Hashing the *text* rather than the page range means an OCR correction or a
  /// different page selection that yields the same content still hits.
  static String key({
    required String text,
    required AiMode mode,
    required SummaryLength length,
    required String provider,
    required String model,
  }) {
    final material = [
      sha256.convert(utf8.encode(text)).toString(),
      mode.name,
      length.name,
      provider,
      model,
    ].join('|');
    return sha256.convert(utf8.encode(material)).toString().substring(0, 32);
  }

  static Future<String?> get(String key) async {
    try {
      final file = File(p.join((await _directory()).path, '$key.json'));
      if (!await file.exists()) return null;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      // Touch on read so eviction is least-recently-*used*, not just oldest.
      await file.setLastModified(DateTime.now());
      return data['result'] as String?;
    } catch (_) {
      return null; // a corrupt entry is a miss, never a crash
    }
  }

  static Future<void> put(String key, String result,
      {Map<String, dynamic>? meta}) async {
    try {
      final dir = await _directory();
      final file = File(p.join(dir.path, '$key.json'));
      await file.writeAsString(jsonEncode({
        'result': result,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
        if (meta != null) 'meta': meta,
      }));
      await _evict(dir);
    } catch (_) {
      // Caching is an optimisation; failing to write must not fail the summary.
    }
  }

  static Future<void> _evict(Directory dir) async {
    final files = (await dir.list().toList()).whereType<File>().toList();
    if (files.length <= _maxEntries) return;
    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    for (final file in files.take(files.length - _maxEntries)) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  static Future<int> count() async {
    try {
      return (await (await _directory()).list().toList()).whereType<File>().length;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> clear() async {
    try {
      final dir = await _directory();
      if (await dir.exists()) await dir.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }
}
