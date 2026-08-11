import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'services/settings_service.dart';
import 'services/stats_service.dart';
import 'services/theme_controller.dart';
import 'ui/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();

  final settings = await SettingsService.load();
  final stats = await StatsService.load();
  final theme = await ThemeController.load();

  runApp(AudiobookReaderApp(
    settings: settings,
    stats: stats,
    theme: theme,
  ));
}

class AudiobookReaderApp extends StatelessWidget {
  final SettingsService settings;
  final StatsService stats;
  final ThemeController theme;

  const AudiobookReaderApp({
    super.key,
    required this.settings,
    required this.stats,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    // Rebuilds the whole app when appearance changes, so switching to dark
    // takes effect immediately rather than on the next navigation.
    return ListenableBuilder(
      listenable: theme,
      builder: (context, _) => MaterialApp(
        title: 'Audiobook Reader',
        debugShowCheckedModeBanner: false,
        theme: theme.light,
        darkTheme: theme.dark,
        themeMode: theme.mode,
        home: LibraryScreen(
          settings: settings,
          stats: stats,
          theme: theme,
        ),
      ),
    );
  }
}
