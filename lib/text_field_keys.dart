// Arrow keys out of a text field, for a D-pad, which has no Tab key.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The text field that [focus] belongs to, if any.
EditableTextState? editableTextOf(FocusNode? focus) =>
    focus?.context?.findAncestorStateOfType<EditableTextState>();

const SingleActivator _up = SingleActivator(LogicalKeyboardKey.arrowUp);
const SingleActivator _down = SingleActivator(LogicalKeyboardKey.arrowDown);

/// In the text fields in [child] (the app puts it around all of its
/// screens): Up with the caret at the very start moves the keyboard focus
/// to what is above the field, and Down with the caret at the very end to
/// what is below it.
///
/// Elsewhere Flutter's arrow keys only move the caret: Up on the first
/// line goes to the start, Down on the last line to the end, and from
/// there they did nothing, so a D-pad user who entered a field could never
/// leave it. Android's own text fields let a D-pad out the same way.
/// (Android keeps a keyboard's arrows inside, as a keyboard has Tab; here
/// any arrow key leaves: Flutter reports a D-pad that also calls itself a
/// keyboard, as some remotes do, as a keyboard.)
///
/// - Only while keys are being used to move around (the mode in which
///   focus rings show), not for the arrow keys of an on-screen keyboard:
///   Flutter leaves the mode as it was for those, so after a tap into the
///   field they only move the caret, and the keyboard stays open. (Flutter
///   tells them by Android's soft keyboard flag or virtual device, a check
///   it means to replace, flutter/flutter#136419; checked on API 36.)
/// - A key held down to get to the start or the end of the field it was
///   pressed in stops there (as on the About screen); one held down since
///   before the focus came into the field goes on through it, as on
///   Android.
/// - Not with Shift (which selects) or another modifier, nor with text
///   selected (the arrow then ends the selection first).
/// - Left and Right only move the caret: all of the app's fields are in
///   one column, and Right would otherwise jump to the menu button on a
///   wide screen.
///
/// (A field's own key handling comes first, then this, then Flutter's text
/// editing keys, which are bound above the whole app.)
class ArrowsLeaveTextFields extends StatefulWidget {
  const ArrowsLeaveTextFields({super.key, required this.child});

  final Widget child;

  @override
  State<ArrowsLeaveTextFields> createState() => _ArrowsLeaveTextFieldsState();
}

class _ArrowsLeaveTextFieldsState extends State<ArrowsLeaveTextFields> {
  /// What had the focus when Up or Down went down, until it comes up: a
  /// repeat of it stops at the edge of that field only.
  FocusNode? _pressedIn;

  @override
  void initState() {
    super.initState();
    // (Told of every key, wherever the focus is, before anything acts on it.)
    HardwareKeyboard.instance.addHandler(_noteWhereKeyWentDown);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_noteWhereKeyWentDown);
    super.dispose();
  }

  bool _noteWhereKeyWentDown(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (event is KeyDownEvent) _pressedIn = FocusManager.instance.primaryFocus;
      // (Not kept: the screen it was on may have gone.)
      if (event is KeyUpEvent) _pressedIn = null;
    }
    return false;
  }

  KeyEventResult _leaveAtEdge(KeyEvent event) {
    if (FocusManager.instance.highlightMode != FocusHighlightMode.traditional) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final bool bUp = _up.accepts(event, keyboard);
    if (!bUp && !_down.accepts(event, keyboard)) return KeyEventResult.ignored;
    final FocusNode? node = FocusManager.instance.primaryFocus;
    final editable = editableTextOf(node);
    if (node == null || editable == null || editable.widget.focusNode != node) {
      return KeyEventResult.ignored;
    }
    if (event is KeyRepeatEvent && _pressedIn == node) {
      return KeyEventResult.ignored;
    }
    final TextEditingValue value = editable.textEditingValue;
    final TextSelection selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final bool bAtEdge =
        selection.extentOffset == (bUp ? 0 : value.text.length);
    if (!bAtEdge) return KeyEventResult.ignored;
    // Flutter's directional moves remember where the focus came from, and
    // a move the opposite way goes back there. A tap into a field doesn't
    // clear that, so a field tapped after earlier D-pad moves could send
    // Up down to where an earlier Down came from. The move out of the
    // field is remembered afresh, so a move back still returns to it.
    final scope = node.nearestScope;
    if (scope != null) {
      FocusTraversalGroup.of(node.context!).invalidateScopeData(scope);
    }
    // (If there is nothing that way, Flutter's own handling does nothing.)
    return node.focusInDirection(
            bUp ? TraversalDirection.up : TraversalDirection.down)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: (_, event) => _leaveAtEdge(event),
        child: widget.child,
      );
}
