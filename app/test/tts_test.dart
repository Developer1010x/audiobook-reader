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
      expect(PiperTts.playerArgs('/usr/bin/ffplay', 'x.wav'), contains('-autoexit'));
      // pw-play and paplay take the bare filename.
      expect(PiperTts.playerArgs('/usr/bin/pw-play', 'x.wav'), ['x.wav']);
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
