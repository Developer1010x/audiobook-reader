import 'package:flutter/material.dart';

import '../../services/stats_service.dart';

/// A compact reading-activity strip: streak, today, and a 14-day sparkline.
class ReadingStats extends StatelessWidget {
  final StatsService stats;
  const ReadingStats({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final streak = stats.streak;
    final recent = stats.recent();

    // Nothing read yet — a row of zeroes is noise, not encouragement.
    if (stats.totalPages == 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          _Metric(
            value: '$streak',
            label: streak == 1 ? 'day streak' : 'day streak',
            icon: Icons.local_fire_department,
            highlight: streak > 0,
          ),
          const SizedBox(width: 24),
          _Metric(value: '${stats.pagesToday}', label: 'pages today'),
          const SizedBox(width: 24),
          _Metric(value: '${stats.totalPages}', label: 'pages total'),
          const Spacer(),
          SizedBox(
            width: 120,
            height: 34,
            child: CustomPaint(
              painter: _Sparkline(
                values: recent,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String value;
  final String label;
  final IconData? icon;
  final bool highlight;

  const _Metric({
    required this.value,
    required this.label,
    this.icon,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            if (icon != null) ...[
              Icon(icon,
                  size: 15,
                  color: highlight ? Colors.orange : theme.colorScheme.outline),
              const SizedBox(width: 4),
            ],
            Text(value,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
        Text(label,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }
}

/// Bar sparkline. Bars beat a line here — daily reading is spiky, and a line
/// implies a continuity the data does not have.
class _Sparkline extends CustomPainter {
  final List<int> values;
  final Color color;

  const _Sparkline({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final max = values.reduce((a, b) => a > b ? a : b);
    if (max == 0) return;

    final gap = 2.0;
    final barWidth = (size.width - gap * (values.length - 1)) / values.length;

    for (var i = 0; i < values.length; i++) {
      final ratio = values[i] / max;
      final height = (size.height * ratio).clamp(2.0, size.height);
      final x = i * (barWidth + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - height, barWidth, height),
          const Radius.circular(1.5),
        ),
        Paint()
          ..color = color.withValues(alpha: values[i] == 0 ? 0.15 : 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(_Sparkline old) => old.values != values;
}
