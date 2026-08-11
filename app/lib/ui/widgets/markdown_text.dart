import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Renders Markdown the way this app needs it.
///
/// Models answer in Markdown whether or not you ask them to — `**bold**`,
/// bullets, headings — and the prompts here deliberately *request* that
/// structure because it is what makes a summary scannable. Showing the raw
/// asterisks was throwing that away and making the output harder to read than
/// plain prose would have been.
///
/// Also used for `.md` books, so a README reads as a document rather than as
/// source.
class MarkdownText extends StatelessWidget {
  const MarkdownText(
    this.data, {
    super.key,
    this.selectable = true,
    this.textScale = 1.0,
    this.padding = EdgeInsets.zero,
    this.onTapLink,
  });

  final String data;
  final bool selectable;

  /// Multiplies the base size, for the reader's text-size control.
  final double textScale;

  final EdgeInsets padding;
  final void Function(String text, String? href, String title)? onTapLink;

  @override
  Widget build(BuildContext context) {
    return MarkdownBody(
      data: data,
      selectable: selectable,
      onTapLink: onTapLink,
      styleSheet: styleSheetFor(context, textScale: textScale),
    );
  }

  /// Shared style sheet so AI output and `.md` books look like one app.
  ///
  /// Built from the active theme rather than hard-coded, so it follows light,
  /// dark and the high-contrast setting without a second definition.
  static MarkdownStyleSheet styleSheetFor(
    BuildContext context, {
    double textScale = 1.0,
    Color? textColor,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: textColor ?? scheme.onSurface,
      height: 1.55,
      fontSize: (theme.textTheme.bodyMedium?.fontSize ?? 14) * textScale,
    );

    TextStyle heading(double scale, FontWeight weight) => base.copyWith(
          fontSize: base.fontSize! * scale,
          fontWeight: weight,
          height: 1.25,
        );

    return MarkdownStyleSheet(
      p: base,
      // Headings in AI output are section labels, not chapter titles — keeping
      // them close to body size stops a five-bullet summary looking like a
      // poster.
      h1: heading(1.45, FontWeight.w700),
      h2: heading(1.25, FontWeight.w700),
      h3: heading(1.12, FontWeight.w600),
      h4: heading(1.0, FontWeight.w600),
      h5: heading(1.0, FontWeight.w600),
      h6: heading(1.0, FontWeight.w600),
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      blockSpacing: 10,
      listIndent: 22,
      code: base.copyWith(
        fontFamily: 'monospace',
        fontSize: base.fontSize! * 0.92,
        backgroundColor: scheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      blockquote: base.copyWith(color: scheme.onSurfaceVariant),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: scheme.primary, width: 3)),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      a: base.copyWith(
        color: scheme.primary,
        decoration: TextDecoration.underline,
      ),
      tableHead: base.copyWith(fontWeight: FontWeight.w700),
      tableBorder: TableBorder.all(color: scheme.outlineVariant, width: 1),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    );
  }

  /// Strip Markdown down to what should be *spoken*.
  ///
  /// Read-aloud must not pronounce "asterisk asterisk" or "hash hash". This
  /// leaves the words and drops the notation, keeping list items as separate
  /// sentences so the voice pauses where the eye would.
  static String toSpeech(String markdown) {
    var text = markdown;

    // Dart's replaceAll takes a literal replacement — `$1` is the characters
    // "$1", not the capture group. Anything keeping inner text must use
    // replaceAllMapped.
    String keepGroup(String input, RegExp pattern) =>
        input.replaceAllMapped(pattern, (m) => m.group(1) ?? '');

    // Fenced code is not prose; announce it rather than reading the symbols.
    text = text.replaceAll(
        RegExp(r'```[\s\S]*?```'), ' (code block omitted) ');
    text = keepGroup(text, RegExp(r'`([^`]*)`'));

    // Images first: the alt-text pattern would otherwise be eaten by the link
    // rule and leave a stray "!".
    text = text.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // Links: say the text, not the URL.
    text = keepGroup(text, RegExp(r'\[([^\]]*)\]\([^)]*\)'));

    text = keepGroup(text, RegExp(r'\*\*([^*]+)\*\*'));
    text = keepGroup(text, RegExp(r'(?<!\*)\*(?!\s)([^*]+)\*'));
    text = keepGroup(text, RegExp(r'__([^_]+)__'));

    text = text
        .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
        // Bullets and numbered items become sentences so speech pauses.
        .replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\d+[.)]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*>\s?', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*[-*_]{3,}\s*$', multiLine: true), '');

    // A line that ended a bullet needs terminal punctuation or the voice runs
    // straight into the next point.
    text = text.split('\n').map((line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return '';
      return RegExp(r'[.!?:;]$').hasMatch(trimmed) ? trimmed : '$trimmed.';
    }).join('\n');

    return text.replaceAll(RegExp(r'\n{2,}'), '\n').trim();
  }
}
