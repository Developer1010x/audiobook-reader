/// A user's list of words the voice gets wrong, and how to say them instead.
///
/// Stored and edited as plain lines, `term = spoken as`, because that is the
/// one format that needs no explanation in a text box. Applied to the text just
/// before it is spoken, so every engine (Piper, espeak-ng, the system voice)
/// benefits and the page itself is never changed.
class Pronunciations {
  const Pronunciations._();

  /// Parse `term = spoken as` lines. Blank lines, `#` comments and lines with
  /// no `=` or an empty side are skipped rather than rejected: a half-typed
  /// line must not throw away the rest of the list.
  static Map<String, String> parse(String? source) {
    final rules = <String, String>{};
    if (source == null) return rules;
    for (final line in source.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final term = trimmed.substring(0, eq).trim();
      final spoken = trimmed.substring(eq + 1).trim();
      if (term.isEmpty || spoken.isEmpty) continue;
      rules[term] = spoken;
    }
    return rules;
  }

  /// The inverse of [parse], one rule per line.
  static String format(Map<String, String> rules) =>
      [for (final e in rules.entries) '${e.key} = ${e.value}'].join('\n');

  /// Replace each whole-word, case-insensitive occurrence of a term.
  ///
  /// Whole words only, so a rule for "Ra" does not rewrite "Rachel". Longer
  /// terms win over shorter ones that overlap them ("New York" before "York"),
  /// and the replacement is a single pass, so a spoken form that contains
  /// another term is never rewritten again.
  static String apply(String text, Map<String, String> rules) {
    if (rules.isEmpty || text.isEmpty) return text;
    final terms = rules.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    final lookup = {for (final t in terms) t.toLowerCase(): rules[t]!};
    // Lookarounds instead of \b, which only works when the term starts and
    // ends with a word character — "C++" or ".NET" would never match.
    final pattern = RegExp(
      '(?<![\\w])(?:${terms.map(RegExp.escape).join('|')})(?![\\w])',
      caseSensitive: false,
      unicode: true,
    );
    return text.replaceAllMapped(
        pattern, (m) => lookup[m.group(0)!.toLowerCase()] ?? m.group(0)!);
  }
}
