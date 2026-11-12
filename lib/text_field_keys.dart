// Arrow keys out of a text field, for a D-pad, which has no Tab key.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The text field that [focus] belongs to, if any.
EditableTextState? editableTextOf(FocusNode? focus) =>
    focus?.context?.findAncestorStateOfType<EditableTextState>();

const SingleActivator _up =
    SingleActivator(LogicalKeyboardKey.arrowUp, includeRepeats: false);
const SingleActivator _down =
    SingleActivator(LogicalKeyboardKey.arrowDown, includeRepeats: false);

/// In the text fields in [child]: Up with the caret at the very start
/// moves the keyboard focus to what is above the field, and Down with the
/// caret at the very end to what is below it.
///
/// Elsewhere Flutter's arrow keys only move the caret: Up on the first
/// line goes to the start, Down on the last line to the end, and from
/// there they did nothing, so a D-pad user who entered a field could never
/// leave it. Android's own text fields let a D-pad out the same way.
/// (Android keeps a keyboard's arrows inside, as a keyboard has Tab; here
/// any arrow key leaves: Flutter reports a D-pad that also calls itself a
/// keyboard, as some remotes do, as a keyboard.)
///
/// Only on a fresh press: a key held down to get to the start or the end
/// of the text stops there (as on the About screen). Not with Shift (which
/// selects) or another modifier, nor with text selected (the arrow then
/// ends the selection first). Left and Right only move the caret: all of
/// the app's fields are in one column, and Right would otherwise jump to
/// the menu button on a wide screen.
///
/// (A field's own key handling comes first, then this, then Flutter's text
/// editing keys, which are bound above the whole app.)
class ArrowsLeaveTextFields extends StatelessWidget {
  const ArrowsLeaveTextFields({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        includeSemantics: false,
        onKeyEvent: (_, event) => _leaveAtEdge(event),
        child: child,
      );

  static KeyEventResult _leaveAtEdge(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final bool bUp = _up.accepts(event, keyboard);
    if (!bUp && !_down.accepts(event, keyboard)) return KeyEventResult.ignored;
    final FocusNode? node = FocusManager.instance.primaryFocus;
    final editable = editableTextOf(node);
    if (node == null || editable == null || editable.widget.focusNode != node) {
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
}
