import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Desktop keyboard control for both reading screens.
///
/// Mirrors Car Mode's bindings so one set of keys works everywhere:
///   Space        play / pause
///   ← / →        previous / next sentence
///   ↓ / ↑        slower / faster (Car Mode's speed ladder)
///   PgUp / PgDn  previous / next page
///   ⌘B / Ctrl+B  toggle bookmark
///   ⌘F / Ctrl+F  search (when the screen has search)
///   Esc          back
///
/// Wrapped around the whole screen, so keys still arrive after a click moves
/// focus into the page viewer: key events bubble up from the focused widget.
///
/// While a text field has focus, the plain keys (Space, arrows, PgUp/PgDn)
/// stand aside. Bubbling means this widget sees a key *before* the app-wide
/// text-editing shortcuts that let a field keep it, so without the check a
/// space typed into search would start playback and never reach the field.
/// A disabled action makes [Shortcuts] return `ignored`, and the key carries on
/// to the field. Esc and the ⌘/Ctrl chords type nothing, so they always work.
class ReaderShortcuts extends StatelessWidget {
  const ReaderShortcuts({
    super.key,
    required this.enabled,
    required this.onPlayPause,
    required this.onSkipSentence,
    required this.onRateStep,
    required this.onPage,
    required this.onBookmark,
    required this.onBack,
    this.onSearch,
    required this.child,
  });

  /// False while an overlay (Car Mode) brings its own bindings.
  final bool enabled;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSkipSentence;
  final ValueChanged<int> onRateStep;
  final ValueChanged<int> onPage;
  final VoidCallback onBookmark;
  final VoidCallback onBack;
  final VoidCallback? onSearch;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final search = onSearch;
    _KeyIntent plain(VoidCallback cb) => _KeyIntent(cb, typing: true);
    _KeyIntent chord(VoidCallback cb) => _KeyIntent(cb, typing: false);
    return Shortcuts(
      shortcuts: {
        const SingleActivator(LogicalKeyboardKey.space): plain(onPlayPause),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): plain(() => onSkipSentence(-1)),
        const SingleActivator(LogicalKeyboardKey.arrowRight): plain(() => onSkipSentence(1)),
        const SingleActivator(LogicalKeyboardKey.arrowDown): plain(() => onRateStep(-1)),
        const SingleActivator(LogicalKeyboardKey.arrowUp): plain(() => onRateStep(1)),
        const SingleActivator(LogicalKeyboardKey.pageUp): plain(() => onPage(-1)),
        const SingleActivator(LogicalKeyboardKey.pageDown): plain(() => onPage(1)),
        const SingleActivator(LogicalKeyboardKey.keyB, meta: true): chord(onBookmark),
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): chord(onBookmark),
        if (search != null) ...{
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): chord(search),
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): chord(search),
        },
        const SingleActivator(LogicalKeyboardKey.escape): chord(onBack),
      },
      child: Actions(
        actions: {_KeyIntent: _KeyAction()},
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class _KeyIntent extends Intent {
  const _KeyIntent(this.run, {required this.typing});
  final VoidCallback run;

  /// True for keys a text field would otherwise receive.
  final bool typing;
}

class _KeyAction extends Action<_KeyIntent> {
  @override
  bool isEnabled(_KeyIntent intent) => !(intent.typing && _textFieldFocused());

  @override
  Object? invoke(_KeyIntent intent) {
    intent.run();
    return null;
  }

  static bool _textFieldFocused() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}
