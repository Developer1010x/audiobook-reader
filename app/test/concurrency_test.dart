import 'dart:async';
import 'dart:math';

import 'package:audiobook_reader/services/concurrency.dart';
import 'package:flutter_test/flutter_test.dart';

/// The properties that actually matter in this codebase's parallel code.
///
/// Every one of these guards a specific way parallelism silently corrupts a
/// book: pages assembled out of order, work outliving a cancel, or a fan-out
/// wide enough to thrash the machine.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('order preservation', () {
    test('results follow input order, not completion order', () async {
      // Deliberately invert the timing: later items finish first. If the
      // implementation collected by completion, this list would come back
      // reversed — and a book would be scrambled.
      final items = List.generate(20, (i) => i);
      final out = await Concurrency.mapBounded<int, int>(
        items,
        (item, index) async {
          await Future<void>.delayed(Duration(milliseconds: (20 - item) * 2));
          return item;
        },
        concurrency: 8,
      );
      expect(out, items);
    });

    test('order holds at concurrency 1 and at concurrency > length', () async {
      final items = List.generate(6, (i) => i);
      Future<int> work(int item, int index) async {
        await Future<void>.delayed(Duration(milliseconds: Random(item).nextInt(8)));
        return item;
      }

      expect(await Concurrency.mapBounded(items, work, concurrency: 1), items);
      expect(await Concurrency.mapBounded(items, work, concurrency: 999), items);
    });

    test('an empty list returns empty without invoking the worker', () async {
      var called = false;
      final out = await Concurrency.mapBounded<int, int>([], (i, idx) async {
        called = true;
        return i;
      });
      expect(out, isEmpty);
      expect(called, isFalse);
    });
  });

  group('bounded fan-out', () {
    test('never exceeds the requested concurrency', () async {
      var inFlight = 0;
      var peak = 0;

      await Concurrency.mapBounded<int, int>(
        List.generate(50, (i) => i),
        (item, index) async {
          inFlight++;
          peak = max(peak, inFlight);
          await Future<void>.delayed(const Duration(milliseconds: 4));
          inFlight--;
          return item;
        },
        concurrency: 4,
      );

      expect(peak, lessThanOrEqualTo(4));
      expect(peak, greaterThan(1), reason: 'should actually run in parallel');
    });

    test('really does run in parallel — wall clock beats serial', () async {
      final stopwatch = Stopwatch()..start();
      await Concurrency.mapBounded<int, int>(
        List.generate(8, (i) => i),
        (item, index) async {
          await Future<void>.delayed(const Duration(milliseconds: 40));
          return item;
        },
        concurrency: 8,
      );
      stopwatch.stop();
      // Serial would be ~320ms; parallel should be well under half that.
      expect(stopwatch.elapsedMilliseconds, lessThan(160));
    });
  });

  group('cancellation', () {
    test('stops dispatching new work once cancelled', () async {
      var started = 0;
      var cancelled = false;

      final out = await Concurrency.mapBounded<int, int>(
        List.generate(100, (i) => i),
        (item, index) async {
          started++;
          if (started >= 5) cancelled = true;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          return item;
        },
        concurrency: 2,
        isCancelled: () => cancelled,
      );

      // Far fewer than 100 items should have been touched.
      expect(started, lessThan(30));
      expect(out.length, 100, reason: 'shape is preserved even when cut short');
    });
  });

  group('lenient mode', () {
    test('drops failures and keeps the rest in order', () async {
      final out = await Concurrency.mapBoundedLenient<int, int>(
        List.generate(10, (i) => i),
        (item, index) async {
          if (item.isOdd) throw StateError('boom');
          return item;
        },
        concurrency: 4,
      );
      expect(out, [0, 2, 4, 6, 8]);
    });

    test('a total failure yields empty rather than throwing', () async {
      final out = await Concurrency.mapBoundedLenient<int, int>(
        [1, 2, 3],
        (item, index) async => throw StateError('always'),
      );
      expect(out, isEmpty);
    });
  });

  group('strict mode', () {
    test('propagates a worker failure rather than hiding it', () async {
      await expectLater(
        Concurrency.mapBounded<int, int>(
          [1, 2, 3],
          (item, index) async {
            if (item == 2) throw StateError('boom');
            return item;
          },
          concurrency: 1,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('pool sizing', () {
    test('pools are sane and leave headroom for the UI', () {
      expect(Concurrency.cores, greaterThan(0));
      expect(Concurrency.cpuPool, greaterThanOrEqualTo(1));
      expect(Concurrency.cpuPool, lessThanOrEqualTo(6));
      expect(Concurrency.ioPool, greaterThanOrEqualTo(2));
      // IO work waits rather than computes, so it may exceed the CPU pool.
      expect(Concurrency.ioPool, greaterThanOrEqualTo(Concurrency.cpuPool));
    });
  });

  group('offload threshold', () {
    test('small payloads are not worth an isolate round trip', () {
      expect(Concurrency.worthOffloading(100), isFalse);
      expect(Concurrency.worthOffloading(Concurrency.offThreadThresholdChars),
          isTrue);
    });
  });

  group('runOffThread', () {
    test('computes correctly and returns the value', () async {
      final result = await Concurrency.runOffThread(_double, 21);
      expect(result, 42);
    });

    test('handles a string payload of the kind the app actually sends', () async {
      final text = 'sentence. ' * 500;
      final count = await Concurrency.runOffThread(_countSentences, text);
      expect(count, 500);
    });
  });
}

int _double(int value) => value * 2;

int _countSentences(String text) => RegExp(r'\.').allMatches(text).length;
