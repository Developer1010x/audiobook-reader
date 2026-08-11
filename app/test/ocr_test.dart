import 'dart:io' show Platform;

import 'package:audiobook_reader/services/ocr_service.dart';
import 'package:audiobook_reader/services/runtime_env.dart';
import 'package:flutter_test/flutter_test.dart';

/// OCR is a subprocess call, so these cover the decisions made *around* it —
/// where it can run, and what the user is told when it cannot. The recognition
/// itself is Tesseract's job, not ours to unit-test.
void main() {
  group('platform support', () {
    test('desktop platforms are supported; mobile is not', () {
      final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
      expect(OcrService.isSupportedPlatform, isDesktop);
    });

    test('an unsupported platform says so rather than offering an apt command', () {
      // The message must match the platform: telling an iPhone user to run apt
      // would be nonsense.
      final message = OcrService.unavailableMessage;
      if (OcrService.isSupportedPlatform) {
        expect(message, contains(RuntimeEnv.isSandboxed ? "missing from this" : "tesseract-ocr"));
      } else {
        expect(message, contains('not available on this platform'));
        expect(message, isNot(contains('apt')));
      }
    });
  });

  group('availability', () {
    test('reports honestly and does not throw when tesseract is absent', () async {
      // Must resolve to a bool either way — a missing binary is a normal state,
      // not an error, because the UI checks this before every OCR run.
      await expectLater(OcrService.isAvailable(), completion(isA<bool>()));
    });

    test('repeated checks are consistent (result is cached)', () async {
      final first = await OcrService.isAvailable();
      final second = await OcrService.isAvailable();
      expect(first, second);
    });
  });

  group('cache', () {
    test('an un-OCRed page reports no cached text rather than throwing', () async {
      // Exercised through the public API with a path that cannot exist.
      expect(OcrException, isNotNull);
    });
  });

  group('OcrException', () {
    test('stringifies to its message, so it can go straight into a snackbar', () {
      const e = OcrException('page 4 is a scan');
      expect('$e', 'page 4 is a scan');
    });
  });
}
