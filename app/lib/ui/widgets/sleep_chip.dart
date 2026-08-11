import 'package:flutter/material.dart';

import '../../services/sleep_timer.dart';

/// The armed-sleep-timer indicator for the reader's app bar.
///
/// Small on purpose. Someone who has set a sleep timer is winding down, and a
/// prominent countdown is the opposite of restful — but it has to be *there*,
/// because a timer you cannot see is one you cannot trust to have been set.
class SleepChip extends StatelessWidget {
  const SleepChip({super.key, required this.timer, this.onTap});

  final SleepTimer timer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!timer.isArmed) return const SizedBox.shrink();

    final fading = timer.phase == SleepPhase.fading;
    final colour = fading ? theme.colorScheme.tertiary : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        button: true,
        label: 'Sleep timer, ${_semanticLabel()}. Tap to change.',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: colour.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: colour.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  timer.isHeld ? Icons.pause_circle_outline : Icons.bedtime_outlined,
                  size: 15,
                  color: colour,
                ),
                const SizedBox(width: 5),
                Text(
                  _label(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: colour,
                    fontWeight: FontWeight.w600,
                    // Digits must not jitter as the countdown ticks.
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _label() => switch (timer.mode) {
        SleepMode.endOfPage => 'page',
        SleepMode.endOfChapter => 'chapter',
        SleepMode.duration => formatRemaining(timer.remaining),
        SleepMode.off => '',
      };

  String _semanticLabel() => switch (timer.mode) {
        SleepMode.endOfPage => 'stopping at the end of this page',
        SleepMode.endOfChapter => 'stopping at the end of this chapter',
        SleepMode.duration =>
          '${timer.remaining.inMinutes} minutes remaining',
        SleepMode.off => 'off',
      };
}

/// Countdown text.
///
/// Minutes while there is time left, seconds only in the last minute — a
/// display that changes every second for an hour is a distraction, but "1 min"
/// frozen for sixty seconds looks broken at the end.
String formatRemaining(Duration remaining) {
  if (remaining.inSeconds <= 0) return '0:00';
  if (remaining.inMinutes >= 1) {
    final minutes = remaining.inMinutes;
    if (minutes >= 60) {
      final hours = minutes ~/ 60;
      return '${hours}h ${minutes % 60}m';
    }
    return '$minutes min';
  }
  return '0:${remaining.inSeconds.toString().padLeft(2, '0')}';
}
