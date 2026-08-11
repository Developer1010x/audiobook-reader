import 'dart:async';
import 'dart:math';

import '../concurrency.dart';
import 'ai_mode.dart';
import 'llm_error.dart';
import 'llm_provider.dart';
import 'summary_cache.dart';
import 'summary_length.dart';
import 'usage_ledger.dart';

/// Runs a summary over text of any length.
///
/// **The problem this solves.** Every model has a context window. Sending a
/// whole chapter in one request does not fail loudly — the model silently sees
/// only part of it and summarises that, producing a confident answer about text
/// it never read. That is the worst kind of wrong.
///
/// **The pipeline.** cache → plan → map (bounded parallel, with retry) → reduce
/// → cache. Chunks split on paragraph or sentence boundaries so none starts
/// mid-clause, and each carries a little overlap so an idea spanning a boundary
/// is not lost from both sides.
class Summariser {
  /// Rough tokens-per-character for English prose. Deliberately pessimistic:
  /// under-filling the window wastes a little capacity, over-filling silently
  /// truncates.
  static const _charsPerToken = 3.6;

  /// Characters repeated from the previous chunk, so a sentence split across a
  /// boundary still has context on one side.
  static const _overlapChars = 400;

  static const _maxAttempts = 4;
  static const _baseBackoff = Duration(milliseconds: 700);

  static int estimateTokens(String text) => (text.length / _charsPerToken).ceil();

  static bool needsChunking(String text, LlmProvider provider) =>
      text.length > provider.inputCharBudget;

  static Future<String> run({
    required LlmProvider provider,
    required String text,
    required AiMode mode,
    required SummaryLength length,
    String? model,
    String? apiKey,
    void Function(String stage)? onProgress,
    TokenSink? onDelta,
    CancellationToken? cancel,
    UsageLedger? ledger,
    bool useCache = true,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const InvalidRequest('Nothing to summarise — no text on those pages.');
    }
    cancel?.throwIfCancelled();

    final resolvedModel = model ?? provider.defaultModel;

    // ── cache ──
    final cacheKey = SummaryCache.key(
      text: trimmed,
      mode: mode,
      length: length,
      provider: provider.id,
      model: resolvedModel,
    );
    if (useCache) {
      final hit = await SummaryCache.get(cacheKey);
      if (hit != null) {
        onProgress?.call('From cache — no request made.');
        onDelta?.call(hit);
        return hit;
      }
    }

    final budget = provider.inputCharBudget;
    final result = trimmed.length <= budget
        ? await _singlePass(
            provider: provider,
            text: trimmed,
            mode: mode,
            length: length,
            model: resolvedModel,
            apiKey: apiKey,
            onProgress: onProgress,
            onDelta: onDelta,
            cancel: cancel,
          )
        : await _mapReduce(
            provider: provider,
            text: trimmed,
            mode: mode,
            length: length,
            model: resolvedModel,
            apiKey: apiKey,
            budget: budget,
            onProgress: onProgress,
            onDelta: onDelta,
            cancel: cancel,
          );

    await ledger?.record(
      provider: provider.id,
      inputTokens: result.inputTokens,
      outputTokens: result.outputTokens,
    );

    if (useCache) {
      await SummaryCache.put(cacheKey, result.text, meta: {
        'provider': provider.id,
        'model': resolvedModel,
        'inputTokens': result.inputTokens,
        'outputTokens': result.outputTokens,
      });
    }
    return result.text;
  }

  // ── single pass ──

  static Future<LlmResult> _singlePass({
    required LlmProvider provider,
    required String text,
    required AiMode mode,
    required SummaryLength length,
    required String model,
    String? apiKey,
    void Function(String stage)? onProgress,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) {
    onProgress?.call('Summarising ~${estimateTokens(text)} tokens…');
    return _withRetry(
      provider: provider,
      onProgress: onProgress,
      cancel: cancel,
      attempt: () => provider.generate(
        text,
        model: model,
        apiKey: apiKey,
        mode: mode,
        length: length,
        onDelta: onDelta,
        cancel: cancel,
      ),
    );
  }

  // ── map / reduce ──

  static Future<LlmResult> _mapReduce({
    required LlmProvider provider,
    required String text,
    required AiMode mode,
    required SummaryLength length,
    required String model,
    required int budget,
    String? apiKey,
    void Function(String stage)? onProgress,
    TokenSink? onDelta,
    CancellationToken? cancel,
  }) async {
    final chunks = chunk(text, budget);
    onProgress?.call(
      '${text.length ~/ 1000}k characters — reading in ${chunks.length} parts…',
    );

    var done = 0;
    // Chunks are independent by construction, so a hosted provider can process
    // several at once — on an eight-part chapter that is roughly four times
    // less waiting. Order is preserved by mapBounded, which matters: notes
    // assembled by completion order would scramble the chapter.
    final notes = await Concurrency.mapBounded<String, LlmResult>(
      chunks,
      (part, index) async {
        final result = await _withRetry(
          provider: provider,
          onProgress: onProgress,
          cancel: cancel,
          // The map stage is not streamed: fragments from parallel workers would
          // interleave into nonsense on screen.
          attempt: () => provider.generate(
            part,
            model: model,
            apiKey: apiKey,
            mode: AiMode.summary,
            length: SummaryLength.standard,
            promptOverride: _mapPrompt(index + 1, chunks.length),
            cancel: cancel,
          ),
        );
        done++;
        onProgress?.call('Read $done of ${chunks.length} parts…');
        return result;
      },
    );

    var totalIn = 0, totalOut = 0;
    final combined = <String>[];
    for (var i = 0; i < notes.length; i++) {
      totalIn += notes[i].inputTokens;
      totalOut += notes[i].outputTokens;
      combined.add('--- Part ${i + 1} of ${notes.length} ---\n${notes[i].text}');
    }

    cancel?.throwIfCancelled();
    onProgress?.call('Combining ${chunks.length} parts…');

    var reducible = combined.join('\n\n');
    // Pathological case: so many parts that the notes themselves overflow.
    // Condense once more rather than truncating them.
    if (reducible.length > budget) {
      final condensed = await _condense(
          reducible, provider, budget, model, apiKey, onProgress, cancel);
      totalIn += condensed.inputTokens;
      totalOut += condensed.outputTokens;
      reducible = condensed.text;
    }

    final finalResult = await _withRetry(
      provider: provider,
      onProgress: onProgress,
      cancel: cancel,
      attempt: () => provider.generate(
        reducible,
        model: model,
        apiKey: apiKey,
        mode: mode,
        length: length,
        promptOverride: _reducePrompt(mode, length, chunks.length),
        onDelta: onDelta,
        cancel: cancel,
      ),
    );

    return LlmResult(
      text: finalResult.text,
      inputTokens: totalIn + finalResult.inputTokens,
      outputTokens: totalOut + finalResult.outputTokens,
    );
  }

  static Future<LlmResult> _condense(
    String notes,
    LlmProvider provider,
    int budget,
    String model,
    String? apiKey,
    void Function(String stage)? onProgress,
    CancellationToken? cancel,
  ) async {
    final parts = chunk(notes, budget);
    final out = StringBuffer();
    var totalIn = 0, totalOut = 0;
    for (var i = 0; i < parts.length; i++) {
      cancel?.throwIfCancelled();
      onProgress?.call('Condensing notes ${i + 1}/${parts.length}…');
      final r = await _withRetry(
        provider: provider,
        onProgress: onProgress,
        cancel: cancel,
        attempt: () => provider.generate(
          parts[i],
          model: model,
          apiKey: apiKey,
          length: SummaryLength.brief,
          promptOverride:
              'Condense these notes, losing no distinct fact. Bullet points only.',
          cancel: cancel,
        ),
      );
      totalIn += r.inputTokens;
      totalOut += r.outputTokens;
      out.writeln(r.text);
      out.writeln();
    }
    return LlmResult(
      text: out.toString(),
      inputTokens: totalIn,
      outputTokens: totalOut,
    );
  }

  // ── execution primitives ──

  /// Retry only what is worth retrying.
  ///
  /// Exponential backoff with jitter, honouring a provider-supplied delay when
  /// there is one. A bad API key fails on the first attempt rather than four
  /// times over twelve seconds.
  static Future<LlmResult> _withRetry({
    required LlmProvider provider,
    required Future<LlmResult> Function() attempt,
    void Function(String stage)? onProgress,
    CancellationToken? cancel,
  }) async {
    LlmError? last;
    for (var i = 0; i < _maxAttempts; i++) {
      cancel?.throwIfCancelled();
      try {
        return await attempt();
      } on Cancelled {
        rethrow;
      } on LlmError catch (e) {
        last = e;
        if (!e.isRetryable || i == _maxAttempts - 1) rethrow;

        final wait = e.retryAfter ??
            Duration(
              milliseconds: (_baseBackoff.inMilliseconds * pow(2, i)).round() +
                  Random().nextInt(250),
            );
        onProgress?.call(
          '${e.message} Retrying in ${(wait.inMilliseconds / 1000).toStringAsFixed(1)}s '
          '(${i + 2}/$_maxAttempts)…',
        );
        await Future<void>.delayed(wait);
      }
    }
    throw last ?? const ProviderUnavailable('Failed after retries.');
  }

  // ── prompts ──

  static String _mapPrompt(int part, int total) =>
      'These are pages $part of $total from a longer passage. Extract the key '
      'points as compact notes — facts, definitions, arguments and terminology. '
      'Do not write an introduction or conclusion; these notes will be combined '
      'with notes from the other parts. Keep the author\'s own terms. Do not '
      'invent anything not present in this text.';

  static String _reducePrompt(AiMode mode, SummaryLength length, int parts) =>
      'Below are notes taken from $parts consecutive sections of one passage.\n'
      'Working ONLY from these notes, produce the final answer.\n\n'
      '${mode.prompt.replaceAll('{n}', '${length.count}')}\n\n'
      '${length.instruction}\n\n'
      'Merge duplicate points across sections rather than repeating them, and '
      'keep the original order of ideas.';

  // ── chunking ──

  /// Split [text] into chunks of at most [budget] characters.
  ///
  /// Prefers paragraph breaks, falls back to sentence ends, and only cuts
  /// mid-sentence for a single sentence longer than the whole budget.
  static List<String> chunk(String text, int budget) {
    if (budget <= 0) return [text];
    if (text.length <= budget) return [text];

    final chunks = <String>[];
    var start = 0;

    while (start < text.length) {
      var end = start + budget;
      if (end >= text.length) {
        chunks.add(text.substring(start).trim());
        break;
      }

      // Search backwards from the limit for a clean break, but not so far back
      // that chunks become tiny.
      final floor = start + (budget * 0.5).round();
      var cut = text.lastIndexOf('\n\n', end);
      if (cut < floor) cut = _lastSentenceEnd(text, floor, end);
      if (cut < floor) cut = end; // no boundary found; hard cut

      chunks.add(text.substring(start, cut).trim());
      // Step back a little so an idea straddling the cut survives on one side.
      start = (cut - _overlapChars) > start ? cut - _overlapChars : cut;
    }

    return chunks.where((c) => c.isNotEmpty).toList();
  }

  static int _lastSentenceEnd(String text, int floor, int end) {
    for (var i = end; i > floor; i--) {
      final c = text.codeUnitAt(i);
      if (c == 0x2E || c == 0x21 || c == 0x3F) return i + 1; // . ! ?
    }
    return -1;
  }
}
