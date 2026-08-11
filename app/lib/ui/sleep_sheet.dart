import 'package:flutter/material.dart';

import '../services/chapter_index.dart';
import '../services/settings_service.dart';
import '../services/sleep_timer.dart';
import 'widgets/sleep_chip.dart';

/// Set, extend or cancel the sleep timer.
///
/// Durations are the ones people actually reach for at night; the end-of-page
/// and end-of-chapter endings exist because a fixed timer that lands mid-clause
/// is precisely what wakes someone up.
class SleepSheet extends StatefulWidget {
  const SleepSheet({
    super.key,
    required this.settings,
    required this.timer,
    required this.chapters,
  });

  final SettingsService settings;
  final SleepTimer timer;
  final ChapterIndex chapters;

  @override
  State<SleepSheet> createState() => _SleepSheetState();
}

class _SleepSheetState extends State<SleepSheet> {
  static const _durations = [
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
  ];

  SleepTimer get _timer => widget.timer;

  void _arm(SleepMode mode, {Duration? total}) {
    _timer.arm(mode, total: total, fadeSeconds: widget.settings.sleepFadeSeconds);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListenableBuilder(
      listenable: _timer,
      builder: (context, _) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Sleep timer', style: theme.textTheme.titleLarge),
                ),
                if (_timer.isArmed)
                  TextButton.icon(
                    onPressed: () {
                      _timer.cancel();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close, size: 18),
                    label: const Text('Cancel'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _statusLine(),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 20),

            // Extending is offered first when a timer is already running: it is
            // what someone reaches for when the voice starts fading and they
            // are not asleep yet.
            if (_timer.isArmed && _timer.mode == SleepMode.duration) ...[
              Wrap(
                spacing: 8,
                children: [
                  for (final extra in const [
                    Duration(minutes: 5),
                    Duration(minutes: 10),
                    Duration(minutes: 15),
                  ])
                    ActionChip(
                      avatar: const Icon(Icons.add, size: 15),
                      label: Text('${extra.inMinutes} min'),
                      onPressed: () {
                        _timer.extend(extra);
                        setState(() {});
                      },
                    ),
                ],
              ),
              const SizedBox(height: 20),
            ],

            Text('Stop after', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final duration in _durations)
                  ChoiceChip(
                    label: Text(_durationLabel(duration)),
                    selected: _timer.mode == SleepMode.duration &&
                        _timer.total == duration,
                    onSelected: (_) =>
                        _arm(SleepMode.duration, total: duration),
                  ),
              ],
            ),
            const SizedBox(height: 20),

            Text('Or finish the section', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  avatar: const Icon(Icons.article_outlined, size: 16),
                  label: const Text('End of page'),
                  selected: _timer.mode == SleepMode.endOfPage,
                  onSelected: (_) => _arm(SleepMode.endOfPage),
                ),
                ChoiceChip(
                  avatar: const Icon(Icons.menu_book_outlined, size: 16),
                  label: const Text('End of chapter'),
                  selected: _timer.mode == SleepMode.endOfChapter,
                  // Without an outline there are no chapter boundaries to stop
                  // at, so the option is disabled rather than silently behaving
                  // like end-of-book.
                  onSelected: widget.chapters.hasChapters
                      ? (_) => _arm(SleepMode.endOfChapter)
                      : null,
                ),
              ],
            ),
            if (!widget.chapters.hasChapters) ...[
              const SizedBox(height: 6),
              Text(
                'This book has no chapter marks, so only end-of-page is available.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],

            const Divider(height: 36),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Fade out before stopping'),
              subtitle: Text(
                widget.settings.sleepFadeSeconds > 0
                    ? 'Volume eases down over the last '
                        '${widget.settings.sleepFadeSeconds} seconds.'
                    : 'Stops at full volume.',
                style: const TextStyle(fontSize: 12),
              ),
              value: widget.settings.sleepFadeSeconds > 0,
              onChanged: (on) async {
                await widget.settings.setSleepFadeSeconds(on ? 30 : 0);
                if (mounted) setState(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also stop background music'),
              value: widget.settings.sleepStopsMusic,
              onChanged: (on) async {
                await widget.settings.setSleepStopsMusic(on);
                if (mounted) setState(() {});
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Also pause Spotify and other players'),
              subtitle: const Text(
                'Uses the desktop media controls.',
                style: TextStyle(fontSize: 12),
              ),
              value: widget.settings.sleepPausesMpris,
              onChanged: (on) async {
                await widget.settings.setSleepPausesMpris(on);
                if (mounted) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  String _statusLine() {
    if (!_timer.isArmed) return 'Not set — reading continues until you stop it.';
    return switch (_timer.mode) {
      SleepMode.duration =>
        'Stopping in ${formatRemaining(_timer.remaining)}'
            '${_timer.phase == SleepPhase.fading ? ' — fading out now' : ''}.',
      SleepMode.endOfPage => 'Stopping at the end of this page.',
      SleepMode.endOfChapter => 'Stopping at the end of this chapter.',
      SleepMode.off => '',
    };
  }

  static String _durationLabel(Duration d) =>
      d.inMinutes >= 60 ? '1 hour' : '${d.inMinutes} min';
}
