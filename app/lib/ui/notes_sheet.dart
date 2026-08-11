import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/annotation.dart';
import '../models/book.dart';
import '../services/settings_service.dart';

/// Highlights and notes for one book.
///
/// Each entry keeps the quoted passage alongside the note, so a note still
/// makes sense months later when read here rather than on the page.
class NotesSheet extends StatefulWidget {
  final Book book;
  final SettingsService settings;
  final void Function(int page)? onGoToPage;

  const NotesSheet({
    super.key,
    required this.book,
    required this.settings,
    this.onGoToPage,
  });

  @override
  State<NotesSheet> createState() => _NotesSheetState();
}

class _NotesSheetState extends State<NotesSheet> {
  late List<Annotation> _items = widget.settings.annotations(widget.book.id);
  bool _notesOnly = false;

  List<Annotation> get _visible =>
      _notesOnly ? _items.where((a) => a.hasNote).toList() : _items;

  Future<void> _reload() async =>
      setState(() => _items = widget.settings.annotations(widget.book.id));

  Future<void> _remove(Annotation a) async {
    await widget.settings.removeAnnotation(widget.book.id, a.id);
    await _reload();
  }

  Future<void> _edit(Annotation a) async {
    final result = await showAnnotationEditor(
      context: context,
      quote: a.quote,
      initialNote: a.note,
      initialColor: a.color,
    );
    if (result == null) return;
    await widget.settings.addAnnotation(
      widget.book.id,
      a.copyWith(note: result.note, color: result.color),
    );
    await _reload();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(
      text: Annotation.toMarkdown(widget.book.title, _items),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${_items.length} notes copied as Markdown')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final withNotes = _items.where((a) => a.hasNote).length;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, controller) {
        if (_items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.edit_note,
                      size: 40, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('No notes yet', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Select any text while reading, then choose Highlight or '
                    'Add note.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        }

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_items.length} highlight${_items.length == 1 ? '' : 's'}'
                      '${withNotes > 0 ? ' · $withNotes with notes' : ''}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: Icon(_notesOnly ? Icons.filter_alt : Icons.filter_alt_outlined),
                    tooltip: _notesOnly ? 'Showing notes only' : 'Notes only',
                    isSelected: _notesOnly,
                    onPressed: () => setState(() => _notesOnly = !_notesOnly),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy_all),
                    tooltip: 'Copy all as Markdown',
                    onPressed: _copyAll,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.separated(
                controller: controller,
                itemCount: _visible.length,
                separatorBuilder: (_, i) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final a = _visible[i];
                  return ListTile(
                    onTap: widget.onGoToPage == null
                        ? null
                        : () {
                            Navigator.pop(context);
                            widget.onGoToPage!(a.page);
                          },
                    leading: Container(
                      width: 5,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colorFor(a.color, theme),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    title: Text(
                      a.quote.replaceAll('\n', ' ').trim(),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontStyle: FontStyle.italic),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (a.hasNote) ...[
                          const SizedBox(height: 6),
                          Text(a.note!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface)),
                        ],
                        const SizedBox(height: 4),
                        Text('Page ${a.page}',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_note),
                          tooltip: a.hasNote ? 'Edit note' : 'Add note',
                          onPressed: () => _edit(a),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Delete',
                          onPressed: () => _remove(a),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

Color colorFor(HighlightColor c, ThemeData theme) => switch (c) {
      HighlightColor.yellow => const Color(0xFFE0B33C),
      HighlightColor.green => const Color(0xFF4FA37A),
      HighlightColor.blue => const Color(0xFF4E8BD6),
      HighlightColor.pink => const Color(0xFFD1618F),
      HighlightColor.none => theme.colorScheme.outlineVariant,
    };

/// Result of the highlight/note editor.
class AnnotationEdit {
  const AnnotationEdit({this.note, required this.color});
  final String? note;
  final HighlightColor color;
}

/// Shared editor used both when creating a highlight and when editing one.
Future<AnnotationEdit?> showAnnotationEditor({
  required BuildContext context,
  required String quote,
  String? initialNote,
  HighlightColor initialColor = HighlightColor.yellow,
}) {
  final controller = TextEditingController(text: initialNote ?? '');
  var color = initialColor;

  return showDialog<AnnotationEdit>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: const Text('Highlight'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border(
                      left: BorderSide(color: colorFor(color, theme), width: 4),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: Text(quote,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontStyle: FontStyle.italic)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    for (final c in HighlightColor.values)
                      if (c != HighlightColor.none)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: InkWell(
                            onTap: () => setState(() => color = c),
                            borderRadius: BorderRadius.circular(20),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: colorFor(c, theme),
                                shape: BoxShape.circle,
                                border: color == c
                                    ? Border.all(
                                        color: theme.colorScheme.onSurface,
                                        width: 2)
                                    : null,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Your note (optional)',
                    border: OutlineInputBorder(),
                    hintText: 'Why does this matter? What does it connect to?',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(
                context,
                AnnotationEdit(
                  note: controller.text.trim().isEmpty
                      ? null
                      : controller.text.trim(),
                  color: color,
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}
