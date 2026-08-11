import 'package:audiobook_reader/services/stats_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StatsService stats;
  final today = DateTime.now();
  DateTime daysAgo(int n) => today.subtract(Duration(days: n));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    stats = await StatsService.load();
  });

  test('starts empty', () {
    expect(stats.totalPages, 0);
    expect(stats.pagesToday, 0);
    expect(stats.streak, 0);
  });

  test('counts pages read today', () async {
    await stats.recordPage();
    await stats.recordPage();
    expect(stats.pagesToday, 2);
    expect(stats.totalPages, 2);
  });

  test('separates pages by day', () async {
    await stats.recordPage(daysAgo(1));
    await stats.recordPage();
    expect(stats.pagesToday, 1);
    expect(stats.pagesOn(daysAgo(1)), 1);
    expect(stats.totalPages, 2);
  });

  group('streak', () {
    test('counts consecutive days back from today', () async {
      for (final n in [0, 1, 2]) {
        await stats.recordPage(daysAgo(n));
      }
      expect(stats.streak, 3);
    });

    test('a gap ends the streak', () async {
      await stats.recordPage(daysAgo(0));
      await stats.recordPage(daysAgo(1));
      // nothing on day 2
      await stats.recordPage(daysAgo(3));
      expect(stats.streak, 2);
    });

    test('a quiet today does not break a streak that ran to yesterday', () async {
      // Reading later in the day should not be punished for not having started.
      await stats.recordPage(daysAgo(1));
      await stats.recordPage(daysAgo(2));
      expect(stats.pagesToday, 0);
      expect(stats.streak, 2);
    });

    test('two silent days does break it', () async {
      await stats.recordPage(daysAgo(2));
      await stats.recordPage(daysAgo(3));
      expect(stats.streak, 0);
    });
  });

  group('sparkline window', () {
    test('returns one entry per day, oldest first', () async {
      await stats.recordPage(daysAgo(0));
      await stats.recordPage(daysAgo(0));
      final recent = stats.recent(days: 5);
      expect(recent, hasLength(5));
      expect(recent.last, 2); // today is the final bar
      expect(recent.first, 0);
    });
  });

  test('persists across a reload', () async {
    await stats.recordPage();
    final reloaded = await StatsService.load();
    expect(reloaded.pagesToday, 1);
  });
}
