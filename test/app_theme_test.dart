import 'package:fake_contacts/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The contrast ratio of two colours, as WCAG defines it (1 to 21).
double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    group('${brightness.name} theme', () {
      final theme = appTheme(brightness);
      final colors = theme.colorScheme;

      test('is Material 3, with the brightness asked for', () {
        expect(theme.useMaterial3, isTrue);
        expect(colors.brightness, brightness);
      });

      test('text fields are outlined', () {
        expect(theme.inputDecorationTheme.border, isA<OutlineInputBorder>());
      });

      // The page's background is surface (Scaffold); the dialog's is
      // surfaceContainerHigh (Material 3's AlertDialog).
      // WCAG AA: 4.5:1 for text, 3:1 for the edges of controls.
      final background = colors.surface;
      for (final (what, color, on, minimum) in [
        ('text: fields, status line, results', colors.onSurface, background, 4.5),
        ('preview, field labels, helper text and warnings',
            colors.onSurfaceVariant, background, 4.5),
        ('a focused field\'s label', colors.primary, background, 4.5),
        ('Delete\'s text, failed results', colors.error, background, 4.5),
        ('Create\'s text on the button', colors.onPrimary, colors.primary, 4.5),
        ('Create\'s button on the page', colors.primary, background, 3.0),
        ('the edges of the fields', colors.outline, background, 3.0),
        ('the focus ring around a button', colors.secondary, background, 3.0),
        // The dialog that asks before Create and Delete.
        ('the dialog\'s title and text', colors.onSurface,
            colors.surfaceContainerHigh, 4.5),
        ('the dialog\'s buttons', colors.primary, colors.surfaceContainerHigh,
            4.5),
        ('the dialog\'s Delete', colors.error, colors.surfaceContainerHigh,
            4.5),
        ('the focus ring in the dialog', colors.secondary,
            colors.surfaceContainerHigh, 3.0),
        // The app bar's menu button; the app bar turns surfaceContainer
        // when the page is scrolled under it.
        ('the menu button', colors.onSurfaceVariant, background, 3.0),
        ('the menu button, scrolled under', colors.onSurfaceVariant,
            colors.surfaceContainer, 3.0),
        ('the focus ring on a scrolled app bar', colors.secondary,
            colors.surfaceContainer, 3.0),
        // Its menu is surfaceContainer (Material 3's popup menu); a
        // focused item is tinted in the theme's focus colour, and has the
        // ring inside its edge.
        ('the menu\'s items', colors.onSurface, colors.surfaceContainer, 4.5),
        ('a focused menu item', colors.onSurface,
            Color.alphaBlend(theme.focusColor, colors.surfaceContainer), 4.5),
        ('the focus ring on a menu item', colors.secondary,
            Color.alphaBlend(theme.focusColor, colors.surfaceContainer), 3.0),
        // The About page: its link, and the message if it can't be opened
        // (the error colour, as above).
        ('the link on About', colors.primary, background, 4.5),
      ]) {
        test('contrast: $what', () {
          expect(contrast(color, on), greaterThanOrEqualTo(minimum),
              reason: '$color on $on');
        });
      }

      test('Delete keeps its error colour edge, greyed when disabled', () {
        final style = destructiveButtonStyle(colors);
        expect(style.side!.resolve({})!.color, colors.error);
        expect(style.side!.resolve({WidgetState.disabled})!.color,
            colors.onSurface.withValues(alpha: 0.12));
      });
    });
  }

  group('focus ring', () {
    setUp(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional);
    tearDown(() => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic);

    /// Another box that can take the focus.
    late FocusNode other;

    /// A focused box 100 x 40 in a [FocusRing] ([inward] or not), and the
    /// ring's render object.
    Future<RenderFocusRing> pumpRing(WidgetTester tester,
        {required bool inward}) async {
      other = FocusNode();
      addTearDown(other.dispose);
      // (Unmounted first, so the node is free when it is disposed.)
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(MaterialApp(
          theme: appTheme(Brightness.light),
          home: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FocusRing(
                inward: inward,
                shape: const RoundedRectangleBorder(),
                child: const Focus(
                    autofocus: true, child: SizedBox(width: 100, height: 40)),
              ),
              Focus(focusNode: other, child: const SizedBox(height: 10)),
            ],
          )));
      await tester.pump();
      return tester.renderObject<RenderFocusRing>(find.byType(FocusRing));
    }

    testWidgets('outside the edge, around a box without a Material',
        (tester) async {
      final ring = await pumpRing(tester, inward: false);
      expect(ring.ringRect,
          const Rect.fromLTWH(0, 0, 100, 40).inflate(FocusRing.outset));
    });

    testWidgets('inward: on the edge, drawn inside it', (tester) async {
      final ring = await pumpRing(tester, inward: true);
      expect(ring.ringRect, const Rect.fromLTWH(0, 0, 100, 40));
      expect(ring.shape!.side.strokeAlign, BorderSide.strokeAlignInside);
      expect(ring.shape!.side.width, 3);
    });

    testWidgets('with focusNode: only while that node itself has the '
        'focus; none once it follows another node', (tester) async {
      final area = FocusNode();
      final inner = FocusNode();
      final another = FocusNode();
      addTearDown(area.dispose);
      addTearDown(inner.dispose);
      addTearDown(another.dispose);
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      Widget app(FocusNode follows) => MaterialApp(
            theme: appTheme(Brightness.light),
            home: Column(mainAxisSize: MainAxisSize.min, children: [
              FocusRing(
                focusNode: follows,
                inward: true,
                shape: const RoundedRectangleBorder(),
                child: Focus(
                  focusNode: area,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const SizedBox(width: 100, height: 40),
                    Focus(focusNode: inner, child: const SizedBox(height: 10)),
                  ]),
                ),
              ),
            ]));
      Future<RenderFocusRing> pump(FocusNode follows) async {
        await tester.pumpWidget(app(follows));
        await tester.pump();
        return tester.renderObject<RenderFocusRing>(find.byType(FocusRing));
      }

      var ring = await pump(area);
      area.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(ring.ringRect, isNotNull);
      inner.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(ring.ringRect, isNull, reason: 'something inside has it');
      area.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(ring.ringRect, isNotNull);
      ring = await pump(another);
      expect(ring.ringRect, isNull);
    });

    testWidgets('none without the focus', (tester) async {
      final ring = await pumpRing(tester, inward: true);
      other.requestFocus();
      await tester.pump();
      expect(other.hasPrimaryFocus, isTrue);
      await tester.pump();
      expect(ring.ringRect, isNull);
    });
  });

  test('the contrast ratio is worked out as WCAG does', () {
    expect(contrast(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrast(Colors.white, Colors.white), 1);
    expect(contrast(const Color(0xFF767676), Colors.white), closeTo(4.54, 0.01));
  });
}
