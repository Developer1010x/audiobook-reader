import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/book.dart';
import '../../services/cover_service.dart';
import '../../services/settings_service.dart';

/// Cover art for a book, rendered from its first page and cached.
///
/// Text formats have no cover to render, so they get a typographic one built
/// from the title — a grid of identical file icons is unreadable, and a blank
/// tile looks broken.
class BookCover extends StatelessWidget {
  final Book book;
  final BookType? type;
  final double width;
  final double height;
  final double radius;

  const BookCover({
    super.key,
    required this.book,
    this.type,
    required this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (book.ext != 'pdf') {
      return _TypographicCover(
        book: book,
        width: width,
        height: height,
        radius: radius,
      );
    }

    final fallback = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(
        type == BookType.textbook
            ? Icons.school_outlined
            : Icons.auto_stories_outlined,
        size: width * 0.4,
        color: theme.colorScheme.outline,
      ),
    );

    return SizedBox(
      width: width,
      height: height,
      child: FutureBuilder<File?>(
        future: CoverService.cover(book, width: (width * 3).round()),
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (file == null) return fallback;
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Image.file(
              file,
              width: width,
              height: height,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => fallback,
            ),
          );
        },
      ),
    );
  }
}

/// A generated cover for txt/md/epub: the title set on a colour derived from it,
/// so the same book always looks the same and different books look different.
class _TypographicCover extends StatelessWidget {
  final Book book;
  final double width;
  final double height;
  final double radius;

  const _TypographicCover({
    required this.book,
    required this.width,
    required this.height,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    final hue = (book.title.hashCode.abs() % 360).toDouble();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = HSLColor.fromAHSL(1, hue, 0.32, dark ? 0.28 : 0.72).toColor();
    final ink = HSLColor.fromAHSL(1, hue, 0.5, dark ? 0.88 : 0.2).toColor();

    return Container(
      width: width,
      height: height,
      padding: EdgeInsets.all(width * 0.1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [base, base.withValues(alpha: 0.75)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              book.title,
              maxLines: width > 70 ? 4 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ink,
                fontWeight: FontWeight.w700,
                fontSize: width * 0.14,
                height: 1.15,
              ),
            ),
          ),
          Text(
            book.ext.toUpperCase(),
            style: TextStyle(
              color: ink.withValues(alpha: 0.7),
              fontSize: width * 0.1,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

/// Poster-style tile: cover above, title below. The default library view.
class BookPoster extends StatelessWidget {
  final Book book;
  final SettingsService settings;
  final VoidCallback onTap;
  final VoidCallback onToggleFavourite;
  final String? subtitleOverride;

  const BookPoster({
    super.key,
    required this.book,
    required this.settings,
    required this.onTap,
    required this.onToggleFavourite,
    this.subtitleOverride,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type =
        settings.typeOverride(book.id) ?? settings.cachedClassification(book.id);
    final favourite = settings.isFavourite(book.id);

    final lastPage = settings.lastPage(book.id);
    final total = settings.pageCount(book.id);
    final progress =
        (lastPage != null && total != null && total > 0 && lastPage > 1)
            ? (lastPage / total).clamp(0.0, 1.0)
            : null;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: LayoutBuilder(
                    builder: (context, c) => BookCover(
                      book: book,
                      type: type,
                      width: c.maxWidth,
                      height: c.maxHeight,
                    ),
                  ),
                ),
                if (progress != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          bottom: Radius.circular(8)),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 4,
                        backgroundColor: Colors.black.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                Positioned(
                  top: 2,
                  right: 2,
                  child: IconButton(
                    iconSize: 16,
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black.withValues(alpha: 0.4),
                      minimumSize: const Size(26, 26),
                      padding: EdgeInsets.zero,
                    ),
                    icon: Icon(
                      favourite ? Icons.star : Icons.star_border,
                      color: favourite ? Colors.amber : Colors.white70,
                    ),
                    tooltip: favourite ? 'Remove from favourites' : 'Favourite',
                    onPressed: onToggleFavourite,
                  ),
                ),
                if (type == BookType.textbook)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Textbook',
                        style: TextStyle(fontSize: 9, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          Text(
            subtitleOverride ?? book.sizeLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
