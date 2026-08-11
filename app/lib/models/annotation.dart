import 'dart:convert';

/// Highlight colours. Stored by name rather than ARGB so the palette can be
/// retuned (or theme-adapted) without rewriting saved data.
enum HighlightColor {
  yellow,
  green,
  blue,
  pink,
  none; // a note with no highlight

  static HighlightColor from(String? name) => HighlightColor.values
      .firstWhere((c) => c.name == name, orElse: () => HighlightColor.yellow);
}

/// A passage the reader marked, optionally with a note of their own.
///
/// Distinct from a [Bookmark], which marks a *place*. An annotation marks
/// *text*: the quoted passage travels with it, so the note still makes sense
/// when read months later in the notes list, away from the page.
class Annotation {
  const Annotation({
    required this.id,
    required this.page,
    required this.quote,
    required this.createdAt,
    this.note,
    this.color = HighlightColor.yellow,
  });

  /// Stable identity — the creation timestamp in microseconds, which is unique
  /// enough for a single-user local app and sorts naturally.
  final String id;

  final int page;

  /// The highlighted text itself.
  final String quote;

  /// The reader's own words about it.
  final String? note;

  final HighlightColor color;
  final int createdAt;

  bool get hasNote => note != null && note!.trim().isNotEmpty;

  DateTime get created => DateTime.fromMillisecondsSinceEpoch(createdAt);

  Annotation copyWith({String? note, HighlightColor? color}) => Annotation(
        id: id,
        page: page,
        quote: quote,
        createdAt: createdAt,
        note: note ?? this.note,
        color: color ?? this.color,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'page': page,
        'quote': quote,
        'note': note,
        'color': color.name,
        'createdAt': createdAt,
      };

  static Annotation fromJson(Map<String, dynamic> json) => Annotation(
        id: json['id'] as String? ?? '${json['createdAt']}',
        page: json['page'] as int? ?? 1,
        quote: json['quote'] as String? ?? '',
        note: json['note'] as String?,
        color: HighlightColor.from(json['color'] as String?),
        createdAt: json['createdAt'] as int? ?? 0,
      );

  static String encode(List<Annotation> items) =>
      jsonEncode(items.map((a) => a.toJson()).toList());

  /// Always returns a growable list — callers add and remove from it.
  static List<Annotation> decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Annotation>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Annotation.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.page.compareTo(b.page));
    } catch (_) {
      // Corrupt storage loses annotations rather than crashing the reader.
      return <Annotation>[];
    }
  }

  /// Plain-text export, so notes can leave the app and land in anything.
  static String toMarkdown(String bookTitle, List<Annotation> items) {
    final buffer = StringBuffer('# $bookTitle\n\n');
    for (final a in items) {
      buffer.writeln('## Page ${a.page}');
      buffer.writeln();
      for (final line in a.quote.trim().split('\n')) {
        buffer.writeln('> $line');
      }
      buffer.writeln();
      if (a.hasNote) {
        buffer.writeln(a.note!.trim());
        buffer.writeln();
      }
    }
    return buffer.toString();
  }
}
