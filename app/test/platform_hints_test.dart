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

  // Read-aloud uses Piper only on Linux; elsewhere install steps would send
  // users to install a voice the app then ignores.
  test('Piper is only advertised where it is used', () {
    final piper = contains('piper-tts');
    expect(PiperTts.installMessage, Platform.isLinux ? piper : isNot(piper));
    expect(TtsService.unavailableMessage,
        Platform.isLinux ? piper : isNot(piper));
  });
}
