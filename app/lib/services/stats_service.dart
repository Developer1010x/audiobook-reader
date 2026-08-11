import 'package:shared_preferences/shared_preferences.dart';

/// Reading activity, kept as a per-day page count.
///
/// Deliberately tiny: one integer per day, capped to a rolling window. The point
/// is a streak and a sense of momentum, not analytics — and nothing about it
/// leaves the machine.
class StatsService {
  static const _kPagesPrefix = 'stats_pages:';
  static const _kDays = 'stats_days';
  static const _windowDays = 120;

  final SharedPreferences _prefs;
  StatsService(this._prefs);

  static Future<StatsService> load() async =>
      StatsService(await SharedPreferences.getInstance());

  static String _key(DateTime day) =>
      '${day.year}-${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// Record that one page was read. Called on each page turn.
  Future<void> recordPage([DateTime? when]) async {
    final day = _key(when ?? DateTime.now());
    final days = _prefs.getStringList(_kDays)?.toList() ?? <String>[];

    if (!days.contains(day)) {
      days.add(day);
      days.sort();
      // Drop the oldest days rather than growing prefs forever.
      while (days.length > _windowDays) {
        final dropped = days.removeAt(0);
        await _prefs.remove('$_kPagesPrefix$dropped');
      }
      await _prefs.setStringList(_kDays, days);
    }
    final current = _prefs.getInt('$_kPagesPrefix$day') ?? 0;
    await _prefs.setInt('$_kPagesPrefix$day', current + 1);
  }

  int pagesOn(DateTime day) => _prefs.getInt('$_kPagesPrefix${_key(day)}') ?? 0;

  int get pagesToday => pagesOn(DateTime.now());

  int get totalPages {
    final days = _prefs.getStringList(_kDays) ?? const [];
    return days.fold(0, (sum, d) => sum + (_prefs.getInt('$_kPagesPrefix$d') ?? 0));
  }

  /// Consecutive days with at least one page, counting back from today.
  ///
  /// Today not yet started does not break the streak — it is only broken once a
  /// full day passes with nothing read.
  int get streak {
    var day = DateTime.now();
    if (pagesOn(day) == 0) day = day.subtract(const Duration(days: 1));

    var count = 0;
    while (pagesOn(day) > 0) {
      count++;
      day = day.subtract(const Duration(days: 1));
    }
    return count;
  }

  /// Pages per day for the last [days] days, oldest first — for a sparkline.
  List<int> recent({int days = 14}) {
    final today = DateTime.now();
    return [
      for (var i = days - 1; i >= 0; i--)
        pagesOn(today.subtract(Duration(days: i)))
    ];
  }
}
