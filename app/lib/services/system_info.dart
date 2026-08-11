import 'dart:io';

/// Enough hardware facts to give honest advice about which models will run.
///
/// This is used to *steer*, not to forbid. Detection is imperfect across
/// platforms, and a user who knows their machine better than we do should
/// always be able to proceed anyway.
class SystemInfo {
  static int? _cachedRamMb;

  /// Total system RAM in megabytes, or null if it cannot be determined.
  static int? get totalRamMb {
    if (_cachedRamMb != null) return _cachedRamMb;
    try {
      if (Platform.isLinux) return _cachedRamMb = _linuxRam();
      if (Platform.isMacOS) return _cachedRamMb = _macRam();
      if (Platform.isWindows) return _cachedRamMb = _windowsRam();
    } catch (_) {
      return null;
    }
    return null;
  }

  static int? _linuxRam() {
    final line = File('/proc/meminfo')
        .readAsLinesSync()
        .firstWhere((l) => l.startsWith('MemTotal:'), orElse: () => '');
    final kb = int.tryParse(RegExp(r'(\d+)').firstMatch(line)?.group(1) ?? '');
    return kb == null ? null : (kb / 1024).round();
  }

  static int? _macRam() {
    final result = Process.runSync('sysctl', ['-n', 'hw.memsize']);
    final bytes = int.tryParse((result.stdout as String).trim());
    return bytes == null ? null : (bytes / (1024 * 1024)).round();
  }

  static int? _windowsRam() {
    final result = Process.runSync(
      'wmic',
      ['ComputerSystem', 'get', 'TotalPhysicalMemory'],
    );
    final match = RegExp(r'(\d{6,})').firstMatch(result.stdout as String);
    final bytes = int.tryParse(match?.group(1) ?? '');
    return bytes == null ? null : (bytes / (1024 * 1024)).round();
  }

  static String get ramLabel {
    final mb = totalRamMb;
    if (mb == null) return 'unknown RAM';
    return '${(mb / 1024).toStringAsFixed(mb < 10240 ? 1 : 0)} GB RAM';
  }

  /// Rough tiers used to pick a sensible default model.
  static ModelTier get tier {
    final mb = totalRamMb;
    if (mb == null) return ModelTier.unknown;
    if (mb < 6 * 1024) return ModelTier.small;
    if (mb < 12 * 1024) return ModelTier.medium;
    if (mb < 32 * 1024) return ModelTier.large;
    return ModelTier.xlarge;
  }
}

enum ModelTier { small, medium, large, xlarge, unknown }
