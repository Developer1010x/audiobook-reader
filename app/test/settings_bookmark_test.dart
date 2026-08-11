import 'package:audiobook_reader/models/bookmark.dart';
import 'package:audiobook_reader/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Round-trips bookmarks through the real SettingsService against an in-memory
/// SharedPreferences, which is where a persistence bug would actually live.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SettingsService settings;
  const bookId = '/books/example.pdf';

  Bookmark at(int page) => Bookmark(
        page: page,
        preview: 'text of page $page',
        createdAt: 1700000000000 + page,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsService.load();
  });

  test('a saved bookmark is reported as bookmarked', () async {
    expect(settings.isBookmarked(bookId, 5), isFalse);
    await settings.addBookmark(bookId, at(5));
    expect(settings.isBookmarked(bookId, 5), isTrue);
    expect(settings.bookmarks(bookId), hasLength(1));
  });

  test('removing clears it', () async {
    await settings.addBookmark(bookId, at(5));
    await settings.removeBookmark(bookId, 5);
    expect(settings.isBookmarked(bookId, 5), isFalse);
    expect(settings.bookmarks(bookId), isEmpty);
  });

  test('bookmarking the same page twice updates rather than duplicates', () async {
    await settings.addBookmark(bookId, at(5));
    await settings.addBookmark(bookId, at(5));
    expect(settings.bookmarks(bookId), hasLength(1));
  });

  test('bookmarks are kept per book, not shared across the library', () async {
    await settings.addBookmark(bookId, at(5));
    expect(settings.isBookmarked('/books/other.pdf', 5), isFalse);
    expect(settings.bookmarks('/books/other.pdf'), isEmpty);
  });

  test('several pages coexist and come back in page order', () async {
    await settings.addBookmark(bookId, at(9));
    await settings.addBookmark(bookId, at(2));
    await settings.addBookmark(bookId, at(5));
    expect(settings.bookmarks(bookId).map((b) => b.page), [2, 5, 9]);
  });

  test('a note survives being added to an existing bookmark', () async {
    await settings.addBookmark(bookId, at(3));
    final existing = settings.bookmarks(bookId).single;
    await settings.addBookmark(bookId, existing.copyWith(note: 'important'));

    final updated = settings.bookmarks(bookId).single;
    expect(updated.note, 'important');
    expect(updated.page, 3);
    expect(settings.bookmarks(bookId), hasLength(1));
  });

  test('bookmarks persist across a new SettingsService instance', () async {
    // The reader and library hold the same instance today, but a reload must
    // not lose bookmarks.
    await settings.addBookmark(bookId, at(7));
    final reloaded = await SettingsService.load();
    expect(reloaded.isBookmarked(bookId, 7), isTrue);
  });

  group('favourites and recents', () {
    test('favourite toggles both ways', () async {
      expect(settings.isFavourite(bookId), isFalse);
      await settings.toggleFavourite(bookId);
      expect(settings.isFavourite(bookId), isTrue);
      await settings.toggleFavourite(bookId);
      expect(settings.isFavourite(bookId), isFalse);
    });

    test('recents are most-recent-first with no duplicates', () async {
      await settings.markOpened('a');
      await settings.markOpened('b');
      await settings.markOpened('a');
      expect(settings.recentBooks, ['a', 'b']);
    });
  });
}
