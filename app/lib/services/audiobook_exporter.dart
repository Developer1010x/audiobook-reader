import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'chapter_index.dart';
import 'concurrency.dart';
import 'piper_tts.dart';
import 'runtime_env.dart';
import 'tts_service.dart';

/// One chapter of an export: a title and an inclusive page range.
class ExportChapter {
  const ExportChapter(this.title, this.startPage, this.endPage);

  final String title;
  final int startPage;
  final int endPage;

  @override
  bool operator ==(Object other) =>
      other is ExportChapter &&
      other.title == title &&
      other.startPage == startPage &&
      other.endPage == endPage;

  @override
  int get hashCode => Object.hash(title, startPage, endPage);

  @override
  String toString() => 'ExportChapter($title, $startPage-$endPage)';
}

/// Progress of a running export, for the dialog.
class ExportProgress {
  const ExportProgress(this.chapter, this.chapterCount, this.title);

  /// 1-based chapter being rendered; [chapterCount] + 1 while joining.
  final int chapter;
  final int chapterCount;
  final String title;

  double get fraction => (chapter - 1) / (chapterCount + 1);
}

/// Thrown when the user cancels; the partial output is deleted first.
class ExportCancelled implements Exception {
  const ExportCancelled();
}

/// Renders a whole book to one `.m4b` audiobook with chapter markers.
///
/// Piper-only: flutter_tts cannot write audio to a file on Linux or Windows,
/// and ignores the path it is given on macOS. ffmpeg does the encoding, so
/// both must be installed; [missingTools] says which are not.
///
/// Each chapter is synthesised to WAVs, encoded straight to AAC, and its WAVs
/// deleted before the next chapter starts. A ten-hour book is about 1.6 GB as
/// WAV but only ~300 MB as 64 kbit/s AAC, so temp space stays at one chapter.
class AudiobookExporter {
  const AudiobookExporter._();

  /// What is missing for an export to work here, or empty when nothing is.
  static List<String> get missingTools => [
        if (!PiperTts.isAvailable) 'Piper (neural voice)',
        if (ffmpeg == null) 'ffmpeg',
      ];

  static String? get ffmpeg => RuntimeEnv.findBinary('ffmpeg');

  /// Split a book into chapters from its index. A book with no index becomes
  /// one chapter named after the book, so the export still works.
  static List<ExportChapter> plan(
      ChapterIndex index, int pageCount, String bookTitle) {
    if (pageCount < 1) return const [];
    if (!index.hasChapters) return [ExportChapter(bookTitle, 1, pageCount)];
    final out = <ExportChapter>[];
    // Pages before the first chapter (cover, contents) are their own section
    // rather than silently dropped.
    if (index.starts.first > 1) {
      out.add(ExportChapter(bookTitle, 1, index.starts.first - 1));
    }
    for (var i = 0; i < index.starts.length; i++) {
      final end =
          i + 1 < index.starts.length ? index.starts[i + 1] - 1 : pageCount;
      if (end < index.starts[i]) continue;
      out.add(ExportChapter(index.titles[i], index.starts[i], end));
    }
    return out;
  }

  /// Duration of a PCM WAV, read from its header. Null if it is not one.
  ///
  /// Walks the RIFF chunks rather than assuming a 44-byte header: writers
  /// are free to put a LIST chunk before `data`.
  static Duration? wavDuration(Uint8List bytes) {
    if (bytes.length < 12) return null;
    final data = ByteData.sublistView(bytes);
    String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
    if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
    int? byteRate;
    var at = 12;
    while (at + 8 <= bytes.length) {
      final id = tag(at);
      final size = data.getUint32(at + 4, Endian.little);
      if (id == 'fmt ' && at + 20 <= bytes.length) {
        byteRate = data.getUint32(at + 16, Endian.little);
      } else if (id == 'data') {
        if (byteRate == null || byteRate == 0) return null;
        // A streaming writer may leave the size as 0 or 0xFFFFFFFF; trust the
        // bytes actually present instead.
        final available = bytes.length - (at + 8);
        final length = (size == 0 || size > available) ? available : size;
        return Duration(microseconds: length * 1000000 ~/ byteRate);
      }
      at += 8 + size + (size.isOdd ? 1 : 0);
    }
    return null;
  }

  /// FFMETADATA1 text: book title plus one CHAPTER block per chapter, in
  /// milliseconds. `=`, `;`, `#`, `\` and newlines must be escaped.
  static String ffmetadata(
      String title, List<({String title, Duration start, Duration end})> chapters) {
    String esc(String s) => s.replaceAllMapped(
        RegExp(r'[=;#\\\n]'), (m) => '\\${m.group(0)}');
    final b = StringBuffer(';FFMETADATA1\n')
      ..writeln('title=${esc(title)}')
      ..writeln('genre=Audiobook');
    for (final c in chapters) {
      b
        ..writeln('[CHAPTER]')
        ..writeln('TIMEBASE=1/1000')
        ..writeln('START=${c.start.inMilliseconds}')
        ..writeln('END=${c.end.inMilliseconds}')
        ..writeln('title=${esc(c.title)}');
    }
    return b.toString();
  }

  /// A concat-demuxer list. Paths are single-quoted, and a quote inside one is
  /// written as `'\''`, the demuxer's own escape.
  static String concatList(List<String> paths) => [
        for (final path in paths) "file '${path.replaceAll("'", r"'\''")}'",
      ].join('\n');

  /// Args to encode concatenated WAVs to one mono 64 kbit/s AAC file.
  static List<String> encodeArgs(String listPath, String outPath) => [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', listPath,
        '-c:a', 'aac', '-b:a', '64k', '-ac', '1',
        outPath,
      ];

  /// Args to join per-chapter AAC files and attach the chapter metadata.
  static List<String> muxArgs(String listPath, String metaPath, String outPath) => [
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', listPath,
        '-i', metaPath,
        '-map', '0:a', '-map_metadata', '1', '-map_chapters', '1',
        '-c', 'copy', '-movflags', '+faststart',
        // The .m4b extension is not one ffmpeg maps to a muxer by itself.
        '-f', 'mp4',
        outPath,
      ];

  /// Render [chapters] to [outPath].
  ///
  /// [textOf] returns the text of an inclusive page range. Throws
  /// [ExportCancelled] when [isCancelled] turns true; nothing is left behind
  /// either way, apart from a finished [outPath].
  static Future<File> export({
    required String bookTitle,
    required List<ExportChapter> chapters,
    required Future<String> Function(int start, int end) textOf,
    required String voice,
    required double rate,
    required String outPath,
    Map<String, String> pronunciations = const {},
    void Function(ExportProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final ff = ffmpeg;
    if (ff == null || !PiperTts.isAvailable) {
      throw Exception('Export needs ${missingTools.join(' and ')}.');
    }
    bool cancelled() => isCancelled?.call() ?? false;
    final work = await Directory.systemTemp.createTemp('audier_export_');
    try {
      final parts = <String>[];
      final marks = <({String title, Duration start, Duration end})>[];
      var clock = Duration.zero;

      for (var c = 0; c < chapters.length; c++) {
        final chapter = chapters[c];
        onProgress?.call(ExportProgress(c + 1, chapters.length, chapter.title));
        final text = await textOf(chapter.startPage, chapter.endPage);
        final chunks = TtsService.speakableChunks(text, pronunciations);
        if (chunks.isEmpty) continue; // a blank or image-only section

        final wavs = await Concurrency.mapBounded<String, File?>(
          chunks,
          (chunk, i) => PiperTts.synthesise(chunk,
              voice: voice,
              rate: rate,
              outPath: p.join(work.path, 'c${c}_$i.wav')),
          concurrency: min(2, Concurrency.cpuPool),
          isCancelled: cancelled,
        );
        if (cancelled()) throw const ExportCancelled();

        var length = Duration.zero;
        final paths = <String>[];
        for (final wav in wavs.whereType<File>()) {
          final d = wavDuration(await wav.readAsBytes());
          if (d == null) continue;
          length += d;
          paths.add(wav.path);
        }
        if (paths.isEmpty) continue;

        final list = File(p.join(work.path, 'c$c.txt'));
        await list.writeAsString(concatList(paths));
        final part = p.join(work.path, 'c$c.m4a');
        await _ffmpeg(ff, encodeArgs(list.path, part));
        for (final path in paths) {
          await File(path).delete();
        }
        parts.add(part);
        marks.add((title: chapter.title, start: clock, end: clock + length));
        clock += length;
      }
      if (parts.isEmpty) throw Exception('This book has no text to read.');
      if (cancelled()) throw const ExportCancelled();

      onProgress?.call(
          ExportProgress(chapters.length + 1, chapters.length, 'Joining chapters'));
      final list = File(p.join(work.path, 'parts.txt'));
      await list.writeAsString(concatList(parts));
      final meta = File(p.join(work.path, 'chapters.ffmeta'));
      await meta.writeAsString(ffmetadata(bookTitle, marks));
      await _ffmpeg(ff, muxArgs(list.path, meta.path, outPath));
      return File(outPath);
    } catch (_) {
      final out = File(outPath);
      if (await out.exists()) await out.delete();
      rethrow;
    } finally {
      await work.delete(recursive: true);
    }
  }

  static Future<void> _ffmpeg(String ff, List<String> args) async {
    final result = await Process.run(ff, args);
    if (result.exitCode != 0) {
      throw Exception('ffmpeg failed: ${'${result.stderr}'.trim()}');
    }
  }
}
