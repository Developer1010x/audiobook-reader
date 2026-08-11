/// How much output the user wants back.
///
/// Length is a separate axis from [AiMode]: "give me interview questions" and
/// "give me one line" are independent choices, and folding them together would
/// mean five modes × five lengths of enum.
///
/// **These instructions carry most of the quality.** A small local model asked
/// for "6 bullet points" returns six restatements of the passage's topic
/// sentences — technically a summary, useless as study material. Naming the
/// *shape* of a good answer (what must appear, what must not) pulls far more
/// out of the same model than asking for more bullets does.
enum SummaryLength {
  oneLine(
    label: 'One line',
    hint: 'A single sentence',
    count: 1,
    instruction:
        'Answer in EXACTLY ONE sentence of at most 30 words, naming the single '
        'most important claim the passage makes. No bullet points, no preamble, '
        'no heading, no restating the topic — the claim itself.',
  ),

  brief(
    label: 'Brief',
    hint: '3 substantive points',
    count: 3,
    instruction:
        'Give exactly 3 bullet points, each one sentence.\n'
        'Each must state something the passage actually ARGUES or ESTABLISHES — '
        'a claim, a definition, a causal link, a number. Do not write bullets '
        'that merely name a topic ("discusses X", "covers Y"): say what the '
        'passage says about it.',
  ),

  standard(
    label: 'Standard',
    hint: 'Structured, with detail under each point',
    count: 5,
    instruction:
        'Structure the answer as:\n'
        '**In short** — two sentences capturing the passage\'s central argument.\n'
        '**Key points** — about 5 bullets. Each begins with a bold 2–5 word '
        'label, then a sentence of substance, then where it helps an indented '
        'sub-bullet with the concrete detail: the number, the example, the '
        'definition, the caveat the author attaches.\n'
        '**Worth remembering** — one line naming the single thing most worth '
        'carrying away.\n\n'
        'Rules: prefer specifics over generalities. If the passage gives a '
        'figure, a name or an example, it belongs in the summary. Never write a '
        'bullet that would be true of any passage on this subject.',
  ),

  detailed(
    label: 'Detailed',
    hint: 'Full breakdown with terms and open questions',
    count: 10,
    instruction:
        'Produce a thorough breakdown, structured as:\n'
        '**In short** — three sentences on the central argument and why it '
        'matters.\n'
        '**The argument, step by step** — walk the passage\'s reasoning in '
        'order, one bullet per move, showing how each step follows from the '
        'last. Quote the author\'s own phrasing for anything load-bearing.\n'
        '**Specifics** — every concrete figure, name, example, dataset or '
        'result the passage gives, with what each one demonstrates.\n'
        '**Terms defined here** — each technical term the passage introduces, '
        'defined AS THIS PASSAGE USES IT.\n'
        '**Assumed knowledge** — what the author takes for granted that a '
        'reader might not have.\n'
        '**Open questions** — what the passage raises but does not settle.\n\n'
        'Rules: depth means detail actually present in the text, never padding. '
        'If a section has nothing to fill it, write "nothing in this passage" '
        'and move on. Do not invent, extrapolate, or add general knowledge from '
        'outside the passage.',
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

  /// Appended to the mode prompt to pin the output's size and shape.
  final String instruction;

  /// One line is a hard constraint that overrides a mode's natural shape —
  /// "one-line flashcards" is incoherent, so the mode prompt is suppressed.
  bool get overridesShape => this == SummaryLength.oneLine;

  /// Room the model needs to actually produce this.
  ///
  /// Left unset, a local model stops mid-answer on the longer shapes, which
  /// reads as a bad summary rather than a truncated one.
  int get outputTokenBudget => switch (this) {
        SummaryLength.oneLine => 120,
        SummaryLength.brief => 400,
        SummaryLength.standard => 1200,
        SummaryLength.detailed => 3000,
      };
}
