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

  test('the contrast ratio is worked out as WCAG does', () {
    expect(contrast(Colors.black, Colors.white), closeTo(21, 0.01));
    expect(contrast(Colors.white, Colors.white), 1);
    expect(contrast(const Color(0xFF767676), Colors.white), closeTo(4.54, 0.01));
  });
}
