import 'dart:io';

import 'package:audiobook_reader/services/wakeful.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(Wakeful.releaseAll);

  // acquire() awaits Process.start after counting its claim. A release (or a
  // release + re-acquire) landing inside that await must not leave a child
  // process holding the machine awake with no claim behind it.
  test('release during a pending acquire leaves no inhibitor', () async {
    final pending = Wakeful.acquire();
    await Wakeful.release();
    await pending;
    expect(Wakeful.isHeld, isFalse);
    expect(Wakeful.debugHasInhibitor, isFalse);
  }, skip: !Platform.isMacOS ? 'needs caffeinate (macOS)' : false);

  test('release + re-acquire during a pending acquire keeps one inhibitor',
      () async {
    final first = Wakeful.acquire();
    await Wakeful.release();
    final second = Wakeful.acquire();
    await Future.wait([first, second]);
    expect(Wakeful.isHeld, isTrue);
    expect(Wakeful.debugHasInhibitor, isTrue);
    await Wakeful.release();
    expect(Wakeful.debugHasInhibitor, isFalse);
  }, skip: !Platform.isMacOS ? 'needs caffeinate (macOS)' : false);
}
