// The app's look: Material 3 colours worked out from one seed colour, in a
// light and a dark version. The app follows the system's dark theme setting.

import 'package:flutter/material.dart';

/// The theme for [brightness]: the colours from the seed, and outlined text
/// fields (the name lists, several lines long, keep a clear edge).
ThemeData appTheme(Brightness brightness) => ThemeData(
      colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue, brightness: brightness),
      inputDecorationTheme:
          const InputDecorationThemeData(border: OutlineInputBorder()),
    );

/// For a button that deletes something, as an outlined button: in the error
/// colour; greyed like any other button while disabled.
ButtonStyle destructiveButtonStyle(ColorScheme colors) =>
    OutlinedButton.styleFrom(foregroundColor: colors.error).copyWith(
      side: WidgetStateProperty.resolveWith((states) => BorderSide(
          color: states.contains(WidgetState.disabled)
              // Material's own disabled outline.
              ? colors.onSurface.withValues(alpha: 0.12)
              : colors.error)),
    );

/// Material 3's focus indicator around a button: a ring 3 dp wide in the
/// secondary colour, 2 dp outside the button's edge, while the button has
/// the keyboard focus and a keyboard or D-pad is in use (never after a tap
/// on the screen). Flutter's buttons only tint themselves a little when
/// focused, which is hard to see, on a filled button hardly at all.
///
/// The ring takes up no space, so nothing moves when it shows. [shape] is
/// the button's (all of the app's are stadiums).
class FocusRing extends StatefulWidget {
  const FocusRing(
      {super.key, required this.child, this.shape = const StadiumBorder()});

  final Widget child;
  final OutlinedBorder shape;

  /// The ring's key, for tests.
  static const Key ringKey = Key('FocusRing');

  @override
  State<FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<FocusRing> {
  bool _bFocused = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_highlightModeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    super.dispose();
  }

  void _highlightModeChanged(FocusHighlightMode _) => setState(() {});

  @override
  Widget build(BuildContext context) {
    final bShow = _bFocused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    // Told when the button in it gets or loses the focus; never takes the
    // focus itself, and adds nothing for TalkBack.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (bFocused) => setState(() => _bFocused = bFocused),
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          widget.child,
          if (bShow)
            Positioned(
              key: FocusRing.ringKey,
              left: -5,
              top: -5,
              right: -5,
              bottom: -5,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: widget.shape.copyWith(
                        side: BorderSide(
                            color: Theme.of(context).colorScheme.secondary,
                            width: 3)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
