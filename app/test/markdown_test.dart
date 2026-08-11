import 'package:audiobook_reader/ui/widgets/markdown_text.dart';
import 'package:flutter_test/flutter_test.dart';

/// Read-aloud must speak the words, not the notation. A summary full of
/// `**bold**` and `##` headings is exactly what the prompts ask for, so it is
/// exactly what the voice will be handed.
void main() {
  group('speech conversion', () {
    test('drops emphasis markers but keeps the words', () {
      expect(MarkdownText.toSpeech('**Key point** matters'),
          contains('Key point matters'));
      expect(MarkdownText.toSpeech('*italic* text'), contains('italic text'));
      expect(MarkdownText.toSpeech('__bold__ text'), contains('bold text'));
      expect(MarkdownText.toSpeech('**Key point**'), isNot(contains('*')));
    });

    test('drops heading hashes', () {
      final spoken = MarkdownText.toSpeech('## In short\nThe argument.');
      expect(spoken, contains('In short'));
      expect(spoken, isNot(contains('#')));
    });

    test('turns bullets into sentences so the voice pauses', () {
      // Without terminal punctuation the voice runs one point into the next.
      final spoken = MarkdownText.toSpeech('- first point\n- second point');
      expect(spoken, contains('first point.'));
      expect(spoken, contains('second point.'));
      expect(spoken, isNot(contains('- ')));
    });

    test('does not double up punctuation that is already there', () {
      expect(MarkdownText.toSpeech('- Already ends properly.'),
          isNot(contains('..')));
      expect(MarkdownText.toSpeech('- A question?'), isNot(contains('?.')));
    });

    test('handles numbered lists', () {
      final spoken = MarkdownText.toSpeech('1. first\n2) second');
      expect(spoken, contains('first.'));
      expect(spoken, contains('second.'));
      expect(spoken, isNot(contains('1.')));
    });

    test('says the link text, never the URL', () {
      final spoken =
          MarkdownText.toSpeech('See [the paper](https://example.com/x.pdf).');
      expect(spoken, contains('the paper'));
      expect(spoken, isNot(contains('example.com')));
    });

    test('announces code blocks rather than reading the symbols', () {
      final spoken = MarkdownText.toSpeech('Text\n```dart\nvoid main() {}\n```\nMore');
      expect(spoken, contains('code block omitted'));
      expect(spoken, isNot(contains('void main')));
      expect(spoken, isNot(contains('```')));
    });

    test('keeps inline code as words', () {
      expect(MarkdownText.toSpeech('Call `readPage` first'),
          contains('readPage'));
    });

    test('strips blockquote markers and horizontal rules', () {
      final spoken = MarkdownText.toSpeech('> quoted line\n\n---\n\nafter');
      expect(spoken, contains('quoted line'));
      expect(spoken, isNot(contains('>')));
      expect(spoken, isNot(contains('---')));
    });

    test('drops images entirely — there is nothing to say', () {
      final spoken = MarkdownText.toSpeech('![a diagram](figure.png) after');
      expect(spoken, isNot(contains('figure.png')));
      expect(spoken, contains('after'));
    });

    test('a realistic Standard-length answer converts cleanly', () {
      const answer = '''
**In short** — The passage argues that scale changed what AI can do.

**Key points**
- **Energy cost**: training consumes significant electricity.
  - Notes the risk of exhausting public internet data.
- **Model as a service**: lowers the barrier to entry.

**Worth remembering** — Demand rose while the barrier fell.
''';
      final spoken = MarkdownText.toSpeech(answer);
      expect(spoken, isNot(contains('*')));
      expect(spoken, isNot(contains('-  ')));
      expect(spoken, contains('In short'));
      expect(spoken, contains('Energy cost'));
      expect(spoken, contains('Worth remembering'));
    });

    test('plain prose passes through unharmed', () {
      const plain = 'A sentence with no markup at all.';
      expect(MarkdownText.toSpeech(plain), plain);
    });

    test('empty input stays empty rather than becoming a stray full stop', () {
      expect(MarkdownText.toSpeech(''), '');
      expect(MarkdownText.toSpeech('   \n\n  '), '');
    });
  });
}
