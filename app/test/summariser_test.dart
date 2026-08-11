import 'package:audiobook_reader/services/llm/ai_mode.dart';
import 'package:audiobook_reader/services/llm/llm_provider.dart';
import 'package:audiobook_reader/services/llm/summariser.dart';
import 'package:audiobook_reader/services/llm/summary_length.dart';
import 'package:flutter_test/flutter_test.dart';

/// A provider that records every call instead of making one, so the map-reduce
/// control flow can be tested without a model.
class FakeProvider extends LlmProvider {
  final int budgetTokens;
  final List<String> prompts = [];
  final List<String> inputs = [];

  FakeProvider({this.budgetTokens = 1000});

  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get defaultModel => 'fake-1';
  @override
  List<String> get suggestedModels => ['fake-1'];
  @override
  bool get isCloud => false;
  @override
  String? get keyName => null;
  @override
  String? get keyUrl => null;
  @override
  int get contextTokens => budgetTokens;

  @override
  Future<String> summarise(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
  }) async {
    inputs.add(text);
    prompts.add(promptOverride ?? mode.prompt);
    return 'notes(${text.length})';
  }
}

void main() {
  String words(int count) => List.filled(count, 'word').join(' ');

  group('chunking', () {
    test('short text is left as a single chunk', () {
      final chunks = Summariser.chunk('One sentence only.', 1000);
      expect(chunks, hasLength(1));
    });

    test('long text is split into several chunks', () {
      final chunks = Summariser.chunk(words(4000), 1000);
      expect(chunks.length, greaterThan(1));
    });

    test('no chunk grossly exceeds the budget', () {
      final chunks = Summariser.chunk(words(4000), 1000);
      for (final c in chunks) {
        expect(c.length, lessThanOrEqualTo(1100), reason: 'chunk overshoot');
      }
    });

    test('prefers paragraph boundaries', () {
      final text = '${'a' * 600}\n\n${'b' * 600}';
      final chunks = Summariser.chunk(text, 800);
      // The first chunk should end at the paragraph break, not mid-run.
      expect(chunks.first.endsWith('a'), isTrue);
      expect(chunks.first.contains('b'), isFalse);
    });

    test('falls back to sentence ends when there is no paragraph break', () {
      final sentence = '${'x' * 90}. ';
      final chunks = Summariser.chunk(sentence * 20, 500);
      expect(chunks.length, greaterThan(1));
      // Every chunk but the last should finish a sentence.
      for (final c in chunks.take(chunks.length - 1)) {
        expect(c.trim().endsWith('.'), isTrue);
      }
    });

    test('covers the whole text — nothing is dropped', () {
      final text = List.generate(60, (i) => 'Sentence number $i.').join(' ');
      final chunks = Summariser.chunk(text, 300);
      final joined = chunks.join(' ');
      for (var i = 0; i < 60; i++) {
        expect(joined, contains('Sentence number $i.'), reason: 'lost $i');
      }
    });

    test('a single unbreakable run still terminates', () {
      final chunks = Summariser.chunk('z' * 5000, 500);
      expect(chunks.length, greaterThan(1));
      expect(chunks.join().length, greaterThanOrEqualTo(5000 - 100));
    });
  });

  group('needsChunking', () {
    test('is false for text inside the budget, true beyond it', () {
      final provider = FakeProvider(budgetTokens: 1000);
      expect(Summariser.needsChunking('short', provider), isFalse);
      expect(
        Summariser.needsChunking('x' * (provider.inputCharBudget + 1), provider),
        isTrue,
      );
    });
  });

  group('single pass', () {
    test('text that fits makes exactly one request', () async {
      final provider = FakeProvider(budgetTokens: 4000);
      await Summariser.run(
        provider: provider,
        text: 'A short passage that easily fits.',
        mode: AiMode.summary,
        length: SummaryLength.brief,
      );
      expect(provider.inputs, hasLength(1));
    });

    test('empty text is rejected before any request', () async {
      final provider = FakeProvider();
      await expectLater(
        Summariser.run(
          provider: provider,
          text: '   ',
          mode: AiMode.summary,
          length: SummaryLength.brief,
        ),
        throwsA(isA<LlmException>()),
      );
      expect(provider.inputs, isEmpty);
    });
  });

  group('map-reduce', () {
    test('long text becomes N map calls plus one reduce', () async {
      final provider = FakeProvider(budgetTokens: 500);
      final long = words(3000);
      expect(Summariser.needsChunking(long, provider), isTrue);

      await Summariser.run(
        provider: provider,
        text: long,
        mode: AiMode.summary,
        length: SummaryLength.standard,
      );

      final chunks = Summariser.chunk(long, provider.inputCharBudget);
      // One call per chunk, plus the final combine.
      expect(provider.inputs, hasLength(chunks.length + 1));
    });

    test('the reduce step sees the notes, not the raw text', () async {
      final provider = FakeProvider(budgetTokens: 500);
      await Summariser.run(
        provider: provider,
        text: words(3000),
        mode: AiMode.summary,
        length: SummaryLength.brief,
      );
      final last = provider.inputs.last;
      expect(last, contains('notes('));
      expect(last, contains('Part 1 of'));
    });

    test('map stages use the note-taking prompt, the reduce uses the mode', () async {
      final provider = FakeProvider(budgetTokens: 500);
      await Summariser.run(
        provider: provider,
        text: words(3000),
        mode: AiMode.interview,
        length: SummaryLength.standard,
      );
      expect(provider.prompts.first, contains('compact notes'));
      expect(provider.prompts.last, contains('interview'));
    });

    test('progress is reported for each part', () async {
      final provider = FakeProvider(budgetTokens: 500);
      final stages = <String>[];
      await Summariser.run(
        provider: provider,
        text: words(3000),
        mode: AiMode.summary,
        length: SummaryLength.standard,
        onProgress: stages.add,
      );
      expect(stages.any((s) => s.contains('Reading part 1')), isTrue);
      expect(stages.any((s) => s.contains('Combining')), isTrue);
    });
  });

  group('token estimate', () {
    test('scales with length and is never zero for real text', () {
      expect(Summariser.estimateTokens('hello world'), greaterThan(0));
      expect(
        Summariser.estimateTokens(words(1000)),
        greaterThan(Summariser.estimateTokens(words(100))),
      );
    });
  });
}
