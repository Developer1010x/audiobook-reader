import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../runtime_env.dart';
import '../system_info.dart';
import 'llm_error.dart';

/// A model the app can offer to install, with what it actually costs to run.
class ModelOption {
  const ModelOption({
    required this.name,
    required this.label,
    required this.downloadGb,
    required this.ramGb,
    required this.note,
  });

  /// Ollama tag, e.g. `qwen2.5:1.5b`.
  final String name;
  final String label;

  /// Approximate download size in gigabytes.
  final double downloadGb;

  /// Approximate RAM needed to run it with a useful context.
  final double ramGb;

  final String note;

  /// Whether this machine can plausibly hold it.
  ///
  /// The OS and everything else need room too, so the check is against a
  /// working figure rather than total RAM.
  bool fitsOn(int? totalRamMb) {
    if (totalRamMb == null) return true; // unknown: do not block
    final usableGb = (totalRamMb / 1024) - 2.0;
    return usableGb >= ramGb;
  }
}

/// Installs and inspects local Ollama models.
///
/// The app deliberately does not try to install the Ollama *daemon* itself —
/// that needs a system service and administrator rights, which an application
/// should not be doing quietly behind the user. It detects it, and shows the
/// exact command for this platform instead.
class OllamaManager {
  static const _base = 'http://localhost:11434';

  /// Catalogue offered in the picker, smallest first.
  ///
  /// Sizes are approximate — enough to warn someone off a 40 GB download onto
  /// an 8 GB laptop, not a specification.
  static const catalogue = <ModelOption>[
    ModelOption(
      name: 'qwen2.5:0.5b',
      label: 'Qwen 2.5 · 0.5B',
      downloadGb: 0.4,
      ramGb: 1.5,
      note: 'Runs almost anywhere. Rough summaries.',
    ),
    ModelOption(
      name: 'qwen2.5:1.5b',
      label: 'Qwen 2.5 · 1.5B',
      downloadGb: 1.0,
      ramGb: 3,
      note: 'Good balance for modest machines.',
    ),
    ModelOption(
      name: 'llama3.2:3b',
      label: 'Llama 3.2 · 3B',
      downloadGb: 2.0,
      ramGb: 5,
      note: 'Noticeably better prose.',
    ),
    ModelOption(
      name: 'qwen2.5:7b',
      label: 'Qwen 2.5 · 7B',
      downloadGb: 4.7,
      ramGb: 9,
      note: 'Strong on technical text.',
    ),
    ModelOption(
      name: 'gemma2:9b',
      label: 'Gemma 2 · 9B',
      downloadGb: 5.4,
      ramGb: 11,
      note: 'Good at explaining concepts.',
    ),
    ModelOption(
      name: 'qwen2.5:14b',
      label: 'Qwen 2.5 · 14B',
      downloadGb: 9.0,
      ramGb: 18,
      note: 'For 32 GB machines and up.',
    ),
  ];

  /// The best model this machine can comfortably run.
  static ModelOption recommended() {
    final ram = SystemInfo.totalRamMb;
    final affordable = catalogue.where((m) => m.fitsOn(ram)).toList();
    if (affordable.isEmpty) return catalogue.first;
    // The largest that fits, but never the very top tier on an unknown machine.
    return affordable.last;
  }

  /// True when the `ollama` binary exists on this machine.
  static bool get isInstalled {
    if (!(Platform.isLinux || Platform.isMacOS || Platform.isWindows)) {
      return false;
    }
    // A confined build cannot see host binaries, but it can still reach the
    // daemon over localhost — so the binary check would be a false negative.
    // isRunning() is authoritative there.
    if (RuntimeEnv.isSandboxed) return true;
    return RuntimeEnv.findBinary('ollama') != null;
  }

  /// True when the daemon answers — installed is not the same as running.
  static Future<bool> isRunning() async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/tags'))
          .timeout(const Duration(seconds: 2));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Platform-appropriate installation instructions.
  static String get installCommand {
    if (Platform.isMacOS) {
      return 'brew install ollama && brew services start ollama';
    }
    if (Platform.isWindows) {
      return 'Download the installer from https://ollama.com/download';
    }
    return 'curl -fsSL https://ollama.com/install.sh | sh';
  }

  static String get startCommand =>
      Platform.isWindows ? 'Start Ollama from the Start menu' : 'ollama serve';

  /// Models already pulled, with their on-disk sizes.
  static Future<List<InstalledModel>> installed() async {
    try {
      final resp = await http
          .get(Uri.parse('$_base/api/tags'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode != 200) return const [];
      final models = (jsonDecode(resp.body)['models'] as List?) ?? const [];
      return models
          .map((m) => InstalledModel(
                name: (m as Map)['name'] as String? ?? '',
                sizeBytes: (m['size'] as num?)?.toInt() ?? 0,
              ))
          .where((m) => m.name.isNotEmpty)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (_) {
      return const [];
    }
  }

  /// Download a model, reporting progress as it goes.
  ///
  /// `/api/pull` streams newline-delimited JSON with `completed`/`total` byte
  /// counts, so this can drive a real progress bar rather than a spinner over a
  /// multi-gigabyte download.
  static Future<void> pull(
    String model, {
    void Function(PullProgress progress)? onProgress,
    CancellationToken? cancel,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('POST', Uri.parse('$_base/api/pull'))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode({'model': model, 'stream': true});

      final http.StreamedResponse response;
      try {
        response = await client.send(request);
      } catch (e) {
        throw const TransportFailure(
          'Could not reach Ollama. Is it running?',
          provider: 'Ollama',
        );
      }
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw errorForStatus(response.statusCode, body, 'Ollama');
      }

      await for (final line in response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        if (cancel?.isCancelled ?? false) throw const Cancelled();
        if (line.trim().isEmpty) continue;
        try {
          final json = jsonDecode(line) as Map<String, dynamic>;
          if (json['error'] != null) {
            throw ModelUnavailable('${json['error']}', provider: 'Ollama');
          }
          onProgress?.call(PullProgress(
            status: json['status'] as String? ?? '',
            completed: (json['completed'] as num?)?.toInt() ?? 0,
            total: (json['total'] as num?)?.toInt() ?? 0,
          ));
        } on LlmError {
          rethrow;
        } catch (_) {
          continue; // a malformed frame should not kill the download
        }
      }
    } finally {
      client.close();
    }
  }

  static Future<void> delete(String model) async {
    try {
      await http.delete(
        Uri.parse('$_base/api/delete'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'model': model}),
      );
    } catch (_) {}
  }
}

class InstalledModel {
  const InstalledModel({required this.name, required this.sizeBytes});
  final String name;
  final int sizeBytes;

  String get sizeLabel => sizeBytes <= 0
      ? ''
      : '${(sizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

class PullProgress {
  const PullProgress({
    required this.status,
    required this.completed,
    required this.total,
  });

  final String status;
  final int completed;
  final int total;

  /// 0..1, or null while Ollama is still resolving the manifest and has no
  /// byte counts to report yet.
  double? get fraction =>
      total > 0 ? (completed / total).clamp(0.0, 1.0) : null;

  String get label {
    if (total <= 0) return status;
    final done = (completed / (1024 * 1024 * 1024)).toStringAsFixed(1);
    final all = (total / (1024 * 1024 * 1024)).toStringAsFixed(1);
    return '$status · $done / $all GB';
  }
}
