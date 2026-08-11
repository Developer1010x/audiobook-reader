import 'package:audiobook_reader/services/dictionary_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Most dictionary lookups fail on the way *in*, not in the dictionary: text
/// selected from a page carries punctuation, quotes, and hyphens broken across
/// line ends. These test the normalising that decides whether a lookup can
/// succeed at all.
void main() {
  group('normalising a selection', () {
    test('strips surrounding punctuation and quotes', () {
      expect(DictionaryService.normalise('"heuristic,"'), 'heuristic');
      expect(DictionaryService.normalise('(algorithm)'), 'algorithm');
      expect(DictionaryService.normalise('word.'), 'word');
      expect(DictionaryService.normalise('—dash—'), 'dash');
    });

    test('lowercases, so a sentence-initial word still resolves', () {
      expect(DictionaryService.normalise('Heuristic'), 'heuristic');
      expect(DictionaryService.normalise('ALGORITHM'), 'algorithm');
    });

    test('rejoins a word hyphenated across a line break', () {
      // PDF text extraction produces exactly this, constantly.
      expect(DictionaryService.normalise('hyphen-\nated'), 'hyphenated');
    });

    test('keeps a genuine compound hyphen', () {
      expect(DictionaryService.normalise('state-of-the-art'),
          'state-of-the-art');
    });

    test('handles accented and non-Latin letters', () {
      expect(DictionaryService.normalise('café,'), 'café');
      expect(DictionaryService.normalise('«naïve»'), 'naïve');
    });

    test('empty and punctuation-only selections normalise to nothing', () {
      expect(DictionaryService.normalise('   '), '');
      expect(DictionaryService.normalise('...'), '');
      expect(DictionaryService.normalise('—'), '');
    });
  });

  group('deciding whether to offer a definition', () {
    test('accepts single words, including hyphenated ones', () {
      expect(DictionaryService.isLookupable('heuristic'), isTrue);
      expect(DictionaryService.isLookupable('"Heuristic,"'), isTrue);
      expect(DictionaryService.isLookupable('well-known'), isTrue);
    });

    test('refuses a phrase or a paragraph', () {
      // A dictionary button on a whole paragraph is noise, not a feature.
      expect(DictionaryService.isLookupable('the quick brown fox'), isFalse);
      expect(DictionaryService.isLookupable('a' * 60), isFalse);
    });

    test('refuses numbers, code and empty selections', () {
      expect(DictionaryService.isLookupable('42'), isFalse);
      expect(DictionaryService.isLookupable('x = y + 1;'), isFalse);
      expect(DictionaryService.isLookupable(''), isFalse);
      expect(DictionaryService.isLookupable('   '), isFalse);
    });
  });

  group('offline capability', () {
    test('reports honestly whether it can work without a network', () {
      // The UI uses this to decide whether to warn the user before a lookup
      // leaves the machine.
      expect(DictionaryService.hasOfflineSource, isA<bool>());
    });

    test('the offline hint names a real package to install', () {
      expect(DictionaryService.offlineHint, contains('dictd'));
    });

    test('online lookup is refused when not allowed', () async {
      // The privacy guarantee: with online off, an unknown word returns null
      // rather than quietly reaching the network.
      final dict = DictionaryService(allowOnline: false);
      final entry = await dict
          .lookup('zzzznotarealwordzzzz')
          .timeout(const Duration(seconds: 10));
      expect(entry, isNull);
    });
  });

  group('entry serialisation', () {
    test('round-trips through the cache format intact', () {
      const entry = DictionaryEntry(
        word: 'heuristic',
        phonetic: '/hjuˈɹɪstɪk/',
        source: 'test',
        senses: [
          Sense(
            partOfSpeech: 'noun',
            definition: 'A rule of thumb.',
            example: 'A useful heuristic.',
            synonyms: ['shortcut'],
          ),
        ],
      );

      final restored = DictionaryEntry.fromJson(
          Map<String, dynamic>.from(entry.toJson()));

      expect(restored.word, 'heuristic');
      expect(restored.phonetic, '/hjuˈɹɪstɪk/');
      expect(restored.senses.single.partOfSpeech, 'noun');
      expect(restored.senses.single.example, 'A useful heuristic.');
      expect(restored.senses.single.synonyms, ['shortcut']);
    });

    test('a malformed cache entry degrades rather than throwing', () {
      final restored = DictionaryEntry.fromJson({'word': 'x'});
      expect(restored.word, 'x');
      expect(restored.isEmpty, isTrue);
    });
  });
}
