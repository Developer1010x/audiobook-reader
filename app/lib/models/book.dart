import 'dart:io';

/// How a book is read, which decides whether an LLM is ever involved.
///
/// This is the core cost/privacy control of the app: a storybook is just read
/// aloud, start to finish, and never touches a model. Only a textbook offers
/// explain/summarise, and even then only when the user taps for it.
/// What kind of document this is, which decides how the app treats it.
///
/// This is not a taxonomy for its own sake — the type drives real behaviour:
/// whether AI study aids are offered at all, which AI mode makes sense by
/// default, and how the reader presents the text. A novel and a lab manual want
/// opposite things from the same app.
enum BookType {
  storybook(
    label: 'Storybook',
    description: 'Fiction and narrative — read start to finish',
    usesLlm: false,
  ),

  textbook(
    label: 'Textbook',
    description: 'Study material — explanations, exercises, diagrams',
    usesLlm: true,
  ),

  documentation(
    label: 'Documentation',
    description: 'Reference and manuals — looked up, not read through',
    usesLlm: true,
  ),

  paper(
    label: 'Paper',
    description: 'Research — abstract, method, results, citations',
    usesLlm: true,
  ),

  letter(
    label: 'Letter',
    description: 'Correspondence, memos and short documents',
    usesLlm: true,
  ),

  notes(
    label: 'Notes',
    description: 'Your own notes and drafts',
    usesLlm: false,
  ),

  magazine(
    label: 'Magazine',
    description: 'Articles and periodicals — browsed by piece',
    usesLlm: false,
  );

  const BookType({
    required this.label,
    required this.description,
    required this.usesLlm,
  });

  final String label;
  final String description;

  /// Whether AI study aids are offered for this kind of document.
  ///
  /// A storybook has no path to a model at all: the button is never built, so
  /// nothing can send a novel to an API by accident.
  final bool usesLlm;

  /// The AI mode that fits this kind of document, used as the starting point
  /// rather than always defaulting to a plain summary.
  String get defaultAiMode => switch (this) {
        BookType.textbook => 'learning',
        BookType.paper => 'keyTerms',
        BookType.documentation => 'keyTerms',
        BookType.letter => 'summary',
        _ => 'summary',
      };

  /// Types worth offering when the user overrides the automatic choice.
  static List<BookType> get selectable => BookType.values;

  static BookType from(String? name) => BookType.values
      .firstWhere((t) => t.name == name, orElse: () => BookType.storybook);
}

/// A book in the library. Metadata only — the file is read in place, never copied.
class Book {
  final File file;
  final String title;
  final String ext;
  final int sizeBytes;

  /// Null until the book has been classified (which needs its text).
  final BookType? type;

  /// True when [type] came from the user overriding the auto-detection.
  final bool typeIsManual;

  const Book({
    required this.file,
    required this.title,
    required this.ext,
    required this.sizeBytes,
    this.type,
    this.typeIsManual = false,
  });

  String get path => file.path;

  /// Stable identity across runs. The path is the natural key — two files with
  /// the same title are genuinely different books.
  String get id => file.path;

  Book copyWith({BookType? type, bool? typeIsManual}) => Book(
    file: file,
    title: title,
    ext: ext,
    sizeBytes: sizeBytes,
    type: type ?? this.type,
    typeIsManual: typeIsManual ?? this.typeIsManual,
  );

  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(sizeBytes / 1024).round()} KB';
  }
}
