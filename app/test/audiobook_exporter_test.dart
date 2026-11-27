import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audiobook_reader/services/audiobook_exporter.dart';
import 'package:audiobook_reader/services/chapter_index.dart';
import 'package:audiobook_reader/services/runtime_env.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A mono 16-bit PCM WAV of [ms] milliseconds of silence, like Piper writes.
Uint8List wav(int ms, {int rate = 22050, bool listChunk = false}) {
  final samples = rate * ms ~/ 1000;
  final dataBytes = samples * 2;
  final list = listChunk ? 12 : 0;
  final b = ByteData(44 + list + dataBytes);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + list + dataBytes, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, rate, Endian.little);
  b.setUint32(28, rate * 2, Endian.little); // byte rate
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  var at = 36;
  if (listChunk) {
    tag(at, 'LIST');
    b.setUint32(at + 4, 4, Endian.little);
    tag(at + 8, 'INFO');
    at += 12;
  }
  tag(at, 'data');
  b.setUint32(at + 4, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  group('plan', () {
    test('no chapter index → one chapter named after the book', () {
      expect(AudiobookExporter.plan(ChapterIndex.empty, 40, 'Book'),
          [const ExportChapter('Book', 1, 40)]);
    });

    test('chapters span up to the next start; front matter kept', () {
      const index = ChapterIndex([3, 10, 25], ['One', 'Two', 'Three'], 30);
      expect(AudiobookExporter.plan(index, 30, 'Book'), const [
        ExportChapter('Book', 1, 2),
        ExportChapter('One', 3, 9),
        ExportChapter('Two', 10, 24),
        ExportChapter('Three', 25, 30),
      ]);
    });

    test('an empty book has nothing to export', () {
      expect(AudiobookExporter.plan(ChapterIndex.empty, 0, 'Book'), isEmpty);
    });
  });

  group('wavDuration', () {
    test('reads the length from the header', () {
      expect(AudiobookExporter.wavDuration(wav(1500)),
          const Duration(milliseconds: 1500));
    });

    test('skips chunks before data rather than assuming 44 bytes', () {
      // 500 ms is a whole number of samples at 22050 Hz; 250 ms is not.
      expect(AudiobookExporter.wavDuration(wav(500, listChunk: true)),
          const Duration(milliseconds: 500));
    });

    test('not a WAV → null', () {
      expect(AudiobookExporter.wavDuration(Uint8List.fromList(utf8.encode('hello world!'))),
          isNull);
      expect(AudiobookExporter.wavDuration(Uint8List(0)), isNull);
    });
  });

  test('ffmetadata escapes the characters FFMETADATA reserves', () {
    final meta = AudiobookExporter.ffmetadata('A=B; #1', [
      (
        title: 'Ch\\1\nx',
        start: Duration.zero,
        end: const Duration(seconds: 2)
      ),
    ]);
    expect(meta, startsWith(';FFMETADATA1\n'));
    expect(meta, contains(r'title=A\=B\; \#1'));
    expect(meta, contains('START=0\nEND=2000\n'));
    expect(meta, contains('title=Ch\\\\1\\\nx'));
  });

  test("concat list escapes a quote in a path as '\\''", () {
    expect(AudiobookExporter.concatList(["/t/it's.wav", '/t/b.wav']),
        "file '/t/it'\\''s.wav'\nfile '/t/b.wav'");
  });

  // The args are the part most likely to be wrong in a way only ffmpeg can
  // tell, so run them for real: two chapters of WAVs → AAC parts → one .m4b,
  // then ask ffprobe what it got.
  final ffmpeg = RuntimeEnv.findBinary('ffmpeg');
  final ffprobe = RuntimeEnv.findBinary('ffprobe');
  test('encode + mux args produce an m4b with the chapter marks', () async {
    final dir = await Directory.systemTemp.createTemp('audier_m4b_');
    addTearDown(() => dir.delete(recursive: true));
    final odd = p.join(dir.path, "it's here");
    await Directory(odd).create();

    final parts = <String>[];
    for (final (i, lengths) in [
      [1000, 500],
      [2000],
    ].indexed) {
      final wavs = <String>[];
      for (final (j, ms) in lengths.indexed) {
        final f = File(p.join(odd, 'c${i}_$j.wav'));
        await f.writeAsBytes(wav(ms));
        wavs.add(f.path);
      }
      final list = File(p.join(dir.path, 'c$i.txt'))
        ..writeAsStringSync(AudiobookExporter.concatList(wavs));
      final part = p.join(odd, 'c$i.m4a');
      final r = await Process.run(
          ffmpeg!, AudiobookExporter.encodeArgs(list.path, part));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      parts.add(part);
    }
    final list = File(p.join(dir.path, 'parts.txt'))
      ..writeAsStringSync(AudiobookExporter.concatList(parts));
    final meta = File(p.join(dir.path, 'meta.txt'))
      ..writeAsStringSync(AudiobookExporter.ffmetadata('My Book', [
        (title: 'One', start: Duration.zero, end: const Duration(milliseconds: 1500)),
        (
          title: 'Two',
          start: const Duration(milliseconds: 1500),
          end: const Duration(milliseconds: 3500)
        ),
      ]));
    final out = p.join(dir.path, 'book.m4b');
    final r = await Process.run(
        ffmpeg!, AudiobookExporter.muxArgs(list.path, meta.path, out));
    expect(r.exitCode, 0, reason: '${r.stderr}');

    final probe = await Process.run(ffprobe!, [
      '-v', 'error', '-print_format', 'json', '-show_chapters', '-show_format', out,
    ]);
    final info = jsonDecode('${probe.stdout}') as Map<String, dynamic>;
    final chapters = info['chapters'] as List;
    expect([for (final c in chapters) c['tags']['title']], ['One', 'Two']);
    expect(info['format']['tags']['title'], 'My Book');
    final seconds = double.parse('${info['format']['duration']}');
    expect(seconds, closeTo(3.5, 0.15));
  },
      skip: ffmpeg == null || ffprobe == null
          ? 'needs ffmpeg and ffprobe'
          : false);
}
