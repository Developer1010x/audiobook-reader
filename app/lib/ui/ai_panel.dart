import 'package:flutter/material.dart';

/// Where AI output should appear, decided by how much room there is.
///
/// A modal sheet covering the page is the wrong shape for this feature: the
/// whole point of a summary is to read it *against* the passage it came from.
/// Covering the book to show the summary of the book is self-defeating.
enum AiPanelPlacement {
  /// Beside the page. The book narrows but stays fully visible and scrollable.
  side,

  /// Docked along the bottom, page above it. For shorter or portrait windows.
  bottom,

  /// A sheet over the page — only when the window is too small for anything
  /// else, where covering is genuinely unavoidable.
  overlay;

  /// Below this the page would be squeezed into uselessness by a side panel.
  static const _minWidthForSide = 900.0;
  static const _minHeightForBottom = 520.0;

  static AiPanelPlacement forSize(Size size) {
    if (size.width >= _minWidthForSide) return AiPanelPlacement.side;
    if (size.height >= _minHeightForBottom) return AiPanelPlacement.bottom;
    return AiPanelPlacement.overlay;
  }
}

/// Lays a reader out with an optional AI panel that does not cover the page.
///
/// The reader passes its own content and the panel; this decides the
/// arrangement from the available space and keeps the divider draggable, so the
/// user can favour the page or the summary as they please.
class AiPanelScaffold extends StatefulWidget {
  const AiPanelScaffold({
    super.key,
    required this.reader,
    required this.panel,
    required this.showPanel,
    this.onDismiss,
    this.initialFraction = 0.36,
  });

  /// The page itself.
  final Widget reader;

  /// The AI output, built only while [showPanel] is true.
  final WidgetBuilder panel;

  final bool showPanel;
  final VoidCallback? onDismiss;

  /// Share of the window the panel takes initially.
  final double initialFraction;

  @override
  State<AiPanelScaffold> createState() => _AiPanelScaffoldState();
}

class _AiPanelScaffoldState extends State<AiPanelScaffold> {
  late double _fraction = widget.initialFraction;

  /// Bounds on the drag: neither pane may be squeezed to a sliver, because a
  /// 40-pixel column of book is not a reading experience and a 40-pixel column
  /// of summary is not readable either.
  static const _minFraction = 0.2;
  static const _maxFraction = 0.6;

  @override
  Widget build(BuildContext context) {
    if (!widget.showPanel) return widget.reader;

    final size = MediaQuery.sizeOf(context);
    final placement = AiPanelPlacement.forSize(size);

    return switch (placement) {
      AiPanelPlacement.side => _sideBySide(size),
      AiPanelPlacement.bottom => _stacked(size),
      AiPanelPlacement.overlay => _overlaid(),
    };
  }

  Widget _sideBySide(Size size) {
    final theme = Theme.of(context);
    final panelWidth = size.width * _fraction;

    return Row(
      children: [
        Expanded(child: widget.reader),
        _Grip(
          axis: Axis.horizontal,
          onDrag: (delta) => setState(() {
            _fraction =
                (_fraction - delta / size.width).clamp(_minFraction, _maxFraction);
          }),
        ),
        SizedBox(
          width: panelWidth,
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: widget.panel(context),
          ),
        ),
      ],
    );
  }

  Widget _stacked(Size size) {
    final theme = Theme.of(context);
    final panelHeight = size.height * _fraction;

    return Column(
      children: [
        Expanded(child: widget.reader),
        _Grip(
          axis: Axis.vertical,
          onDrag: (delta) => setState(() {
            _fraction = (_fraction - delta / size.height)
                .clamp(_minFraction, _maxFraction);
          }),
        ),
        SizedBox(
          height: panelHeight,
          child: Material(
            color: theme.colorScheme.surfaceContainerLow,
            child: widget.panel(context),
          ),
        ),
      ],
    );
  }

  /// Last resort on a very small window. Even here the page shows through, and
  /// tapping it dismisses — so the book is never more than one tap away.
  Widget _overlaid() {
    final theme = Theme.of(context);
    return Stack(
      children: [
        widget.reader,
        Positioned.fill(
          child: GestureDetector(
            onTap: widget.onDismiss,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.35)),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            heightFactor: 0.7,
            child: Material(
              color: theme.colorScheme.surface,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
              ),
              child: widget.panel(context),
            ),
          ),
        ),
      ],
    );
  }
}

/// The draggable divider between page and panel.
class _Grip extends StatelessWidget {
  const _Grip({required this.axis, required this.onDrag});

  final Axis axis;
  final void Function(double delta) onDrag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final horizontal = axis == Axis.horizontal;

    return MouseRegion(
      cursor: horizontal
          ? SystemMouseCursors.resizeColumn
          : SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate:
            horizontal ? (d) => onDrag(d.delta.dx) : null,
        onVerticalDragUpdate: horizontal ? null : (d) => onDrag(d.delta.dy),
        child: Semantics(
          label: 'Resize the assistant panel',
          child: SizedBox(
            width: horizontal ? 10 : null,
            height: horizontal ? null : 10,
            child: Center(
              child: Container(
                width: horizontal ? 3 : 44,
                height: horizontal ? 44 : 3,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Header for the panel: title, an optional subtitle, and a close button that
/// is always in the same place regardless of placement.
class AiPanelHeader extends StatelessWidget {
  const AiPanelHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onClose,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
          ),
          ...actions,
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
