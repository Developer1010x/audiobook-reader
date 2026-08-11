import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Accent colours offered in Settings.
///
/// A reading app is looked at for hours, so these are muted rather than vivid —
/// a saturated accent that looks striking in a screenshot becomes tiring across
/// a chapter. Each is a seed; Material derives the rest of the scheme from it,
/// which keeps contrast correct in both themes without hand-tuning every token.
enum AccentColour {
  indigo('Indigo', Color(0xFF5B6ABF)),
  forest('Forest', Color(0xFF3D7A5E)),
  clay('Clay', Color(0xFFA35A43)),
  slate('Slate', Color(0xFF54677A)),
  plum('Plum', Color(0xFF7A4E7E)),
  amber('Amber', Color(0xFF9A7726));

  const AccentColour(this.label, this.seed);
  final String label;
  final Color seed;

  static AccentColour from(String? name) => AccentColour.values
      .firstWhere((a) => a.name == name, orElse: () => AccentColour.indigo);
}

/// Appearance: light, dark or follow the system, plus the accent.
///
/// Kept apart from [SettingsService] deliberately — it is read on the very
/// first frame, before the rest of the app exists, and it notifies the root
/// widget rather than any screen. Its own prefs handle also means a theme
/// change never has to wait on unrelated settings work.
///
/// Note this is distinct from the readers' *night mode*, which inverts the
/// rendered page itself. A dark interface with a normally-rendered white page
/// is a perfectly reasonable combination, so the two stay independent.
class ThemeController extends ChangeNotifier {
  static const _kMode = 'theme_mode';
  static const _kAccent = 'theme_accent';
  static const _kContrast = 'theme_high_contrast';

  final SharedPreferences _prefs;

  ThemeController(this._prefs);

  static Future<ThemeController> load() async =>
      ThemeController(await SharedPreferences.getInstance());

  // ── mode ──

  ThemeMode get mode {
    final v = _prefs.getString(_kMode);
    return switch (v) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> setMode(ThemeMode value) async {
    await _prefs.setString(_kMode, value.name);
    notifyListeners();
  }

  String get modeLabel => switch (mode) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'Follow system',
      };

  // ── accent ──

  AccentColour get accent => AccentColour.from(_prefs.getString(_kAccent));

  Future<void> setAccent(AccentColour value) async {
    await _prefs.setString(_kAccent, value.name);
    notifyListeners();
  }

  // ── contrast ──

  /// Raises contrast for low-light reading and for anyone who finds the default
  /// surfaces too close together.
  bool get highContrast => _prefs.getBool(_kContrast) ?? false;

  Future<void> setHighContrast(bool value) async {
    await _prefs.setBool(_kContrast, value);
    notifyListeners();
  }

  // ── themes ──

  ThemeData get light => buildTheme(Brightness.light, accent.seed, highContrast);
  ThemeData get dark => buildTheme(Brightness.dark, accent.seed, highContrast);

  /// One builder for both themes, so a change made for light never silently
  /// leaves dark behind.
  static ThemeData buildTheme(
    Brightness brightness,
    Color seed,
    bool highContrast,
  ) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      contrastLevel: highContrast ? 0.6 : 0.0,
    );
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      // A true-black ground in dark mode is harsh next to a bright page image;
      // a very dark neutral sits better beside rendered paper.
      scaffoldBackgroundColor: isDark ? const Color(0xFF0F1014) : scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? const Color(0xFF0F1014) : scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: scheme.outlineVariant.withValues(alpha: highContrast ? 1.0 : 0.5),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: highContrast ? 1.0 : 0.6),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
