import 'package:audiobook_reader/services/desktop_tray.dart';
import 'package:audiobook_reader/services/mpris_server.dart';
import 'package:audiobook_reader/services/playback_remote.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

/// A reader stand-in that records what remotes asked of it.
class FakeReader {
  bool playing = false;
  final calls = <String>[];

  late final target = PlaybackTarget(
    title: 'Dune',
    isPlaying: () => playing,
    togglePlay: () async {
      calls.add('toggle');
      playing = !playing;
    },
    stop: () async {
      calls.add('stop');
      playing = false;
    },
    skip: (n) async => calls.add('skip $n'),
  );
}

void main() {
  final remote = PlaybackRemote.instance;
  late FakeReader reader;

  setUp(() {
    reader = FakeReader();
    remote.claim(reader.target);
  });
  tearDown(() => remote.release(reader.target));

  group('PlaybackRemote', () {
    test('forwards to the claimed reader', () async {
      await remote.togglePlay();
      await remote.skip(-1);
      await remote.stop();
      expect(reader.calls, ['toggle', 'skip -1', 'stop']);
    });

    test('a closing reader cannot unhook the one that replaced it', () {
      final next = FakeReader();
      remote.claim(next.target);
      remote.release(reader.target); // the old screen's dispose, arriving late
      expect(remote.title, 'Dune');
      expect(identical(remote.target, next.target), isTrue);
      remote.release(next.target);
      expect(remote.hasTarget, isFalse);
    });

    test('with nothing claimed, controls do nothing rather than throw', () async {
      remote.release(reader.target);
      await remote.togglePlay();
      expect(remote.isPlaying, isFalse);
      expect(reader.calls, isEmpty);
    });
  });

  group('tray menu', () {
    test('shows the book and enables controls while one is open', () {
      final menu = DesktopTray.menuFor(remote);
      expect(menu.first.label, 'Dune');
      expect(menu.firstWhere((m) => m.key == 'toggle').label, 'Play');
      expect(menu.firstWhere((m) => m.key == 'stop').enabled, isFalse);
      reader.playing = true;
      final playing = DesktopTray.menuFor(remote);
      expect(playing.firstWhere((m) => m.key == 'toggle').label, 'Pause');
      expect(playing.firstWhere((m) => m.key == 'stop').enabled, isTrue);
    });

    test('everything but the title is disabled with no book open', () {
      remote.release(reader.target);
      final menu = DesktopTray.menuFor(remote);
      expect(menu.first.label, 'No book open');
      expect(menu.where((m) => m.enabled), isEmpty);
    });
  });

  group('MPRIS', () {
    final mpris = MprisObject(PlaybackRemote.instance);
    const player = 'org.mpris.MediaPlayer2.Player';

    Future<DBusMethodResponse> call(String name, [String iface = player]) =>
        mpris.handleMethodCall(
            DBusMethodCall(sender: ':1.1', interface: iface, name: name));

    test('media keys map onto the reader', () async {
      await call('PlayPause');
      await call('Next');
      await call('Previous');
      await call('Pause');
      expect(reader.calls, ['toggle', 'skip 1', 'skip -1', 'stop']);
    });

    test('Play and Pause are idempotent, unlike PlayPause', () async {
      reader.playing = true;
      await call('Play');
      reader.playing = false;
      await call('Pause');
      expect(reader.calls, isEmpty);
    });

    test('unknown methods and interfaces are errors, not crashes', () async {
      expect(await call('Explode'), isA<DBusMethodErrorResponse>());
      expect(await call('PlayPause', 'org.example.Nope'),
          isA<DBusMethodErrorResponse>());
    });

    test('PlaybackStatus follows the reader', () async {
      String status() =>
          (mpris.playerProperties['PlaybackStatus'] as DBusString).value;
      expect(status(), 'Paused');
      reader.playing = true;
      expect(status(), 'Playing');
      remote.release(reader.target);
      expect(status(), 'Stopped');
    });
  });
}
