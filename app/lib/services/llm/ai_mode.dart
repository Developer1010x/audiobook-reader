/// What the user wants the model to *do* with a passage.
///
/// The same chapter serves different purposes: skimming before a meeting,
/// studying for an exam, or preparing for an interview. One generic "summarise"
/// prompt serves none of them well, so each mode carries its own instruction and
/// its own output shape.
enum AiMode {
  /// Plain reading — the gist, fast.
  summary(
    label: 'Summary',
    description: 'The gist, in a few bullets',
    icon: 0xe8d2, // Icons.notes
    prompt: 'Summarise the following passage from a book in {n} short bullet '
        'points. Be concrete, keep the author\'s own terminology, and do not '
        'invent detail that is not in the passage.',
  ),

  /// Studying — explain it, do not just compress it.
  learning(
    label: 'Learning',
    description: 'Explain concepts simply, with examples',
    icon: 0xe80c, // Icons.school
    prompt: 'You are helping someone learn this material properly.\n'
        'For the passage below:\n'
        '1. State the core idea in two sentences, in plain language.\n'
        '2. Explain each key concept ({n} at most), defining any jargon the '
        'passage uses.\n'
        '3. Give one concrete example or analogy for the hardest concept.\n'
        '4. Note anything the passage assumes the reader already knows.\n'
        'Do not invent detail beyond the passage; if something is unclear in '
        'the text, say so.',
  ),

  /// Interview preparation — likely questions and strong answers.
  interview(
    label: 'Interview',
    description: 'Likely questions and strong answers',
    icon: 0xe7fd, // Icons.person
    prompt: 'You are preparing a candidate for a technical interview using the '
        'passage below.\n'
        'Produce {n} interview questions an interviewer could realistically ask '
        'on this material, ordered from foundational to advanced. For each:\n'
        '  Q: the question\n'
        '  A: a strong, concise answer grounded in the passage\n'
        'Favour questions that test understanding over recall. Base every '
        'answer on the passage; do not invent facts.',
  ),

  /// Active recall — self-test material.
  flashcards(
    label: 'Flashcards',
    description: 'Question/answer pairs for revision',
    icon: 0xe06e, // Icons.style
    prompt: 'Create {n} flashcards for active recall from the passage below.\n'
        'Format each as:\n'
        '  Front: a single specific question\n'
        '  Back: the answer in one or two sentences\n'
        'Each card must test exactly one fact or idea. Keep the author\'s '
        'terminology. Use only what is in the passage.',
  ),

  /// Key terms — a glossary for the passage.
  keyTerms(
    label: 'Key terms',
    description: 'Glossary of the terminology used',
    icon: 0xe8f9, // Icons.list_alt
    prompt: 'List the {n} most important technical terms in the passage below.\n'
        'For each: the term, then a one-line definition *as this passage uses '
        'it* — not a generic dictionary definition. If the passage does not '
        'define a term it uses, say "used but not defined here".',
  );

  const AiMode({
    required this.label,
    required this.description,
    required this.icon,
    required this.prompt,
  });

  final String label;
  final String description;
  final int icon;
  final String prompt;

  /// Sensible item count per mode — five bullets is right for a summary, but
  /// five flashcards is thin and five interview questions is about right.
  int get defaultCount => switch (this) {
        AiMode.summary => 5,
        AiMode.learning => 4,
        AiMode.interview => 6,
        AiMode.flashcards => 8,
        AiMode.keyTerms => 8,
      };

  /// The full prompt sent to the model.
  String build(String text, {int? count}) {
    final instruction = prompt.replaceAll('{n}', '${count ?? defaultCount}');
    return '$instruction\n\n---\n\n$text';
  }
}
