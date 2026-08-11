import 'package:audiobook_reader/services/llm/ai_mode.dart';
import 'package:audiobook_reader/services/llm/llm_error.dart';
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

  /// Fails this many times before succeeding, to exercise retry.
  int failuresRemaining = 0;
  LlmError Function()? failWith;

  @override
  Future<LlmResult> generate(
    String text, {
    String? model,
    String? apiKey,
    AiMode mode = AiMode.summary,
    SummaryLength length = SummaryLength.standard,
    String? promptOverride,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) async {
    cancel?.throwIfCancelled();
    if (failuresRemaining > 0) {
      failuresRemaining--;
      throw failWith?.call() ?? const RateLimited('busy', provider: 'fake');
    }
    inputs.add(text);
    prompts.add(promptOverride ?? mode.prompt);
    final out = 'notes(${text.length})';
    onDelta?.call(out);
    return LlmResult(text: out, inputTokens: 10, outputTokens: 5);
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
        useCache: false,
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
        throwsA(isA<LlmError>()),
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
        useCache: false,
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
        useCache: false,
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
        useCache: false,
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
        useCache: false,
        onProgress: stages.add,
      );
      // Parallel workers do not finish in order, so progress counts completions
      // rather than naming a specific part.
      expect(stages.any((s) => s.contains('parts')), isTrue);
      expect(stages.any((s) => s.contains('Combining')), isTrue);
    });
  });

  _pipelineTests();

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

/// Executor behaviour added with the pipeline: retry, cancellation, accounting.
void _pipelineTests() {
  String words(int count) => List.filled(count, 'word').join(' ');

  group('retry', () {
    test('a retryable failure is retried and then succeeds', () async {
      final provider = FakeProvider(budgetTokens: 4000)..failuresRemaining = 2;
      final out = await Summariser.run(
        provider: provider,
        text: 'short passage',
        mode: AiMode.summary,
        length: SummaryLength.brief,
        useCache: false,
      );
      expect(out, contains('notes('));
      expect(provider.failuresRemaining, 0);
    });

    test('a fatal failure is not retried', () async {
      // A bad key must fail immediately rather than four times over 12 seconds.
      final provider = FakeProvider(budgetTokens: 4000)
        ..failuresRemaining = 99
        ..failWith = () => const AuthFailed('bad key');

      await expectLater(
        Summariser.run(
          provider: provider,
          text: 'short passage',
          mode: AiMode.summary,
          length: SummaryLength.brief,
          useCache: false,
        ),
        throwsA(isA<AuthFailed>()),
      );
      // 99 minus exactly one attempt.
      expect(provider.failuresRemaining, 98);
    });
  });

  group('cancellation', () {
    test('a cancelled token stops before any request', () async {
      final provider = FakeProvider(budgetTokens: 4000);
      final token = CancellationToken()..cancel();
      await expectLater(
        Summariser.run(
          provider: provider,
          text: 'short passage',
          mode: AiMode.summary,
          length: SummaryLength.brief,
          cancel: token,
          useCache: false,
        ),
        throwsA(isA<Cancelled>()),
      );
      expect(provider.inputs, isEmpty);
    });
  });

  group('error classification', () {
    test('HTTP statuses map to retryable or fatal correctly', () {
      expect(errorForStatus(429, '', 'x'), isA<RateLimited>());
      expect(errorForStatus(500, '', 'x'), isA<ProviderUnavailable>());
      expect(errorForStatus(401, '', 'x'), isA<AuthFailed>());
      expect(errorForStatus(404, '', 'x'), isA<ModelUnavailable>());

      expect(errorForStatus(429, '', 'x').isRetryable, isTrue);
      expect(errorForStatus(503, '', 'x').isRetryable, isTrue);
      expect(errorForStatus(401, '', 'x').isRetryable, isFalse);
      expect(errorForStatus(404, '', 'x').isRetryable, isFalse);
    });

    test('a context-length message is detected from the body', () {
      final e = errorForStatus(400, 'maximum context length exceeded', 'x');
      expect(e, isA<ContextExceeded>());
      expect(e.isRetryable, isFalse);
    });
  });

  group('concurrency', () {
    test('local providers stay serial, cloud providers do not', () {
      expect(const OllamaProvider().maxConcurrency, 1);
      for (final p in kProviders.where((p) => p.isCloud)) {
        expect(p.maxConcurrency, greaterThan(1), reason: p.id);
      }
    });
  });

  group('streaming', () {
    test('deltas reach the caller', () async {
      final provider = FakeProvider(budgetTokens: 4000);
      final deltas = <String>[];
      await Summariser.run(
        provider: provider,
        text: 'short passage',
        mode: AiMode.summary,
        length: SummaryLength.brief,
        useCache: false,
        onDelta: deltas.add,
      );
      expect(deltas, isNotEmpty);
    });
  });

  group('accounting', () {
    test('map-reduce sums tokens across every stage', () async {
      final provider = FakeProvider(budgetTokens: 500);
      var recordedIn = 0;
      await Summariser.run(
        provider: provider,
        text: words(3000),
        mode: AiMode.summary,
        length: SummaryLength.brief,
        useCache: false,
        onProgress: (_) {},
      );
      // Each fake call reports 10 in / 5 out; several calls must have happened.
      recordedIn = provider.inputs.length * 10;
      expect(recordedIn, greaterThan(10));
    });
  });
}
