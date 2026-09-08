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
  ///
  /// Each desktop puts a user-installed tool somewhere different, and a wrong
  /// guess is silent: [isAvailable] simply reports false and the app offers the
  /// robotic system voice on a machine where Piper is installed.
  static List<String> get _binaryCandidates {
    final home = RuntimeEnv.homeDir;
    final data = RuntimeEnv.appDataDir;
    if (Platform.isWindows) {
      return <String>[
        // The pip/uv venv layout, which is what installMessage instructs.
        if (data.isNotEmpty) ...[
          p.join(data, 'piper-venv', 'Scripts', 'piper.exe'),
          p.join(data, 'piper', 'piper.exe'),
        ],
        r'C:\Program Files\piper\piper.exe',
        r'C:\piper\piper.exe',
      ];
    }
    return <String>[
      if (data.isNotEmpty) p.join(data, 'piper-venv', 'bin', 'piper'),
      if (home.isNotEmpty) ...[
        p.join(home, '.local', 'share', 'piper-venv', 'bin', 'piper'),
        p.join(home, '.local', 'bin', 'piper'),
      ],
      // Homebrew, which is how a Mac user is most likely to have got it. The
      // arm64 and Intel prefixes differ, and only one exists on any machine.
      if (Platform.isMacOS) ...[
        '/opt/homebrew/bin/piper',
        p.join('/opt/homebrew', 'share', 'piper-venv', 'bin', 'piper'),
      ],
      '/usr/local/bin/piper',
      '/usr/bin/piper',
    ];
  }

  static List<String> get _voiceDirCandidates {
    final home = RuntimeEnv.homeDir;
    final data = RuntimeEnv.appDataDir;
    return <String>[
      // Voices shipped inside the package take precedence, so a store install
      // has a working voice with no setup at all.
      for (final dir in RuntimeEnv.bundledDataDirs) p.join(dir, 'piper-voices'),
      if (data.isNotEmpty) p.join(data, 'piper-voices'),
      if (home.isNotEmpty && !Platform.isWindows) ...[
        p.join(home, '.local', 'share', 'piper-voices'),
        p.join(home, '.config', 'piper', 'voices'),
      ],
    ];
  }

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

  /// The system audio player.
  ///
  /// Piper writes a WAV and plays nothing itself, so every platform needs some
  /// command that can play a file. The candidates differ completely:
  ///   * Linux   — pw-play covers PipeWire, paplay PulseAudio, aplay ALSA.
  ///   * macOS   — afplay ships with the OS, so this never comes up empty.
  ///   * Windows — nothing bundled can play audio from the command line except
  ///     PowerShell's `SoundPlayer`, which is WAV-only. That is exactly what
  ///     Piper produces, so it works as a zero-install fallback; ffplay is
  ///     still preferred when present because it can be told a volume.
  static String? get player {
    for (final candidate in _playerCandidates) {
      final path = RuntimeEnv.findBinary(candidate);
      if (path != null) return path;
    }
    // Present on every supported Windows version, so this is a real fallback
    // rather than a guess — but only ever reached on Windows.
    if (Platform.isWindows) return _powershell;
    return null;
  }

  static const _powershell = 'powershell';

  static List<String> get _playerCandidates {
    if (Platform.isMacOS) return const ['afplay', 'ffplay'];
    if (Platform.isWindows) return const ['ffplay'];
    return const ['pw-play', 'paplay', 'aplay', 'ffplay'];
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
      // afplay takes a linear 0..1 gain, same scale the app already uses.
      'afplay' => ['-v', level.toStringAsFixed(3), file],
      // SoundPlayer has no volume control, so a fade has no effect here — the
      // sleep timer still ends the session, just without the gentle taper.
      // PlaySync blocks until the clip ends, which is what makes awaiting the
      // process mean "this chunk finished", exactly as the other players do.
      // Single quotes are the literal-string form in PowerShell; a quote inside
      // a path is escaped by doubling it, so a stray apostrophe in a filename
      // cannot end the string and run the rest as a command.
      'powershell' || 'powershell.exe' => [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(New-Object Media.SoundPlayer '${file.replaceAll("'", "''")}')"
              '.PlaySync()',
        ],
      _ => [file],
    };
  }

  /// How to install Piper, in the terms of the platform actually in use.
  ///
  /// Telling a Mac or Windows user to run `~/.local/share/...` is not merely
  /// unhelpful — it is a path that cannot exist there, so the instruction reads
  /// as the app being broken rather than the tool being absent.
  static String get installMessage {
    if (Platform.isWindows) {
      // Raw strings throughout: every `$env:` and `\` here is PowerShell
      // syntax, and Dart would otherwise read them as interpolation and
      // escapes. The `$env` in the middle of this block is precisely what the
      // analyzer rejected when it was written as a normal string.
      return 'Piper gives a far better voice than the system one. '
          'Install it with:\n'
          r'    uv venv $env:LOCALAPPDATA\piper-venv' '\n'
          r'    $env:LOCALAPPDATA\piper-venv\Scripts\python -m pip install piper-tts' '\n'
          r'    mkdir $env:LOCALAPPDATA\piper-voices' '\n'
          r'    cd $env:LOCALAPPDATA\piper-voices' '\n'
          r'    $env:LOCALAPPDATA\piper-venv\Scripts\python -m piper.download_voices en_US-lessac-medium';
    }
    final data = Platform.isMacOS
        ? r'~/Library/Application Support'
        : r'~/.local/share';
    return 'Piper gives a far better voice than the system one. Install it '
        'with:\n'
        '    uv venv $data/piper-venv\n'
        '    VIRTUAL_ENV=$data/piper-venv uv pip install piper-tts\n'
        '    mkdir -p $data/piper-voices && cd $data/piper-voices && \\\n'
        '      $data/piper-venv/bin/python -m piper.download_voices en_US-lessac-medium';
  }

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
