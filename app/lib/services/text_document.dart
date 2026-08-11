import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/book.dart';

/// A plain-text book — `.txt`, `.md` or `.epub` — loaded into synthetic pages.
///
/// These formats have no page concept of their own: a text file is one long
/// stream, and an EPUB paginates differently on every screen size. So the app
/// imposes its own pagination, which keeps the rest of the design (page
/// numbers, resume position, per-page read-aloud, page ranges for AI) working
/// unchanged across formats.
class TextDocument {
  final List<TextPage> pages;

  /// Chapter titles from the EPUB spine, empty for txt/md.
  final List<TextChapter> chapters;

  const TextDocument({required this.pages, this.chapters = const []});

  int get pageCount => pages.length;

  static const _targetPageChars = 1800;

  static bool handles(String ext) => const {'txt', 'md', 'epub'}.contains(ext);

  static Future<TextDocument> open(Book book) async {
    return switch (book.ext) {
      'epub' => _openEpub(File(book.path)),
      _ => _openPlain(File(book.path)),
    };
  }

  // ── txt / md ──

  static Future<TextDocument> _openPlain(File file) async {
    final raw = await _readText(file);
    final pages = _paginate(raw);
    return TextDocument(pages: pages);
  }

  /// Decode as UTF-8, falling back to Latin-1 rather than throwing — older text
  /// files in a personal library are frequently not UTF-8.
  static Future<String> _readText(File file) async {
    final bytes = await file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  // ── epub ──

  /// EPUB is a zip: `META-INF/container.xml` points at the OPF, whose `spine`
  /// gives reading order. Parsing it directly avoids a dependency that conflicts
  /// with the PDF engine.
  static Future<TextDocument> _openEpub(File file) async {
    final archive = ZipDecoder().decodeBytes(await file.readAsBytes());

    String? readFile(String path) {
      final normalised = path.replaceAll('\\', '/');
      for (final entry in archive.files) {
        if (!entry.isFile) continue;
        if (entry.name == normalised ||
            Uri.decodeFull(entry.name) == normalised) {
          return utf8.decode(entry.readBytes() ?? [], allowMalformed: true);
        }
      }
      return null;
    }

    final container = readFile('META-INF/container.xml');
    if (container == null) throw const FormatException('Not a valid EPUB.');

    final opfPath = XmlDocument.parse(container)
        .findAllElements('rootfile')
        .first
        .getAttribute('full-path');
    if (opfPath == null) throw const FormatException('EPUB has no OPF.');

    final opfXml = readFile(opfPath);
    if (opfXml == null) throw const FormatException('EPUB OPF is missing.');
    final opf = XmlDocument.parse(opfXml);
    final base = p.dirname(opfPath);

    // manifest id -> href
    final manifest = <String, String>{};
    for (final item in opf.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) manifest[id] = href;
    }

    final pages = <TextPage>[];
    final chapters = <TextChapter>[];

    for (final ref in opf.findAllElements('itemref')) {
      final href = manifest[ref.getAttribute('idref')];
      if (href == null) continue;

      final path = base == '.' ? href : p.normalize(p.join(base, href));
      final content = readFile(path);
      if (content == null) continue;

      final document = html_parser.parse(content);
      // Scripts and styles carry no readable text but plenty of noise.
      for (final node in document.querySelectorAll('script, style')) {
        node.remove();
      }
      final title = document.querySelector('h1, h2, title')?.text.trim();
      final text = _tidy(document.body?.text ?? '');
      if (text.trim().isEmpty) continue;

      chapters.add(TextChapter(
        title: (title == null || title.isEmpty) ? 'Section ${chapters.length + 1}' : title,
        firstPage: pages.length + 1,
      ));
      pages.addAll(_paginate(text, startNumber: pages.length + 1));
    }

    if (pages.isEmpty) throw const FormatException('EPUB contained no readable text.');
    return TextDocument(pages: pages, chapters: chapters);
  }

  /// HTML-derived text arrives with runs of blank lines and stray whitespace.
  static String _tidy(String text) => text
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .split('\n')
      .map((line) => line.trim())
      .join('\n')
      .trim();

  /// Split text into pages on paragraph boundaries, so a page never starts
  /// mid-sentence.
  static List<TextPage> _paginate(String text, {int startNumber = 1}) {
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final pages = <TextPage>[];
    final buffer = StringBuffer();

    void flush() {
      final content = buffer.toString().trim();
      if (content.isEmpty) return;
      pages.add(TextPage(number: startNumber + pages.length, text: content));
      buffer.clear();
    }

    for (final paragraph in paragraphs) {
      final trimmed = paragraph.trim();
      if (trimmed.isEmpty) continue;
      if (buffer.isNotEmpty && buffer.length + trimmed.length > _targetPageChars) {
        flush();
      }
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write(trimmed);
    }
    flush();

    // A file with no blank lines at all still needs at least one page.
    if (pages.isEmpty && text.trim().isNotEmpty) {
      pages.add(TextPage(number: startNumber, text: text.trim()));
    }
    return pages;
  }
}

class TextPage {
  final int number;
  final String text;
  const TextPage({required this.number, required this.text});
}

class TextChapter {
  final String title;
  final int firstPage;
  const TextChapter({required this.title, required this.firstPage});
}
