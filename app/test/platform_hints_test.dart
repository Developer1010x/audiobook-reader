import 'dart:io';

import 'package:audiobook_reader/services/media_player_service.dart';
import 'package:audiobook_reader/services/piper_tts.dart';
import 'package:audiobook_reader/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every install hint must speak the running platform's language. A Linux
/// command on a Mac reads as the app being broken, not a tool being missing.
/// CI runs this on all three OSes, so each branch is exercised somewhere.
void main() {
  final apt = contains('sudo apt');

  test('music player hint names this platform\'s installer', () {
    final hint = MediaPlayerService.playerInstallHint;
    if (Platform.isMacOS) expect(hint, contains('brew install'));
    if (Platform.isWindows) expect(hint, contains('winget install'));
    if (Platform.isLinux) expect(hint, apt);
  });

  test('media-control hint offers apt only on Linux', () {
    final hint = MprisControl.installHint;
    expect(hint, Platform.isLinux ? apt : isNot(apt));
  });

  // Piper is used wherever it is installed, so its install steps are offered
  // on Linux and Windows. Not on macOS: the pip wheel crashes there (its
  // espeak-ng data path is baked in at build time), so steps would lead to a
  // crash rather than a voice.
  test('Piper install steps are offered only where they work', () {
    final piper = contains('piper-tts');
    final offered = Platform.isLinux || Platform.isWindows;
    expect(PiperTts.installMessage, offered ? piper : isNot(piper));
    expect(TtsService.unavailableMessage, offered ? piper : isNot(piper));
    // ...and in that platform's own paths.
    if (Platform.isWindows) {
      expect(PiperTts.installMessage, isNot(contains('~/.local')));
      expect(PiperTts.installMessage, contains(r'$env:LOCALAPPDATA'));
    }
  });
}
