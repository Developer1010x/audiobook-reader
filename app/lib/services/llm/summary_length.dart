/// How much output the user wants back.
///
/// Length is a separate axis from [AiMode]: "give me interview questions" and
/// "give me one line" are independent choices, and forcing them into one list
/// would mean five modes × four lengths of enum.
enum SummaryLength {
  oneLine(
    label: 'One line',
    hint: 'A single sentence',
    count: 1,
    instruction:
        'Answer in EXACTLY ONE sentence of at most 30 words. No bullet points, '
        'no preamble, no heading — just the sentence.',
  ),

  brief(
    label: 'Brief',
    hint: '3 points',
    count: 3,
    instruction: 'Give exactly 3 short bullet points. One line each.',
  ),

  standard(
    label: 'Standard',
    hint: '6 points',
    count: 6,
    instruction: 'Give about 6 bullet points, one or two lines each.',
  ),

  detailed(
    label: 'Detailed',
    hint: '12+ points, sub-detail',
    count: 12,
    instruction:
        'Be thorough: at least 12 points, grouped under short headings, with '
        'sub-points where the material has structure. Do not pad — if the '
        'passage is thin, say so rather than inventing detail.',
  );

  const SummaryLength({
    required this.label,
    required this.hint,
    required this.count,
    required this.instruction,
  });

  final String label;
  final String hint;

  /// Item count handed to the mode's `{n}` placeholder.
  final int count;

  /// Appended to the mode prompt to pin the output size.
  final String instruction;

  /// One line is a hard constraint that overrides a mode's natural shape —
  /// "one-line flashcards" is incoherent, so the mode prompt is suppressed.
  bool get overridesShape => this == SummaryLength.oneLine;
}
