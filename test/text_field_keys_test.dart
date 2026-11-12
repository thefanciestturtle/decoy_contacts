import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fake_contacts/text_field_keys.dart';

/// A button, a field of three lines, a field of one line and a button,
/// one above the other, in [ArrowsLeaveTextFields].
class _Page {
  final FocusNode above = FocusNode(debugLabel: 'above');
  final FocusNode lines = FocusNode(debugLabel: 'lines');
  final FocusNode line = FocusNode(debugLabel: 'line');
  final FocusNode below = FocusNode(debugLabel: 'below');
  final TextEditingController linesText =
      TextEditingController(text: 'one\ntwo\nthree');
  final TextEditingController lineText = TextEditingController(text: 'abc');

  /// Shows the page; with [bAbove] false, without the button above.
  Future<void> pump(WidgetTester tester, {bool bAbove = true}) async {
    addTearDown(() {
      for (final node in [above, lines, line, below]) {
        node.dispose();
      }
      linesText.dispose();
      lineText.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ArrowsLeaveTextFields(
          child: Column(children: [
            if (bAbove)
              TextButton(focusNode: above, onPressed: () {}, child: const Text('Above')),
            TextField(controller: linesText, focusNode: lines, maxLines: 4),
            TextField(controller: lineText, focusNode: line),
            TextButton(focusNode: below, onPressed: () {}, child: const Text('Below')),
          ]),
        ),
      ),
    ));
  }

  /// Gives [node]'s field the focus, with the caret at [offset].
  Future<void> focus(WidgetTester tester, FocusNode node, int offset) async {
    node.requestFocus();
    await tester.pump();
    (node == lines ? linesText : lineText).selection =
        TextSelection.collapsed(offset: offset);
    await tester.pump();
  }

  /// Which of the four has the focus, and where the caret is, if in a field.
  String where() {
    for (final (node, name) in [(above, 'above'), (below, 'below')]) {
      if (node.hasPrimaryFocus) return name;
    }
    for (final (node, name, text) in [
      (lines, 'lines', linesText),
      (line, 'line', lineText),
    ]) {
      if (node.hasPrimaryFocus) {
        final s = text.selection;
        return s.isCollapsed ? '$name ${s.baseOffset}' : '$name ${s.start}-${s.end}';
      }
    }
    return 'none';
  }
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  testWidgets('Down goes to the end of the last line first, then out of the '
      'field; Up to the start of the first line first, then out', (tester) async {
    final page = _Page();
    await page.pump(tester);
    await page.focus(tester, page.lines, 1);

    final seen = <String>[];
    for (var i = 0; i < 6; i++) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      seen.add(page.where());
    }
    // 'one\ntwo\nthree': the line below, its end, then the next field, which
    // keeps its caret where it was (here, at the end), so on to the button.
    expect(seen, ['lines 5', 'lines 9', 'lines 13', 'line 3', 'below', 'below']);

    seen.clear();
    for (var i = 0; i < 7; i++) {
      await press(tester, LogicalKeyboardKey.arrowUp);
      seen.add(page.where());
    }
    // Its only line: to the start first. Then up a line at a time (where
    // in the line is Flutter's business), to the start, and out.
    expect(seen, [
      'line 3', 'line 0',
      'lines 13', startsWith('lines '), startsWith('lines '), 'lines 0', 'above',
    ]);
  });

  testWidgets('an empty field is left at once', (tester) async {
    final page = _Page();
    await page.pump(tester);
    page.lineText.clear();
    await page.focus(tester, page.line, 0);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'below');
    await page.focus(tester, page.line, 0);
    await press(tester, LogicalKeyboardKey.arrowUp);
    // (Never edited, it gets the caret at the end.)
    expect(page.where(), 'lines 13');
  });

  testWidgets('a key held down stops at the edge; only a fresh press leaves',
      (tester) async {
    final page = _Page();
    await page.pump(tester);
    await page.focus(tester, page.lines, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
    }
    await tester.pump();
    expect(page.where(), 'lines 13');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'line 3');

    await page.focus(tester, page.lines, 13);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    for (var i = 0; i < 6; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowUp);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(page.where(), 'lines 0');
  });

  testWidgets('a key held down since before the focus came into the fields '
      'goes on through them, as on Android', (tester) async {
    final page = _Page();
    await page.pump(tester);
    page.above.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(page.where(), 'lines 13');
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(page.where(), 'below');
  });

  testWidgets("the arrow keys of an on-screen keyboard only move the caret: "
      "Flutter doesn't switch to moving around by keys for them",
      (tester) async {
    final page = _Page();
    await page.pump(tester);
    // As after a tap into the field, with only the on-screen keyboard's
    // keys pressed since.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTouch;
    addTearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);
    await page.focus(tester, page.lines, 0);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'lines 0');
    await page.focus(tester, page.line, 3);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'line 3');

    // Once keys are used to move around, the same press leaves.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'below');
  });

  testWidgets('with Shift or Control, at the edge, the focus stays',
      (tester) async {
    final page = _Page();
    await page.pump(tester);
    for (final modifier in [
      LogicalKeyboardKey.shiftLeft,
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.altLeft,
    ]) {
      for (final (key, offset) in [
        (LogicalKeyboardKey.arrowDown, 13),
        (LogicalKeyboardKey.arrowUp, 0),
      ]) {
        await page.focus(tester, page.lines, offset);
        await tester.sendKeyDownEvent(modifier);
        await press(tester, key);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
        expect(page.where(), startsWith('lines '), reason: '$modifier $key');
      }
    }
  });

  testWidgets('with text selected up to the edge, the arrow ends the '
      'selection first', (tester) async {
    final page = _Page();
    await page.pump(tester);
    await page.focus(tester, page.lines, 0);
    page.linesText.selection =
        const TextSelection(baseOffset: 4, extentOffset: 13);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'lines 13');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'line 3');

    await page.focus(tester, page.lines, 0);
    page.linesText.selection =
        const TextSelection(baseOffset: 9, extentOffset: 0);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'lines 0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'above');
  });

  testWidgets('Left at the start and Right at the end only move the caret',
      (tester) async {
    final page = _Page();
    await page.pump(tester);
    await page.focus(tester, page.line, 0);
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(page.where(), 'line 0');
    await page.focus(tester, page.line, 3);
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(page.where(), 'line 3');
    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(page.where(), 'line 2');
  });

  testWidgets('a field tapped after earlier arrow moves: Up goes up and Down '
      'goes down', (tester) async {
    final page = _Page();
    await page.pump(tester);
    // Flutter remembers where each move came from, and sends a move the
    // opposite way back there; a tap doesn't clear that.
    page.above.requestFocus();
    await tester.pump();
    for (final expected in ['lines 13', 'line 3', 'below']) {
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(page.where(), expected);
    }
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    await page.focus(tester, page.lines, 0);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'above');

    // And the other way: after that move up, a tap into the lower field.
    await tester.tap(find.byType(TextField).last);
    await tester.pump();
    await page.focus(tester, page.line, 3);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(page.where(), 'below');
  });

  testWidgets('with nothing above, Up at the start does nothing',
      (tester) async {
    final page = _Page();
    await page.pump(tester, bAbove: false);
    await page.focus(tester, page.lines, 0);
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'lines 0');
    await press(tester, LogicalKeyboardKey.arrowUp);
    expect(page.where(), 'lines 0');
  });
}
