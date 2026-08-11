import 'dart:convert';

/// A saved position in a book, with a snippet so the list is readable without
/// opening each one.
class Bookmark {
  final int page;

  /// First line or so of the page, captured when the bookmark was made.
  final String preview;

  /// Optional note the user typed.
  final String? note;

  /// Milliseconds since epoch — stored rather than a DateTime so the JSON is
  /// stable and sortable.
  final int createdAt;

  const Bookmark({
    required this.page,
    required this.preview,
    required this.createdAt,
    this.note,
  });

  DateTime get created => DateTime.fromMillisecondsSinceEpoch(createdAt);

  Bookmark copyWith({String? note}) => Bookmark(
        page: page,
        preview: preview,
        createdAt: createdAt,
        note: note ?? this.note,
      );

  Map<String, dynamic> toJson() => {
        'page': page,
        'preview': preview,
        'note': note,
        'createdAt': createdAt,
      };

  static Bookmark fromJson(Map<String, dynamic> json) => Bookmark(
        page: json['page'] as int,
        preview: json['preview'] as String? ?? '',
        note: json['note'] as String?,
        createdAt: json['createdAt'] as int? ?? 0,
      );

  static String encode(List<Bookmark> bookmarks) =>
      jsonEncode(bookmarks.map((b) => b.toJson()).toList());

  /// Always returns a *growable* list. Callers mutate the result (add/remove a
  /// bookmark), so handing back `const []` on the empty path would throw
  /// "Cannot remove from an unmodifiable list" on the very first bookmark.
  static List<Bookmark> decode(String? raw) {
    if (raw == null || raw.isEmpty) return <Bookmark>[];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Bookmark.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.page.compareTo(b.page));
    } catch (_) {
      // Corrupt storage should lose bookmarks, not crash the reader.
      return <Bookmark>[];
    }
  }
}
