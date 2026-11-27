import 'package:audiobook_reader/services/pronunciations.dart';
import 'package:audiobook_reader/services/tts_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parse', () {
    test('reads term = spoken lines and trims both sides', () {
      expect(Pronunciations.parse(' Hermione =  her-my-oh-nee \nSQL=sequel'),
          {'Hermione': 'her-my-oh-nee', 'SQL': 'sequel'});
    });

    test('skips blanks, comments and half-typed lines instead of failing', () {
      expect(
          Pronunciations.parse('# names\n\n= nothing\nnoequals\nGIF =\nGIF = jif'),
          {'GIF': 'jif'});
    });

    test('null and empty give no rules', () {
      expect(Pronunciations.parse(null), isEmpty);
      expect(Pronunciations.parse(''), isEmpty);
    });

    test('format round-trips through parse', () {
      final rules = {'Ra': 'rah', 'C++': 'C plus plus'};
      expect(Pronunciations.parse(Pronunciations.format(rules)), rules);
    });
  });

  group('apply', () {
    test('whole words only, any case', () {
      final rules = {'ra': 'rah'};
      expect(Pronunciations.apply('Ra met Rachel. RA!', rules),
          'rah met Rachel. rah!');
    });

    test('longer terms win over shorter overlapping ones', () {
      final rules = {'York': 'yawk', 'New York': 'noo yawk'};
      expect(Pronunciations.apply('New York, York', rules), 'noo yawk, yawk');
    });

    test('terms with symbols at either end still match', () {
      final rules = {'C++': 'C plus plus', '.NET': 'dot net'};
      expect(Pronunciations.apply('C++ and .NET.', rules),
          'C plus plus and dot net.');
    });

    test('a spoken form is not rewritten again', () {
      final rules = {'a': 'b', 'b': 'c'};
      expect(Pronunciations.apply('a b', rules), 'b c');
    });

    test('regex characters in a term are literal', () {
      expect(Pronunciations.apply('x.y xzy', {'x.y': 'ex why'}), 'ex why xzy');
    });

    test('no rules leaves text untouched', () {
      expect(Pronunciations.apply('Hello', const {}), 'Hello');
    });
  });

  test('export chunks get the same cleaning and pronunciations as playback', () {
    final chunks = TtsService.speakableChunks(
        'Hermione wrote SQL-\nqueries.\n12\n', {'Hermione': 'her-my-oh-nee'});
    expect(chunks, ['her-my-oh-nee wrote SQLqueries.']);
  });
}
