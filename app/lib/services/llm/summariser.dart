import 'ai_mode.dart';
import 'llm_provider.dart';
import 'summary_length.dart';

/// Runs a summary over text of any length.
///
/// **The problem this solves.** Every model has a context window. Sending a
/// whole chapter in one request does not fail loudly — the model silently sees
/// only part of it and summarises that, producing a confident answer about text
/// it never read. That is the worst kind of wrong.
///
/// **The approach.** If the text fits, one request. If it does not, map-reduce:
/// each chunk is condensed to notes (the *map*), then the notes are summarised
/// into the final answer (the *reduce*). Chunks split on paragraph or sentence
/// boundaries so no chunk starts mid-clause, and each carries a little overlap
/// so an idea spanning a boundary is not lost from both sides.
class Summariser {
  /// Rough tokens-per-character for English prose. Deliberately pessimistic:
  /// under-filling the window wastes a little capacity, over-filling silently
  /// truncates.
  static const _charsPerToken = 3.6;

  /// Characters repeated from the previous chunk, so a sentence split across a
  /// boundary still has context on one side.
  static const _overlapChars = 400;

  static int estimateTokens(String text) => (text.length / _charsPerToken).ceil();

  /// Whether [text] would need chunking for [provider].
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
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const LlmException('Nothing to summarise — no text on those pages.');
    }

    final budget = provider.inputCharBudget;

    // Fits in one request: no need to pay for two round trips or lose fidelity
    // to an intermediate condensation step.
    if (trimmed.length <= budget) {
      onProgress?.call('Summarising ${estimateTokens(trimmed)} tokens…');
      return provider.summarise(
        trimmed,
        model: model,
        apiKey: apiKey,
        mode: mode,
        length: length,
      );
    }

    final chunks = chunk(trimmed, budget);
    onProgress?.call(
      '${trimmed.length ~/ 1000}k characters — reading in ${chunks.length} parts…',
    );

    // ── map ──
    final notes = <String>[];
    for (var i = 0; i < chunks.length; i++) {
      onProgress?.call('Reading part ${i + 1} of ${chunks.length}…');
      final note = await provider.summarise(
        chunks[i],
        model: model,
        apiKey: apiKey,
        mode: AiMode.summary,
        length: SummaryLength.standard,
        promptOverride: _mapPrompt(i + 1, chunks.length),
      );
      notes.add('--- Part ${i + 1} of ${chunks.length} ---\n$note');
    }

    // ── reduce ──
    onProgress?.call('Combining ${chunks.length} parts…');
    final combined = notes.join('\n\n');

    // Pathological case: so many parts that the notes themselves overflow.
    // Condense the notes once more rather than truncating them.
    final reducible = combined.length > budget
        ? await _condense(
            combined, provider, budget, model, apiKey, onProgress)
        : combined;

    return provider.summarise(
      reducible,
      model: model,
      apiKey: apiKey,
      mode: mode,
      length: length,
      promptOverride: _reducePrompt(mode, length, chunks.length),
    );
  }

  static Future<String> _condense(
    String notes,
    LlmProvider provider,
    int budget,
    String? model,
    String? apiKey,
    void Function(String stage)? onProgress,
  ) async {
    final parts = chunk(notes, budget);
    final out = <String>[];
    for (var i = 0; i < parts.length; i++) {
      onProgress?.call('Condensing notes ${i + 1}/${parts.length}…');
      out.add(await provider.summarise(
        parts[i],
        model: model,
        apiKey: apiKey,
        mode: AiMode.summary,
        length: SummaryLength.brief,
        promptOverride:
            'Condense these notes, losing no distinct fact. Bullet points only.',
      ));
    }
    return out.join('\n\n');
  }

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
      if (cut < floor) {
        cut = _lastSentenceEnd(text, floor, end);
      }
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
