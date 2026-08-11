import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book.dart';
import '../models/annotation.dart';
import '../models/bookmark.dart';
import 'llm/ai_mode.dart';
import 'llm/summary_length.dart';
import 'sleep_timer.dart';

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

  // ── sleep timer ──
  /// The last duration chosen, pre-selected next time. Re-arming the same
  /// stretch every night is the common case and deserves to be one tap.
  int get sleepMinutes => _prefs.getInt('sleep_minutes') ?? 30;
  Future<void> setSleepMinutes(int minutes) =>
      _prefs.setInt('sleep_minutes', minutes.clamp(1, 24 * 60));

  /// The last mode chosen. [SleepMode.off] is never stored — cancelling a timer
  /// says nothing about what the user wants next time.
  SleepMode get sleepMode {
    final v = _prefs.getString('sleep_mode');
    return SleepMode.values.firstWhere(
        (m) => m.name == v && m != SleepMode.off,
        orElse: () => SleepMode.duration);
  }

  Future<void> setSleepMode(SleepMode mode) async {
    if (mode == SleepMode.off) return;
    await _prefs.setString('sleep_mode', mode.name);
  }

  /// How long the voice takes to fade out before the timer stops it. Zero cuts
  /// it dead, which some people prefer and everyone else finds alarming.
  int get sleepFadeSeconds => _prefs.getInt('sleep_fade_seconds') ?? 30;
  Future<void> setSleepFadeSeconds(int seconds) =>
      _prefs.setInt('sleep_fade_seconds', seconds.clamp(0, 120));

  /// Sentences to step back when picking a book up after a sleep stop. Nobody
  /// remembers the last thing they heard before dropping off.
  int get sleepRewindSentences => _prefs.getInt('sleep_rewind_sentences') ?? 2;
  Future<void> setSleepRewindSentences(int count) =>
      _prefs.setInt('sleep_rewind_sentences', count.clamp(0, 10));

  /// Stop our own background music too. On by default: silencing the voice and
  /// leaving the playlist running all night is not a sleep timer.
  bool get sleepStopsMusic => _prefs.getBool('sleep_stops_music') ?? true;
  Future<void> setSleepStopsMusic(bool value) =>
      _prefs.setBool('sleep_stops_music', value);

  /// Pause whatever else is playing over MPRIS. Off by default — we did not
  /// start Spotify, so we do not presume to stop it.
  bool get sleepPausesMpris => _prefs.getBool('sleep_pauses_mpris') ?? false;
  Future<void> setSleepPausesMpris(bool value) =>
      _prefs.setBool('sleep_pauses_mpris', value);

  /// Freeze the timer while Car Mode is on. On by default: audio cutting out
  /// mid-drive for no visible reason makes the driver look at the phone to find
  /// out why, which is the one thing Car Mode exists to prevent.
  bool get sleepHoldInCar => _prefs.getBool('sleep_hold_in_car') ?? true;
  Future<void> setSleepHoldInCar(bool value) =>
      _prefs.setBool('sleep_hold_in_car', value);

  /// Where a sleep timer stopped, as `"page:sentence"` — `ReadingAnchor`'s
  /// encoding, kept as a plain string so services need not know about the UI.
  ///
  /// Deliberately not a [Bookmark]: [addBookmark] replaces same-page entries,
  /// so recording this as one would silently eat a bookmark the user placed on
  /// purpose. The *running* timer is never persisted — waking to a twelve-hour
  /// expired countdown is nonsense — but where it left off is worth keeping,
  /// for the resume offered when the book is next opened.
  String? sleepStop(String bookId) => _prefs.getString('sleep_stop:$bookId');

  Future<void> setSleepStop(String bookId, int page, int sentence) =>
      _prefs.setString('sleep_stop:$bookId', '$page:$sentence');

  Future<void> clearSleepStop(String bookId) =>
      _prefs.remove('sleep_stop:$bookId');

  // ── car mode ──
  /// Keep the screen on in Car Mode. On by default: a screen that sleeps while
  /// driving means fumbling to wake it, which is the situation Car Mode exists
  /// to avoid.
  bool get carKeepAwake => _prefs.getBool('car_keep_awake') ?? true;
  Future<void> setCarKeepAwake(bool value) =>
      _prefs.setBool('car_keep_awake', value);

  /// Show the sentence being read. Off by default — text is exactly what a
  /// driver should not be reading.
  bool get carShowText => _prefs.getBool('car_show_text') ?? false;
  Future<void> setCarShowText(bool value) =>
      _prefs.setBool('car_show_text', value);

  /// Confirm taps by feel, so a control can be used without looking at it.
  bool get carHaptics => _prefs.getBool('car_haptics') ?? true;
  Future<void> setCarHaptics(bool value) =>
      _prefs.setBool('car_haptics', value);

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
