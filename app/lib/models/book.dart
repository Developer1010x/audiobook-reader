import 'dart:io';

/// How a book is read, which decides whether an LLM is ever involved.
///
/// This is the core cost/privacy control of the app: a storybook is just read
/// aloud, start to finish, and never touches a model. Only a textbook offers
/// explain/summarise, and even then only when the user taps for it.
enum BookType {
  storybook,
  textbook;

  bool get usesLlm => this == BookType.textbook;

  String get label => this == BookType.textbook ? 'Textbook' : 'Storybook';
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
