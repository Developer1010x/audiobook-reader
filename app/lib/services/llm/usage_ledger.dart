import 'package:shared_preferences/shared_preferences.dart';

/// Tokens and estimated spend, per provider, per day.
///
/// Cloud summarising costs real money and the bill arrives a month later. This
/// keeps a running count on-device so the number is visible before it becomes a
/// surprise. Local providers are recorded too — tokens there cost time, not
/// money, which is still worth seeing.
class UsageLedger {
  static const _kDays = 'usage_days';
  static const _windowDays = 90;

  final SharedPreferences _prefs;
  UsageLedger(this._prefs);

  static Future<UsageLedger> load() async =>
      UsageLedger(await SharedPreferences.getInstance());

  /// USD per million tokens, input/output. Approximate list prices — enough to
  /// tell "cents" from "dollars", not an invoice.
  static const pricing = <String, ({double input, double output})>{
    'ollama': (input: 0, output: 0),
    'gemini': (input: 0.30, output: 2.50),
    'groq': (input: 0.59, output: 0.79),
    'openrouter': (input: 0.40, output: 0.80),
    'together': (input: 0.88, output: 0.88),
    'huggingface': (input: 0.20, output: 0.60),
  };

  static String _day([DateTime? when]) {
    final d = when ?? DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  static double estimateCost(String provider, int inputTokens, int outputTokens) {
    final rate = pricing[provider];
    if (rate == null) return 0;
    return (inputTokens / 1e6) * rate.input + (outputTokens / 1e6) * rate.output;
  }

  Future<void> record({
    required String provider,
    required int inputTokens,
    required int outputTokens,
    int requests = 1,
  }) async {
    final day = _day();
    final days = _prefs.getStringList(_kDays)?.toList() ?? <String>[];
    if (!days.contains(day)) {
      days.add(day);
      days.sort();
      while (days.length > _windowDays) {
        final dropped = days.removeAt(0);
        for (final k in _prefs.getKeys().where((k) => k.contains(dropped))) {
          await _prefs.remove(k);
        }
      }
      await _prefs.setStringList(_kDays, days);
    }

    Future<void> bump(String field, int by) async {
      final key = 'usage:$day:$provider:$field';
      await _prefs.setInt(key, (_prefs.getInt(key) ?? 0) + by);
    }

    await bump('in', inputTokens);
    await bump('out', outputTokens);
    await bump('req', requests);
  }

  int _sum(String field, {String? provider, String? day}) {
    final days = day != null ? [day] : (_prefs.getStringList(_kDays) ?? const []);
    var total = 0;
    for (final d in days) {
      for (final prov in pricing.keys) {
        if (provider != null && prov != provider) continue;
        total += _prefs.getInt('usage:$d:$prov:$field') ?? 0;
      }
    }
    return total;
  }

  int get inputTokensToday => _sum('in', day: _day());
  int get outputTokensToday => _sum('out', day: _day());
  int get requestsToday => _sum('req', day: _day());
  int get totalRequests => _sum('req');

  /// Estimated spend across the retained window, cloud providers only.
  double get estimatedSpend {
    final days = _prefs.getStringList(_kDays) ?? const [];
    var total = 0.0;
    for (final d in days) {
      for (final provider in pricing.keys) {
        total += estimateCost(
          provider,
          _prefs.getInt('usage:$d:$provider:in') ?? 0,
          _prefs.getInt('usage:$d:$provider:out') ?? 0,
        );
      }
    }
    return total;
  }

  double get spendToday {
    var total = 0.0;
    final d = _day();
    for (final provider in pricing.keys) {
      total += estimateCost(
        provider,
        _prefs.getInt('usage:$d:$provider:in') ?? 0,
        _prefs.getInt('usage:$d:$provider:out') ?? 0,
      );
    }
    return total;
  }

  /// Human-readable, and honest about being an estimate.
  static String formatCost(double usd) {
    if (usd <= 0) return 'free';
    if (usd < 0.01) return '<\$0.01';
    return '~\$${usd.toStringAsFixed(2)}';
  }
}
