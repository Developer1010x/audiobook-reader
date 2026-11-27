import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/audiobook_exporter.dart';
import '../services/piper_tts.dart';
import '../services/settings_service.dart';

/// Ask where to save, then render the book to `<title>.m4b` there, with a
/// progress dialog that can cancel.
///
/// Shared by both readers: they differ only in how a page range becomes text,
/// which is what [textOf] supplies.
Future<void> exportAudiobook(
  BuildContext context, {
  required String bookId,
  required String title,
  required List<ExportChapter> chapters,
  required Future<String> Function(int start, int end) textOf,
  required SettingsService settings,
  required double rate,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) =>
      messenger.showSnackBar(SnackBar(content: Text(text)));

  final missing = AudiobookExporter.missingTools;
  if (missing.isNotEmpty) {
    say('Export needs ${missing.join(' and ')}. '
        '${missing.contains('ffmpeg') ? 'Install ffmpeg from ffmpeg.org. ' : ''}'
        '${!PiperTts.isAvailable ? PiperTts.installMessage : ''}');
    return;
  }
  if (chapters.isEmpty) {
    say('This book has no pages to export.');
    return;
  }

  final dir = await FilePicker.platform
      .getDirectoryPath(dialogTitle: 'Save the audiobook in…');
  if (dir == null || !context.mounted) return;
  // Path separators and characters Windows forbids would turn the title into
  // a different folder or an invalid name.
  final safe = title.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
  final out = p.join(dir, '${safe.isEmpty ? 'audiobook' : safe}.m4b');

  final progress = ValueNotifier<ExportProgress?>(null);
  var cancelled = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Exporting audiobook'),
      content: ValueListenableBuilder<ExportProgress?>(
        valueListenable: progress,
        builder: (context, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: value?.fraction),
            const SizedBox(height: 12),
            Text(
              value == null
                  ? 'Starting…'
                  : value.chapter > value.chapterCount
                      ? value.title
                      : 'Chapter ${value.chapter} of ${value.chapterCount}: '
                          '${value.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              'A long book takes a while: the voice renders faster than it '
              'speaks, but not instantly.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => cancelled = true,
          child: const Text('Cancel'),
        ),
      ],
    ),
  ));

  try {
    await AudiobookExporter.export(
      bookTitle: title,
      chapters: chapters,
      textOf: textOf,
      voice: settings.voiceFor(bookId) ?? PiperTts.voices.first,
      rate: rate,
      outPath: out,
      pronunciations: settings.pronunciations,
      onProgress: (value) => progress.value = value,
      isCancelled: () => cancelled,
    );
    say('Saved ${p.basename(out)}');
  } on ExportCancelled {
    say('Export cancelled.');
  } catch (e) {
    say('Export failed: $e');
  } finally {
    // The notifier is left to the GC rather than disposed: the dialog's
    // builder may still hold it for the frame in which the route pops.
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}
