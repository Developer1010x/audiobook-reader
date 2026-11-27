import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'library_service.dart';

/// Calls [onChanged] once the library folder has settled after books were
/// added, removed or renamed, so a new download shows up without a rescan.
///
/// Events are debounced: copying a 300 MB PDF fires dozens of modify events,
/// and a whole folder dragged in fires hundreds, all of which should cost one
/// rescan after the copy ends rather than one per event.
///
/// macOS and Windows watch the whole tree with one recursive watch. Linux's
/// inotify has no recursive mode (dart:io refuses `recursive: true` there), so
/// each directory gets its own watch, and new directories are picked up as
/// they appear.
class LibraryWatcher {
  LibraryWatcher(
    this.root, {
    required this.onChanged,
    this.debounce = const Duration(seconds: 2),
  });

  final String root;
  final void Function() onChanged;
  final Duration debounce;

  final _subs = <String, StreamSubscription<FileSystemEvent>>{};
  Timer? _timer;
  bool _closed = false;
  DateTime? _startedAt;

  static bool get _perDirectory => Platform.isLinux;

  /// Start watching. Failure is quiet: watching is a convenience, and the
  /// Rescan menu item still works on a filesystem that cannot be watched
  /// (some network mounts, or an inotify limit that has been reached).
  Future<void> start() async {
    if (!await Directory(root).exists()) return;
    _startedAt = DateTime.now();
    if (!_perDirectory) {
      _watch(root, recursive: true);
      return;
    }
    _watch(root, recursive: false);
    try {
      await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
        if (_closed) return;
        if (e is Directory) _watch(e.path, recursive: false);
      }
    } on FileSystemException {
      // An unreadable subfolder: what was already watched keeps working.
    }
  }

  void _watch(String dir, {required bool recursive}) {
    if (_closed || _subs.containsKey(dir)) return;
    try {
      _subs[dir] = Directory(dir)
          .watch(recursive: recursive)
          .listen(_onEvent, onError: (_) => _unwatch(dir), cancelOnError: true);
    } on FileSystemException {
      // Out of inotify watches, most likely. The rest of the tree still works.
    }
  }

  /// macOS's FSEvents reports folders that already existed when the watch
  /// began as freshly created (checked 2026-11-27: the root and every folder
  /// made just before `start()`). Without this, each launch would rescan the
  /// whole library a second time for nothing.
  bool _isReplayedFolder(FileSystemEvent event) {
    final since = _startedAt;
    if (since == null || event is! FileSystemCreateEvent || !event.isDirectory) {
      return false;
    }
    try {
      return FileStat.statSync(event.path).changed.isBefore(since);
    } on FileSystemException {
      return false;
    }
  }

  void _unwatch(String dir) => unawaited(_subs.remove(dir)?.cancel());

  void _onEvent(FileSystemEvent event) {
    if (_closed || p.equals(event.path, root)) return;
    if (_isReplayedFolder(event)) return;
    if (_perDirectory && event.isDirectory) {
      if (event.type == FileSystemEvent.create) _watch(event.path, recursive: false);
      if (event.type == FileSystemEvent.delete) _unwatch(event.path);
    }
    // A finished download is usually a rename from `book.pdf.part` to
    // `book.pdf`: only the destination looks like a book.
    final destination = event is FileSystemMoveEvent ? event.destination : null;
    final relevant = isRelevant(event.path, isDirectory: event.isDirectory) ||
        (destination != null &&
            isRelevant(destination, isDirectory: event.isDirectory));
    if (!relevant) return;
    _timer?.cancel();
    _timer = Timer(debounce, onChanged);
  }

  /// Whether a change at [path] could change the book list.
  ///
  /// A folder can hold books, so any folder change counts. A file counts only
  /// if it is a format the scanner would list, ignoring the macOS `._` stubs
  /// it skips too — otherwise Finder's metadata writes would rescan forever.
  static bool isRelevant(String path, {required bool isDirectory}) {
    final name = p.basename(path);
    if (name.startsWith('.')) return false;
    if (isDirectory) return true;
    final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
    return LibraryService.supportedExtensions.contains(ext);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    final subs = _subs.values.toList();
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }
}
