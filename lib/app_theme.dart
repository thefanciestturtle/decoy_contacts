// The app's look: Material 3 colours worked out from one seed colour, in a
// light and a dark version. The app follows the system's dark theme setting.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
/// The ring follows the button as drawn (its [Material]), not the space it
/// takes up: on Android a button is padded to a 48 dp tap target, taller
/// than the 40 dp button. It takes up no space, so nothing moves when it
/// shows. [shape] is the button's (all of the app's are stadiums).
class FocusRing extends StatefulWidget {
  const FocusRing(
      {super.key, required this.child, this.shape = const StadiumBorder()});

  final Widget child;
  final OutlinedBorder shape;

  /// How far outside the button's edge the ring ends: a 2 dp gap, then the
  /// ring, 3 dp wide.
  static const double outset = 5;

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

  void _highlightModeChanged(FocusHighlightMode _) {
    // Only a focused button's ring comes or goes.
    if (_bFocused) setState(() {});
  }

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
      child: _FocusRingPainter(
        shape: bShow
            ? widget.shape.copyWith(
                side: BorderSide(
                    color: Theme.of(context).colorScheme.secondary, width: 3))
            : null,
        child: widget.child,
      ),
    );
  }
}

/// Paints [shape] (with its side as the ring), if any, around the first
/// [Material] in [child], [FocusRing.outset] outside it.
class _FocusRingPainter extends SingleChildRenderObjectWidget {
  const _FocusRingPainter({required this.shape, required super.child});

  final OutlinedBorder? shape;

  @override
  RenderFocusRing createRenderObject(BuildContext context) =>
      RenderFocusRing(shape);

  @override
  void updateRenderObject(BuildContext context, RenderFocusRing renderObject) {
    renderObject.shape = shape;
  }
}

/// The render object of [FocusRing]. Public for tests: [ringRect].
class RenderFocusRing extends RenderProxyBox {
  RenderFocusRing(this._shape);

  /// The ring's shape, with its colour and width as the side; null while
  /// it isn't shown.
  OutlinedBorder? get shape => _shape;
  OutlinedBorder? _shape;
  set shape(OutlinedBorder? value) {
    if (value == _shape) return;
    _shape = value;
    markNeedsPaint();
  }

  /// Where the ring is (its outer edge), in this render object's
  /// coordinates; null while it isn't shown.
  Rect? get ringRect {
    if (_shape == null || child == null) return null;
    return _buttonRect().inflate(FocusRing.outset);
  }

  /// The button as drawn: the first [Material]'s shape inside (a button's
  /// Material is drawn by a RenderPhysicalShape); all of this box if there
  /// is none.
  Rect _buttonRect() {
    RenderPhysicalShape? found;
    void visit(RenderObject node) {
      if (found != null) return;
      if (node is RenderPhysicalShape) {
        found = node;
        return;
      }
      node.visitChildren(visit);
    }

    visitChildren(visit);
    final shape = found;
    if (shape == null || !shape.hasSize) return Offset.zero & size;
    return MatrixUtils.transformRect(
        shape.getTransformTo(this), Offset.zero & shape.size);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    final rect = ringRect;
    if (rect != null) _shape!.paint(context.canvas, rect.shift(offset));
  }
}
