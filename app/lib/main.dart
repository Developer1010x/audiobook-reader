import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'services/settings_service.dart';
import 'services/stats_service.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  final settings = await SettingsService.load();
  final stats = await StatsService.load();
  runApp(AudiobookReaderApp(settings: settings, stats: stats));
}

class AudiobookReaderApp extends StatelessWidget {
  final SettingsService settings;
  final StatsService stats;
  const AudiobookReaderApp({
    super.key,
    required this.settings,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF5B6ABF);
    return MaterialApp(
      title: 'Audiobook Reader',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light, seed),
      darkTheme: _theme(Brightness.dark, seed),
      themeMode: ThemeMode.system,
      home: LibraryScreen(settings: settings, stats: stats),
    );
  }

  ThemeData _theme(Brightness brightness, Color seed) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}
