import 'dart:io';

import 'package:path/path.dart' as p;

import 'runtime_env.dart';

/// Piper — a neural text-to-speech engine that runs locally on CPU.
///
/// The system voice on Linux (espeak-ng via speech-dispatcher) is a formant
/// synthesiser: intelligible, but robotic enough to be unpleasant over a whole
/// chapter. Piper produces natural prosody and is still fully offline, so it
/// keeps the privacy rule intact.
///
/// Piper writes a WAV file rather than playing audio itself, so speaking is two
/// steps: synthesise, then play through the system audio tool.
class PiperTts {
  /// Where a pip-installed piper lands, plus the usual manual install spots.
  static final _binaryCandidates = <String>[
    p.join(_home, '.local/share/piper-venv/bin/piper'),
    p.join(_home, '.local/bin/piper'),
    '/usr/local/bin/piper',
    '/usr/bin/piper',
  ];

  static List<String> get _voiceDirCandidates => <String>[
        // Voices shipped inside the package take precedence, so a store install
        // has a working voice with no setup at all.
        for (final dir in RuntimeEnv.bundledDataDirs) p.join(dir, 'piper-voices'),
        p.join(_home, '.local/share/piper-voices'),
        p.join(_home, '.config/piper/voices'),
      ];

  static String get _home => Platform.environment['HOME'] ?? '';

  static String? _binaryCache;
  static String? _voiceDirCache;
  static bool _resolved = false;

  /// Path to the piper binary, or null if it is not installed.
  static String? get binary {
    _resolve();
    return _binaryCache;
  }

  /// Directory holding `.onnx` voice models, or null if none was found.
  static String? get voiceDir {
    _resolve();
    return _voiceDirCache;
  }

  static void _resolve() {
    if (_resolved) return;
    _resolved = true;

    final override = Platform.environment['PIPER_BIN'];
    for (final candidate in [
      if (override != null && override.isNotEmpty) override,
      ..._binaryCandidates,
    ]) {
      if (File(candidate).existsSync()) {
        _binaryCache = candidate;
        break;
      }
    }
    // Bundled copy first: a confined build cannot see host binaries.
    _binaryCache ??= RuntimeEnv.findBinary('piper');

    for (final candidate in _voiceDirCandidates) {
      final dir = Directory(candidate);
      if (dir.existsSync() && _voicesIn(dir).isNotEmpty) {
        _voiceDirCache = candidate;
        break;
      }
    }
  }

  static String? _which(String binary) {
    try {
      final result = Process.runSync('which', [binary]);
      if (result.exitCode != 0) return null;
      final path = (result.stdout as String).trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  static List<String> _voicesIn(Directory dir) => dir
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .where((name) => name.endsWith('.onnx'))
      .map((name) => name.substring(0, name.length - '.onnx'.length))
      .toList()
    ..sort();

  /// Installed voice names, e.g. `en_US-lessac-medium`.
  static List<String> get voices {
    final dir = voiceDir;
    if (dir == null) return const [];
    return _voicesIn(Directory(dir));
  }

  /// Whether Piper can actually be used: binary present, at least one voice,
  /// and something to play the audio with.
  static bool get isAvailable =>
      binary != null && voices.isNotEmpty && player != null;

  /// The system audio player. pw-play covers PipeWire, aplay covers ALSA.
  static String? get player {
    for (final candidate in ['pw-play', 'paplay', 'aplay', 'ffplay']) {
      final path = RuntimeEnv.findBinary(candidate);
      if (path != null) return path;
    }
    return null;
  }

  /// Arguments for [player], including volume where the player supports it.
  ///
  /// [volume] is 0..1. Only ffplay and the PulseAudio/PipeWire tools can be
  /// told a level; aplay cannot, so a fade there simply has no effect rather
  /// than failing — the sleep timer still ends the session, just without the
  /// gentle taper.
  static List<String> playerArgs(String player, String file,
      {double volume = 1.0}) {
    final name = p.basename(player);
    final level = volume.clamp(0.0, 1.0);
    return switch (name) {
      'ffplay' => [
          '-nodisp',
          '-autoexit',
          '-loglevel',
          'quiet',
          // ffplay takes 0-100.
          '-volume',
          '${(level * 100).round()}',
          file,
        ],
      // Different scales, verified against each tool's own --help. Getting
      // this wrong is silent: an out-of-range value is clamped, so the fade
      // simply never happens rather than erroring.
      //   pw-play: 0.0-1.0 (linear float)
      //   paplay:  0-65536 (PulseAudio integer)
      'pw-play' => ['--volume=${level.toStringAsFixed(3)}', file],
      'paplay' => ['--volume=${(level * 65536).round()}', file],
      'aplay' => ['-q', file],
      _ => [file],
    };
  }

  static String get installMessage =>
      'Piper gives a far better voice than the system one. Install it with:\n'
      '    uv venv ~/.local/share/piper-venv\n'
      '    VIRTUAL_ENV=~/.local/share/piper-venv uv pip install piper-tts\n'
      '    cd ~/.local/share/piper-voices && \\\n'
      '      ~/.local/share/piper-venv/bin/python -m piper.download_voices en_US-lessac-medium';

  /// Synthesise [text] to a WAV file and return it.
  ///
  /// [rate] is the app's 0.1–1.0 scale. Piper expresses speed as `length-scale`,
  /// where *larger is slower*, so the mapping is inverted.
  static Future<File> synthesise(
    String text, {
    required String voice,
    required double rate,
    required String outPath,
  }) async {
    final bin = binary;
    final dir = voiceDir;
    if (bin == null || dir == null) {
      throw Exception('Piper is not installed.');
    }

    // rate 0.5 (the slider's middle) maps to 1.0 — the voice's natural speed.
    final lengthScale = (1.5 - rate).clamp(0.5, 2.0);

    final process = await Process.start(bin, [
      '--model', voice,
      '--data-dir', dir,
      '--length-scale', lengthScale.toStringAsFixed(2),
      '--output-file', outPath,
    ]);
    process.stdin.write(text);
    await process.stdin.close();

    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      final err = await process.stderr.transform(const SystemEncoding().decoder).join();
      throw Exception('Piper failed: ${err.trim()}');
    }
    final file = File(outPath);
    if (!await file.exists()) throw Exception('Piper produced no audio.');
    return file;
  }
}
