import 'package:audiobook_reader/ui/widgets/reader_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> log;

  Widget harness({bool enabled = true, bool withSearch = true, Widget? body}) {
    return MaterialApp(
      home: ReaderShortcuts(
        enabled: enabled,
        onPlayPause: () => log.add('play'),
        onSkipSentence: (d) => log.add('sentence $d'),
        onRateStep: (d) => log.add('rate $d'),
        onPage: (d) => log.add('page $d'),
        onBookmark: () => log.add('bookmark'),
        onBack: () => log.add('back'),
        onSearch: withSearch ? () => log.add('search') : null,
        child: Scaffold(body: body ?? const SizedBox()),
      ),
    );
  }

  Future<void> chord(WidgetTester t, LogicalKeyboardKey mod, LogicalKeyboardKey key) async {
    await t.sendKeyDownEvent(mod);
    await t.sendKeyEvent(key);
    await t.sendKeyUpEvent(mod);
  }

  setUp(() => log = []);

  testWidgets('every key maps to its action', (t) async {
    await t.pumpWidget(harness());
    await t.pump();
    for (final k in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.pageUp,
      LogicalKeyboardKey.pageDown,
      LogicalKeyboardKey.escape,
    ]) {
      await t.sendKeyEvent(k);
    }
    expect(log, [
      'play', 'sentence -1', 'sentence 1', 'rate -1', 'rate 1',
      'page -1', 'page 1', 'back',
    ]);
  });

  testWidgets('bookmark and search answer to both Cmd and Ctrl', (t) async {
    await t.pumpWidget(harness());
    await t.pump();
    await chord(t, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyB);
    await chord(t, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyB);
    await chord(t, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.keyF);
    await chord(t, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyF);
    expect(log, ['bookmark', 'bookmark', 'search', 'search']);
  });

  testWidgets('a screen without search binds no search key', (t) async {
    await t.pumpWidget(harness(withSearch: false));
    await t.pump();
    await chord(t, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyF);
    expect(log, isEmpty);
  });

  testWidgets('typing in a text field does not start playback', (t) async {
    // Focused the way a user does it — a click. (The reader's search field is
    // focused explicitly with requestFocus, which is the same thing.)
    await t.pumpWidget(harness(body: const TextField()));
    await t.tap(find.byType(TextField));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(log, isEmpty);
  });

  testWidgets('Esc and chords still work while typing', (t) async {
    await t.pumpWidget(harness(body: const TextField()));
    await t.tap(find.byType(TextField));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await chord(t, LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.keyB);
    expect(log, ['back', 'bookmark']);
  });

  testWidgets('disabled (Car Mode up) binds nothing', (t) async {
    await t.pumpWidget(harness(enabled: false));
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(log, isEmpty);
  });
}
