// The app's look: Material 3 colours worked out from one seed colour, in a
// light and a dark version. The app follows the system's dark theme setting.

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

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
///
/// With [inward], the ring is drawn just inside the edge of all of [child]
/// instead, as Material 3 does for a menu item (see [RingedMenuItem]), which
/// has no edge of its own and fills the menu's width.
///
/// With [focusNode], the ring shows while that node itself has the focus,
/// not while something inside it has: for an area that takes the focus
/// and holds buttons of its own. (It can change to another node, but not
/// to or from none.)
class FocusRing extends StatefulWidget {
  const FocusRing(
      {super.key,
      required this.child,
      this.shape = const StadiumBorder(),
      this.inward = false,
      this.focusNode});

  final Widget child;
  final OutlinedBorder shape;
  final bool inward;
  final FocusNode? focusNode;

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
    widget.focusNode?.addListener(_nodeChanged);
    _bFocused = widget.focusNode?.hasPrimaryFocus ?? false;
  }

  @override
  void didUpdateWidget(FocusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert((oldWidget.focusNode == null) == (widget.focusNode == null),
        'A FocusRing can change its focusNode, but not to or from none.');
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode?.removeListener(_nodeChanged);
      widget.focusNode?.addListener(_nodeChanged);
      _bFocused = widget.focusNode?.hasPrimaryFocus ?? false;
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_highlightModeChanged);
    widget.focusNode?.removeListener(_nodeChanged);
    super.dispose();
  }

  /// For [FocusRing.focusNode].
  void _nodeChanged() {
    final node = widget.focusNode;
    if (node == null || node.hasPrimaryFocus == _bFocused) return;
    if (!mounted) return;
    setState(() => _bFocused = node.hasPrimaryFocus);
  }

  void _highlightModeChanged(FocusHighlightMode _) {
    // Only a focused button's ring comes or goes.
    if (_bFocused) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bShow = _bFocused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final painter = _FocusRingPainter(
      inward: widget.inward,
      shape: bShow
          ? widget.shape.copyWith(
              side: BorderSide(
                  color: Theme.of(context).colorScheme.secondary, width: 3))
          : null,
      child: widget.child,
    );
    // Told when the button in it gets or loses the focus (unless it
    // follows [FocusRing.focusNode] instead); never takes the focus itself,
    // and adds nothing for TalkBack.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onFocusChange: (bFocused) {
        if (widget.focusNode == null) setState(() => _bFocused = bFocused);
      },
      child: painter,
    );
  }
}

/// Paints [shape] (with its side as the ring), if any, around the first
/// [Material] in [child], [FocusRing.outset] outside it; or, if [inward],
/// just inside the edge of all of [child].
class _FocusRingPainter extends SingleChildRenderObjectWidget {
  const _FocusRingPainter(
      {required this.shape, required this.inward, required super.child});

  final OutlinedBorder? shape;
  final bool inward;

  @override
  RenderFocusRing createRenderObject(BuildContext context) =>
      RenderFocusRing(shape, inward: inward);

  @override
  void updateRenderObject(BuildContext context, RenderFocusRing renderObject) {
    renderObject
      ..shape = shape
      ..inward = inward;
  }
}

/// The render object of [FocusRing]. Public for tests: [ringRect].
class RenderFocusRing extends RenderProxyBox {
  RenderFocusRing(this._shape, {this._inward = false});

  /// See [FocusRing.inward].
  bool get inward => _inward;
  bool _inward;
  set inward(bool value) {
    if (value == _inward) return;
    _inward = value;
    markNeedsPaint();
  }

  /// The ring's shape, with its colour and width as the side; null while
  /// it isn't shown.
  OutlinedBorder? get shape => _shape;
  OutlinedBorder? _shape;
  set shape(OutlinedBorder? value) {
    if (value == _shape) return;
    _shape = value;
    markNeedsPaint();
  }

  /// Where the ring is (its outer edge; the ring is drawn inside it), in
  /// this render object's coordinates: [FocusRing.outset] outside the
  /// button, or, if [inward], all of this box. Null while it isn't shown.
  Rect? get ringRect {
    if (_shape == null || child == null) return null;
    // (The ring is drawn inside the shape's edge.)
    return _inward ? Offset.zero & size : _buttonRect().inflate(FocusRing.outset);
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

/// A [PopupMenuItem] with a [FocusRing] inside its edge while it has the
/// keyboard focus: Flutter shows that only as a faint tint.
class RingedMenuItem<T> extends PopupMenuItem<T> {
  const RingedMenuItem({
    super.key,
    super.value,
    super.onTap,
    super.enabled,
    super.height,
    super.padding,
    super.textStyle,
    super.labelTextStyle,
    super.mouseCursor,
    required super.child,
  });

  @override
  PopupMenuItemState<T, RingedMenuItem<T>> createState() =>
      _RingedMenuItemState<T>();
}

class _RingedMenuItemState<T>
    extends PopupMenuItemState<T, RingedMenuItem<T>> {
  @override
  Widget build(BuildContext context) => FocusRing(
        inward: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(4))),
        child: super.build(context),
      );
}
