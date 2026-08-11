import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/annotation.dart';
import '../models/bookmark.dart';
import 'llm/ai_mode.dart';
import 'llm/summary_length.dart';

/// App settings and API keys.
///
/// Keys go in the platform secure store (Keychain / Keystore / libsecret), never
/// in SharedPreferences and never in a file in the repo. Everything else — the
/// library path, provider choice, per-book type overrides — is ordinary prefs.
class SettingsService {
  static const _kLibraryPath = 'library_path';
  static const _kProviderId = 'provider_id';
  static const _kModel = 'model';
  static const _kTypeOverride = 'type_override:';
  static const _kClassified = 'classified:';

  static const _secure = FlutterSecureStorage();

  final SharedPreferences _prefs;
  SettingsService(this._prefs);

  static Future<SettingsService> load() async =>
      SettingsService(await SharedPreferences.getInstance());

  // ── library ──
  String? get libraryPath => _prefs.getString(_kLibraryPath);
  Future<void> setLibraryPath(String path) => _prefs.setString(_kLibraryPath, path);

  // ── provider ──
  String get providerId => _prefs.getString(_kProviderId) ?? 'ollama';
  Future<void> setProviderId(String id) => _prefs.setString(_kProviderId, id);

  /// Model for [providerId]. Stored per provider, because a model name is
  /// meaningless across providers — an Ollama tag is not a Gemini model.
  String? modelFor(String providerId) => _prefs.getString('$_kModel:$providerId');
  Future<void> setModelFor(String providerId, String model) =>
      _prefs.setString('$_kModel:$providerId', model);

  // ── API keys (secure store only) ──
  Future<String?> getKey(String keyName) => _secure.read(key: keyName);

  Future<void> setKey(String keyName, String value) => value.trim().isEmpty
      ? _secure.delete(key: keyName)
      : _secure.write(key: keyName, value: value.trim());

  Future<bool> hasKey(String? keyName) async {
    if (keyName == null) return true; // provider needs no key (Ollama)
    final v = await _secure.read(key: keyName);
    return v != null && v.isNotEmpty;
  }

  // ── reading position ──
  /// Last page read, so a book reopens where it was left rather than at page 1.
  int? lastPage(String bookId) => _prefs.getInt('last_page:$bookId');

  Future<void> setLastPage(String bookId, int page) =>
      _prefs.setInt('last_page:$bookId', page);

  /// Total pages, cached at first open so the library can show progress without
  /// opening every PDF.
  int? pageCount(String bookId) => _prefs.getInt('page_count:$bookId');

  Future<void> setPageCount(String bookId, int count) =>
      _prefs.setInt('page_count:$bookId', count);

  // ── AI mode ──
  /// Remembered across sessions: someone preparing for interviews wants that
  /// mode every time, not a summary they must re-select.
  AiMode get aiMode {
    final v = _prefs.getString('ai_mode');
    return AiMode.values.firstWhere((m) => m.name == v,
        orElse: () => AiMode.summary);
  }

  Future<void> setAiMode(AiMode mode) => _prefs.setString('ai_mode', mode.name);

  SummaryLength get summaryLength {
    final v = _prefs.getString('summary_length');
    return SummaryLength.values.firstWhere((l) => l.name == v,
        orElse: () => SummaryLength.standard);
  }

  Future<void> setSummaryLength(SummaryLength length) =>
      _prefs.setString('summary_length', length.name);

  // ── bookmarks ──
  List<Bookmark> bookmarks(String bookId) =>
      Bookmark.decode(_prefs.getString('bookmarks:$bookId'));

  Future<void> setBookmarks(String bookId, List<Bookmark> bookmarks) =>
      _prefs.setString('bookmarks:$bookId', Bookmark.encode(bookmarks));

  Future<void> addBookmark(String bookId, Bookmark bookmark) async {
    final list = bookmarks(bookId).toList()
      // One bookmark per page: adding again on the same page updates it rather
      // than stacking duplicates the user must clean up.
      ..removeWhere((b) => b.page == bookmark.page)
      ..add(bookmark)
      ..sort((a, b) => a.page.compareTo(b.page));
    await setBookmarks(bookId, list);
  }

  Future<void> removeBookmark(String bookId, int page) async {
    final list = bookmarks(bookId).toList()..removeWhere((b) => b.page == page);
    await setBookmarks(bookId, list);
  }

  bool isBookmarked(String bookId, int page) =>
      bookmarks(bookId).any((b) => b.page == page);

  // ── annotations & notes ──
  List<Annotation> annotations(String bookId) =>
      Annotation.decode(_prefs.getString('annotations:$bookId'));

  Future<void> setAnnotations(String bookId, List<Annotation> items) =>
      _prefs.setString('annotations:$bookId', Annotation.encode(items));

  Future<void> addAnnotation(String bookId, Annotation a) async {
    final list = annotations(bookId).toList()
      ..removeWhere((x) => x.id == a.id) // editing replaces in place
      ..add(a)
      ..sort((x, y) => x.page.compareTo(y.page));
    await setAnnotations(bookId, list);
  }

  Future<void> removeAnnotation(String bookId, String id) async {
    final list = annotations(bookId).toList()..removeWhere((a) => a.id == id);
    await setAnnotations(bookId, list);
  }

  int annotationCount(String bookId) => annotations(bookId).length;

  // ── favourites ──
  Set<String> get favourites =>
      (_prefs.getStringList('favourites') ?? const []).toSet();

  bool isFavourite(String bookId) => favourites.contains(bookId);

  Future<void> toggleFavourite(String bookId) async {
    final set = favourites;
    set.contains(bookId) ? set.remove(bookId) : set.add(bookId);
    await _prefs.setStringList('favourites', set.toList());
  }

  // ── recently opened ──
  /// Most recent first, capped so the list stays a shortcut rather than history.
  List<String> get recentBooks =>
      _prefs.getStringList('recent_books') ?? <String>[];

  Future<void> markOpened(String bookId) async {
    final list = recentBooks.toList()
      ..remove(bookId)
      ..insert(0, bookId);
    await _prefs.setStringList('recent_books', list.take(12).toList());
  }

  // ── background audio ──
  String? get musicFolder => _prefs.getString('music_folder');
  Future<void> setMusicFolder(String path) =>
      _prefs.setString('music_folder', path);

  // ── voice ──
  /// Chosen Piper voice, remembered across sessions.
  String? get voice => _prefs.getString('tts_voice');
  Future<void> setVoice(String name) => _prefs.setString('tts_voice', name);

  // ── appearance ──
  bool get nightMode => _prefs.getBool('night_mode') ?? false;
  Future<void> setNightMode(bool value) => _prefs.setBool('night_mode', value);

  // ── book type ──
  /// A user override wins permanently over auto-detection.
  BookType? typeOverride(String bookId) {
    final v = _prefs.getString('$_kTypeOverride$bookId');
    if (v == null) return null;
    return BookType.values.firstWhere((t) => t.name == v,
        orElse: () => BookType.storybook);
  }

  Future<void> setTypeOverride(String bookId, BookType type) =>
      _prefs.setString('$_kTypeOverride$bookId', type.name);

  Future<void> clearTypeOverride(String bookId) =>
      _prefs.remove('$_kTypeOverride$bookId');

  /// Cached auto-detection, so a book is classified once rather than on every open.
  BookType? cachedClassification(String bookId) {
    final v = _prefs.getString('$_kClassified$bookId');
    if (v == null) return null;
    return BookType.values.firstWhere((t) => t.name == v,
        orElse: () => BookType.storybook);
  }

  Future<void> cacheClassification(String bookId, BookType type) =>
      _prefs.setString('$_kClassified$bookId', type.name);
}
