import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/media_player_service.dart';
import '../services/settings_service.dart';

/// Background audio while reading.
///
/// Offered because read-aloud is not always possible or wanted — no speech
/// engine, a scanned page with no text, or simply preferring music. Two
/// sources: a folder of your own files, or whatever player is already running
/// on the desktop.
class MusicSheet extends StatefulWidget {
  final SettingsService settings;
  final MediaPlayerService player;

  const MusicSheet({
    super.key,
    required this.settings,
    required this.player,
  });

  @override
  State<MusicSheet> createState() => _MusicSheetState();
}

class _MusicSheetState extends State<MusicSheet> {
  List<String> _players = const [];
  String? _selectedPlayer;
  String? _nowPlaying;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    _refreshPlayers();
    final folder = widget.settings.musicFolder;
    if (folder != null && widget.player.playlist.isEmpty) {
      widget.player.loadFolder(folder);
    }
  }

  void _onPlayer() => mounted ? setState(() {}) : null;

  Future<void> _refreshPlayers() async {
    final found = await MprisControl.players();
    final playing = found.isEmpty
        ? null
        : await MprisControl.nowPlaying(found.first);
    if (!mounted) return;
    setState(() {
      _players = found;
      _selectedPlayer ??= found.isEmpty ? null : found.first;
      _nowPlaying = playing;
      _loading = false;
    });
  }

  Future<void> _pickFolder() async {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose a music folder',
      initialDirectory: widget.settings.musicFolder,
    );
    if (path == null) return;
    await widget.settings.setMusicFolder(path);
    final count = await widget.player.loadFolder(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$count tracks found')),
    );
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayer);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final player = widget.player;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Text('Background audio', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'For when you would rather read to music than be read to.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 22),

          // ── your own files ──
          Text('From a folder', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          if (!MediaPlayerService.canPlayFiles)
            _Hint(
              icon: Icons.warning_amber_outlined,
              text: 'No audio player found. Install one with:\n'
                  '    sudo apt install mpv',
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            player.playlist.isEmpty
                                ? (widget.settings.musicFolder ??
                                    'No folder chosen')
                                : '${player.playlist.length} tracks',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: _pickFolder,
                          child: Text(player.playlist.isEmpty
                              ? 'Choose folder'
                              : 'Change'),
                        ),
                      ],
                    ),
                    if (player.nowPlaying != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        player.nowPlaying!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (player.playlist.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.skip_previous),
                            onPressed: player.previous,
                          ),
                          IconButton.filledTonal(
                            icon: Icon(player.isPlaying
                                ? Icons.stop
                                : Icons.play_arrow),
                            onPressed: () async {
                              try {
                                player.isPlaying
                                    ? await player.stop()
                                    : await player.play();
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('$e')),
                                  );
                                }
                              }
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.skip_next),
                            onPressed: player.next,
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),

          // ── an app already running ──
          Row(
            children: [
              Expanded(
                child: Text('Or control a running app',
                    style: theme.textTheme.labelLarge),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: 'Look again',
                onPressed: _refreshPlayers,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Spotify, VLC, Rhythmbox, a browser — anything that supports the '
            'desktop media standard. No account or setup needed.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 10),

          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_players.isEmpty)
            _Hint(
              icon: Icons.music_off_outlined,
              text: MprisControl.isAvailable
                  ? 'No media player is running. Start Spotify or another '
                      'player, then tap refresh.'
                  : MprisControl.installHint,
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    if (_players.length > 1)
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final name in _players)
                            ChoiceChip(
                              label: Text(name),
                              selected: _selectedPlayer == name,
                              onSelected: (_) async {
                                setState(() => _selectedPlayer = name);
                                final track =
                                    await MprisControl.nowPlaying(name);
                                if (mounted) {
                                  setState(() => _nowPlaying = track);
                                }
                              },
                            ),
                        ],
                      )
                    else
                      Text(_players.first, style: theme.textTheme.bodyMedium),
                    if (_nowPlaying != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _nowPlaying!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () =>
                              MprisControl.previous(_selectedPlayer),
                        ),
                        IconButton.filledTonal(
                          icon: const Icon(Icons.play_arrow),
                          tooltip: 'Play or pause',
                          onPressed: () async {
                            await MprisControl.playPause(_selectedPlayer);
                            await Future<void>.delayed(
                                const Duration(milliseconds: 300));
                            final track =
                                await MprisControl.nowPlaying(_selectedPlayer);
                            if (mounted) setState(() => _nowPlaying = track);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => MprisControl.next(_selectedPlayer),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.outline),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
