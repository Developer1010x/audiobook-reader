import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'runtime_env.dart';

/// One sense of a word.
class Sense {
  const Sense({
    required this.partOfSpeech,
    required this.definition,
    this.example,
    this.synonyms = const [],
  });

  final String partOfSpeech;
  final String definition;
  final String? example;
  final List<String> synonyms;

  Map<String, dynamic> toJson() => {
        'pos': partOfSpeech,
        'def': definition,
        'ex': example,
        'syn': synonyms,
      };

  static Sense fromJson(Map<String, dynamic> json) => Sense(
        partOfSpeech: json['pos'] as String? ?? '',
        definition: json['def'] as String? ?? '',
        example: json['ex'] as String?,
        synonyms:
            (json['syn'] as List?)?.map((e) => '$e').toList() ?? const [],
      );
}

class DictionaryEntry {
  const DictionaryEntry({
    required this.word,
    required this.senses,
    this.phonetic,
    this.source = 'dictionary',
  });

  final String word;
  final String? phonetic;
  final List<Sense> senses;
  final String source;

  bool get isEmpty => senses.isEmpty;

  Map<String, dynamic> toJson() => {
        'word': word,
        'phonetic': phonetic,
        'senses': senses.map((s) => s.toJson()).toList(),
        'source': source,
      };

  static DictionaryEntry fromJson(Map<String, dynamic> json) => DictionaryEntry(
        word: json['word'] as String? ?? '',
        phonetic: json['phonetic'] as String?,
        senses: (json['senses'] as List? ?? const [])
            .map((e) => Sense.fromJson(e as Map<String, dynamic>))
            .toList(),
        source: json['source'] as String? ?? 'dictionary',
      );
}

/// Look up a word while reading.
///
/// Three sources, tried in order, because the app's whole posture is
/// local-first but a local dictionary is not something every machine has:
///
///   1. **Cache** — a word looked up once is free forever after.
///   2. **A local dictionary binary** (`dict`, `sdcv`) if one is installed.
///      Fully offline.
///   3. **A free online dictionary**, only if the user has allowed it.
///
/// The online step is opt-in and deliberately narrow: a single word crosses the
/// network, never the passage around it. That distinction matters — it is the
/// difference between looking up a word and sending someone your book.
class DictionaryService {
  static const _apiBase = 'https://api.dictionaryapi.dev/api/v2/entries/en';

  static Directory? _cacheDir;
  static final Map<String, DictionaryEntry?> _memory = {};

  /// Whether the network source may be used. Owned by the caller (settings),
  /// so the decision stays the user's.
  bool allowOnline;

  DictionaryService({this.allowOnline = true});

  static Future<Directory> _dir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'dictionary'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _cacheDir = dir;
  }

  /// True when a word can be looked up without any network at all.
  static bool get hasOfflineSource =>
      RuntimeEnv.findBinary('sdcv') != null ||
      RuntimeEnv.findBinary('dict') != null;

  static String get offlineHint =>
      'For offline definitions, install a local dictionary:\n'
      '    sudo apt install dictd dict-gcide dict-wn';

  /// Reduce a word as it appears in prose to something lookupable.
  ///
  /// Text selected from a page arrives with punctuation, quotes, hyphens broken
  /// across lines and stray case. Without this, half of all lookups miss.
  static String normalise(String raw) {
    var word = raw.trim().toLowerCase();
    word = word.replaceAll(RegExp(r'^[^\p{L}]+|[^\p{L}]+$', unicode: true), '');
    // A hyphen left by a line break inside a word, e.g. "hyphen-\nated".
    word = word.replaceAll(RegExp(r'-\s*\n\s*'), '');
    return word.trim();
  }

  /// Whether this selection is worth offering a definition for.
  ///
  /// A dictionary button on a whole paragraph is noise; this is for single
  /// words, which is what someone actually stops to look up.
  static bool isLookupable(String raw) {
    final word = normalise(raw);
    if (word.isEmpty || word.length > 40) return false;
    return RegExp(r'^[\p{L}]+(-[\p{L}]+)?$', unicode: true).hasMatch(word);
  }

  Future<DictionaryEntry?> lookup(String raw) async {
    final word = normalise(raw);
    if (word.isEmpty) return null;

    if (_memory.containsKey(word)) return _memory[word];

    final cached = await _fromCache(word);
    if (cached != null) return _memory[word] = cached;

    final offline = await _fromLocalBinary(word);
    if (offline != null) {
      await _toCache(word, offline);
      return _memory[word] = offline;
    }

    if (!allowOnline) return _memory[word] = null;

    final online = await _fromApi(word);
    if (online != null) await _toCache(word, online);
    return _memory[word] = online;
  }

  // ── sources ──

  /// `sdcv` and `dict` both print plain text; this keeps the parsing minimal
  /// rather than trying to understand every dictionary format.
  Future<DictionaryEntry?> _fromLocalBinary(String word) async {
    final sdcv = RuntimeEnv.findBinary('sdcv');
    final dict = RuntimeEnv.findBinary('dict');
    final binary = sdcv ?? dict;
    if (binary == null) return null;

    try {
      final result = await Process.run(
        binary,
        sdcv != null ? ['-n', word] : [word],
      ).timeout(const Duration(seconds: 6));
      if (result.exitCode != 0) return null;

      final text = (result.stdout as String).trim();
      if (text.isEmpty || text.toLowerCase().contains('no definitions found')) {
        return null;
      }

      final lines = text
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty && !l.startsWith('---'))
          .toList();

      return DictionaryEntry(
        word: word,
        source: p.basename(binary),
        senses: [
          for (final line in lines.take(8))
            Sense(partOfSpeech: '', definition: line),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  Future<DictionaryEntry?> _fromApi(String word) async {
    try {
      final resp = await http
          .get(Uri.parse('$_apiBase/${Uri.encodeComponent(word)}'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;

      final data = jsonDecode(resp.body);
      if (data is! List || data.isEmpty) return null;
      final first = data.first as Map<String, dynamic>;

      final senses = <Sense>[];
      for (final meaning in (first['meanings'] as List? ?? const [])) {
        final pos = (meaning as Map)['partOfSpeech'] as String? ?? '';
        for (final def in (meaning['definitions'] as List? ?? const [])) {
          final d = def as Map;
          senses.add(Sense(
            partOfSpeech: pos,
            definition: d['definition'] as String? ?? '',
            example: d['example'] as String?,
            synonyms:
                (d['synonyms'] as List?)?.take(4).map((e) => '$e').toList() ??
                    const [],
          ));
          // Enough to be useful without becoming a wall of text mid-page.
          if (senses.length >= 6) break;
        }
        if (senses.length >= 6) break;
      }
      if (senses.isEmpty) return null;

      return DictionaryEntry(
        word: first['word'] as String? ?? word,
        phonetic: _phoneticOf(first),
        senses: senses,
        source: 'dictionaryapi.dev',
      );
    } catch (_) {
      return null;
    }
  }

  static String? _phoneticOf(Map<String, dynamic> json) {
    final direct = json['phonetic'] as String?;
    if (direct != null && direct.isNotEmpty) return direct;
    for (final entry in (json['phonetics'] as List? ?? const [])) {
      final text = (entry as Map)['text'] as String?;
      if (text != null && text.isNotEmpty) return text;
    }
    return null;
  }

  // ── cache ──

  Future<DictionaryEntry?> _fromCache(String word) async {
    try {
      final file = File(p.join((await _dir()).path, '$word.json'));
      if (!await file.exists()) return null;
      return DictionaryEntry.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _toCache(String word, DictionaryEntry entry) async {
    try {
      final file = File(p.join((await _dir()).path, '$word.json'));
      await file.writeAsString(jsonEncode(entry.toJson()));
    } catch (_) {
      // Caching is an optimisation, never a reason to fail a lookup.
    }
  }

  static Future<void> clearCache() async {
    _memory.clear();
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _cacheDir = null;
  }
}
