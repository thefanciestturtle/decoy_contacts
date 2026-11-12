// Where the keyboard focus is, for the widget tests and the on-device tests.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The app bar's menu button (⋮).
final Finder menu = find.byKey(const Key('Menu'));

/// The keys of the four text fields, from the top.
const List<String> kFieldKeys = [
  'LastNames',
  'FirstNames',
  'PhoneNumberTemplate',
  'EmailAddressTemplate',
];

/// Whether the keyboard focus is on what [finder] finds, or inside it.
bool focusWithin(WidgetTester tester, Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null || finder.evaluate().isEmpty) return false;
  final element = tester.element(finder);
  var bFound = false;
  focused.visitAncestorElements((e) => !(bFound = e == element));
  return bFound;
}

/// Whether the keyboard focus is on the menu button.
bool menuFocused(WidgetTester tester) => focusWithin(tester, menu);

/// The label of the button with the keyboard focus, or null if none
/// has it.
String? focusedButton() {
  final focus = FocusManager.instance.primaryFocus;
  final button = focus is FocusScopeNode
      ? null
      : focus?.context?.findAncestorWidgetOfExactType<TextButton>() ??
          focus?.context?.findAncestorWidgetOfExactType<FilledButton>() ??
          focus?.context?.findAncestorWidgetOfExactType<OutlinedButton>();
  final child = button?.child;
  return child is Text ? child.data : (child is Semantics
      ? (child.child as Text?)?.data
      : null);
}

/// Where the keyboard focus is on the home page: 'menu', a field's key
/// (see [kFieldKeys]), a button's label, or null.
String? focusedPlace(WidgetTester tester) {
  if (menuFocused(tester)) return 'menu';
  for (final key in kFieldKeys) {
    if (focusWithin(tester, find.byKey(Key(key)))) return key;
  }
  return focusedButton();
}

/// Presses [key] [times] times, and says where the focus was after each.
Future<List<String?>> pressAll(
    WidgetTester tester, LogicalKeyboardKey key, int times) async {
  final seen = <String?>[];
  for (var i = 0; i < times; i++) {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
    seen.add(focusedPlace(tester));
  }
  return seen;
}
