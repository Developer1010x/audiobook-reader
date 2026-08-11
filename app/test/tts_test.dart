import 'dart:io' show Platform;

import 'package:audiobook_reader/services/piper_tts.dart';
import 'package:audiobook_reader/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // TtsService constructs a FlutterTts, which registers a method-channel
  // handler and therefore needs the binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('engine selection', () {
    test('reports which engine will actually be used', () {
      final name = TtsService.engineName;
      expect(name, isNotEmpty);
      if (Platform.isLinux) {
        // Must name a real engine, so a robotic voice is never a surprise.
        expect(name, anyOf(contains('Piper'), contains('espeak')));
      }
    });

    test('availability does not throw regardless of what is installed',
        () async {
      await expectLater(TtsService.isAvailable(), completion(isA<bool>()));
    });
  });

  group('Piper discovery', () {
    test('reports availability without throwing', () {
      expect(PiperTts.isAvailable, isA<bool>());
    });

    test('voices list is empty rather than null when none are installed', () {
      expect(PiperTts.voices, isA<List<String>>());
    });

    test('availability requires binary, a voice, and a player together', () {
      // Any one missing must mean unavailable — otherwise the app would try to
      // speak and fail at the point of use.
      if (PiperTts.isAvailable) {
        expect(PiperTts.binary, isNotNull);
        expect(PiperTts.voices, isNotEmpty);
        expect(PiperTts.player, isNotNull);
      }
    });

    test('player arguments are tailored per player', () {
      expect(PiperTts.playerArgs('/usr/bin/aplay', 'x.wav'), contains('-q'));
      expect(
          PiperTts.playerArgs('/usr/bin/ffplay', 'x.wav'), contains('-autoexit'));
      expect(PiperTts.playerArgs('/usr/bin/pw-play', 'x.wav'), contains('x.wav'));
    });

    test('volume reaches the players that can honour it', () {
      // The sleep timer fades out rather than cutting off mid-word, which needs
      // the level to actually reach the player process.
      expect(PiperTts.playerArgs('/usr/bin/ffplay', 'x.wav', volume: 0.5),
          contains('50'));
      // pw-play and paplay take DIFFERENT scales. Using one tool's range for
      // the other is silent: the value is clamped, so the fade never happens.
      expect(PiperTts.playerArgs('/usr/bin/pw-play', 'x.wav', volume: 0.5),
          contains('--volume=0.500'));
      expect(PiperTts.playerArgs('/usr/bin/paplay', 'x.wav', volume: 1.0),
          contains('--volume=65536'));
      expect(PiperTts.playerArgs('/usr/bin/pw-play', 'x.wav', volume: 1.0),
          contains('--volume=1.000'));
    });

    test('aplay cannot take a volume, and says so by omission', () {
      // Not a bug: aplay has no level control, so a fade there simply has no
      // effect rather than failing. The session still ends.
      final args = PiperTts.playerArgs('/usr/bin/aplay', 'x.wav', volume: 0.2);
      expect(args.any((a) => a.contains('volume')), isFalse);
      expect(args, contains('x.wav'));
    });

    test('volume is clamped, so a bad value cannot produce a bad argument', () {
      expect(PiperTts.playerArgs('/usr/bin/ffplay', 'x.wav', volume: 5.0),
          contains('100'));
      expect(PiperTts.playerArgs('/usr/bin/ffplay', 'x.wav', volume: -1.0),
          contains('0'));
    });
  });

  group('rate', () {
    test('clamps to the usable range', () async {
      final tts = TtsService();
      await tts.setRate(5.0);
      expect(tts.rate, 1.0);
      await tts.setRate(-1.0);
      expect(tts.rate, 0.1);
      tts.dispose();
    });
  });
}
