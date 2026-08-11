import 'package:flutter/material.dart';

import '../models/book.dart';
import '../models/bookmark.dart';
import '../services/settings_service.dart';

/// Saved positions in a book, with previews so a bookmark is recognisable
/// without opening it.
class BookmarksSheet extends StatefulWidget {
  final Book book;
  final SettingsService settings;
  final void Function(int page) onGoToPage;

  const BookmarksSheet({
    super.key,
    required this.book,
    required this.settings,
    required this.onGoToPage,
  });

  @override
  State<BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<BookmarksSheet> {
  late List<Bookmark> _bookmarks = widget.settings.bookmarks(widget.book.id);

  Future<void> _remove(Bookmark bookmark) async {
    await widget.settings.removeBookmark(widget.book.id, bookmark.page);
    setState(() => _bookmarks = widget.settings.bookmarks(widget.book.id));
  }

  Future<void> _editNote(Bookmark bookmark) async {
    final controller = TextEditingController(text: bookmark.note ?? '');
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Note · page ${bookmark.page}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Why does this page matter?',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (note == null) return;
    await widget.settings.addBookmark(
      widget.book.id,
      bookmark.copyWith(note: note.trim().isEmpty ? null : note.trim()),
    );
    setState(() => _bookmarks = widget.settings.bookmarks(widget.book.id));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) {
        if (_bookmarks.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmark_border,
                      size: 40, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('No bookmarks yet', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'Tap the bookmark icon while reading to save your place.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          controller: controller,
          padding: const EdgeInsets.only(bottom: 24),
          itemCount: _bookmarks.length + 1,
          separatorBuilder: (_, index) => const Divider(height: 1),
          itemBuilder: (context, i) {
            if (i == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  '${_bookmarks.length} bookmark${_bookmarks.length == 1 ? '' : 's'}',
                  style: theme.textTheme.titleMedium,
                ),
              );
            }
            final bookmark = _bookmarks[i - 1];
            return ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  '${bookmark.page}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
              title: Text(
                bookmark.note ?? _snippet(bookmark.preview),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: bookmark.note != null
                    ? const TextStyle(fontWeight: FontWeight.w600)
                    : null,
              ),
              subtitle: bookmark.note != null
                  ? Text(_snippet(bookmark.preview),
                      maxLines: 1, overflow: TextOverflow.ellipsis)
                  : null,
              onTap: () {
                Navigator.pop(context);
                widget.onGoToPage(bookmark.page);
              },
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_note),
                    tooltip: 'Add a note',
                    onPressed: () => _editNote(bookmark),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove',
                    onPressed: () => _remove(bookmark),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static String _snippet(String preview) {
    final text = preview.trim();
    if (text.isEmpty) return '(no preview)';
    return text.length <= 90 ? text : '${text.substring(0, 90)}…';
  }
}
