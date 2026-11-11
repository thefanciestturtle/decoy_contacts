// The About screen (U9): its text, the link to the source code, the
// licence page, and reading it all by keyboard or D-pad.

import 'dart:async';
import 'dart:io';

import 'package:fake_contacts/about_page.dart';
import 'package:fake_contacts/app_log.dart';
import 'package:fake_contacts/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// [text] with each run of white space as one space.
String oneLine(String text) => text.trim().split(RegExp(r'\s+')).join(' ');

/// The focus rings shown, in global coordinates.
List<Rect> rings(WidgetTester tester) => [
      for (final ring
          in tester.renderObjectList<RenderFocusRing>(find.byType(FocusRing)))
        if (ring.ringRect case final Rect rect)
          MatrixUtils.transformRect(ring.getTransformTo(null), rect),
    ];

/// The links opened, and what opening one gives: true (opened), false
/// (no app could), or an error to throw.
class FakeBrowser {
  final List<Uri> opened = [];
  Object answer = true;

  /// If set, the next opening waits for it.
  Completer<bool>? pending;

  Future<bool> open(Uri url) async {
    opened.add(url);
    final pending = this.pending;
    this.pending = null;
    if (pending != null) return pending.future;
    final answer = this.answer;
    if (answer is bool) return answer;
    throw answer;
  }
}

/// Shows a page with a button that opens About, as the app's menu does
/// (so About has a page to go back to), and opens it.
Future<void> pumpAbout(WidgetTester tester, FakeBrowser browser,
    {Brightness brightness = Brightness.light}) async {
  await tester.pumpWidget(MaterialApp(
    theme: appTheme(brightness),
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AboutPage(openLink: browser.open))),
          child: const Text('Open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  expect(find.byType(AboutPage), findsOneWidget);
}

final Finder text = find.byKey(AboutPage.keyText);
final Finder link = find.byKey(AboutPage.keySourceLink);
final Finder licenses = find.byKey(AboutPage.keyLicenses);
final Finder linkFailed = find.text(kLinkFailedText);

ScrollPosition position(WidgetTester tester) => tester
    .state<ScrollableState>(
        find.descendant(of: text, matching: find.byType(Scrollable)))
    .position;

/// The focus node of the text as a whole.
FocusNode textFocus(WidgetTester tester) =>
    Focus.of(tester.element(find.byType(SingleChildScrollView)));

FocusNode focusOf(WidgetTester tester, Finder finder) =>
    Focus.of(tester.element(find.descendant(
        of: finder, matching: find.byType(Text), matchRoot: true).first));

/// Whether the Back button has the keyboard focus.
bool backFocused() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<BackButton>() !=
    null;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  group('kept in step with the repository', () {
    test('the version is the one in pubspec.yaml', () {
      final match = RegExp(r'^version:\s*([0-9.]+)(\+\d+)?\s*$', multiLine: true)
          .firstMatch(File('pubspec.yaml').readAsStringSync());
      expect(match, isNotNull);
      expect(kAppVersion, match!.group(1));
    });

    test("the privacy policy is README's, word for word", () {
      final readme = File('README.md').readAsStringSync();
      final section = RegExp(r'^## Privacy Policy\s*$(.*?)^## ',
              multiLine: true, dotAll: true)
          .firstMatch(readme);
      expect(section, isNotNull, reason: 'README has a Privacy Policy section');
      expect(oneLine(section!.group(1)!), kPrivacyPolicy);
      expect(kPrivacyPolicy, endsWith('It has no internet access.'));
    });

    test("the licence is LICENSE.md's", () {
      expect(File('LICENSE.md').readAsStringSync().replaceAll('\r\n', '\n').trim(),
          kAppLicense);
    });
  });

  test("the app's licence is added to the licence page, once", () async {
    registerAppLicense();
    registerAppLicense();
    final entries = await LicenseRegistry.licenses
        .where((entry) => entry.packages.contains(kLicensePackage))
        .toList();
    expect(entries, hasLength(1));
    expect(entries.single.packages, [kLicensePackage]);
    expect(entries.single.paragraphs.map((p) => p.text).join('\n\n'),
        kAppLicense);
  });

  testWidgets('shows the name, the version and each section under a heading '
      'that TalkBack can jump to', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpAbout(tester, FakeBrowser());
    expect(find.widgetWithText(AppBar, 'About'), findsOneWidget);
    expect(find.text('Version $kAppVersion'), findsOneWidget);
    // (Android needs the level: without it, no heading.)
    int headingLevel(String text) =>
        tester.getSemantics(find.text(text)).getSemanticsData().headingLevel;
    expect(tester.getSemantics(find.text('Fake Contacts')),
        isSemantics(label: 'Fake Contacts', isHeader: true));
    expect(headingLevel('Fake Contacts'), 1);
    expect(kAboutSections.map((s) => s.$1), [
      'What it does',
      'Create and Delete',
      'What it stores',
      'New phone or backup',
      'Privacy policy',
      'Source code',
    ]);
    for (final (heading, paragraphs) in kAboutSections) {
      expect(tester.getSemantics(find.text(heading)),
          isSemantics(label: heading, isHeader: true));
      expect(headingLevel(heading), 2, reason: heading);
      for (final paragraph in paragraphs) {
        expect(find.text(paragraph), findsOneWidget);
        expect(tester.getSemantics(find.text(paragraph)),
            isSemantics(label: paragraph, isHeader: false));
        expect(headingLevel(paragraph), 0);
      }
    }
    expect(find.text(kPrivacyPolicy), findsOneWidget);
    // The text as a whole takes the keyboard focus, but isn't a stop for
    // TalkBack.
    expect(tester.getSemantics(find.byType(SingleChildScrollView)),
        isNot(isSemantics(isFocusable: true)));
    handle.dispose();
  });

  group('the link to the source code', () {
    testWidgets('is a link, which TalkBack can open, and opens its address',
        (tester) async {
      final handle = tester.ensureSemantics();
      final browser = FakeBrowser();
      await pumpAbout(tester, browser);
      expect(find.text(kSourceLabel), findsOneWidget);
      expect(kSourceUrl.toString(), 'https://$kSourceLabel');
      final node = tester.getSemantics(find.text(kSourceLabel));
      expect(node, isSemantics(label: kSourceLabel, isLink: true,
          hasTapAction: true));
      // Without its address: see _buildSourceLink.
      expect(node.getSemanticsData().linkUrl, isNull);
      // Tall enough to tap.
      expect(tester.getSize(link).height,
          greaterThanOrEqualTo(kMinInteractiveDimension));

      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(browser.opened, [kSourceUrl]);
      expect(linkFailed, findsNothing);
      handle.dispose();
    });

    testWidgets("says so if no app could open it, and not after it could",
        (tester) async {
      final handle = tester.ensureSemantics();
      final browser = FakeBrowser()..answer = false;
      await pumpAbout(tester, browser);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(linkFailed, findsOneWidget);
      // Read out as it appears.
      expect(tester.getSemantics(linkFailed),
          isSemantics(label: kLinkFailedText, isLiveRegion: true));

      browser.answer = true;
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(browser.opened, [kSourceUrl, kSourceUrl]);
      expect(linkFailed, findsNothing);
      handle.dispose();
    });

    testWidgets('the message goes for a frame before the link is opened '
        'again, so a second failure is read out again, however quick',
        (tester) async {
      final browser = FakeBrowser()..answer = false;
      await pumpAbout(tester, browser);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(linkFailed, findsOneWidget);
      // (This one fails at once.)
      await tester.tap(link);
      await tester.pump();
      expect(linkFailed, findsNothing);
      await tester.pumpAndSettle();
      expect(browser.opened, [kSourceUrl, kSourceUrl]);
      expect(linkFailed, findsOneWidget);
    });

    testWidgets('a second tap while it opens does nothing', (tester) async {
      final browser = FakeBrowser();
      await pumpAbout(tester, browser);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      final opening = Completer<bool>();
      browser.pending = opening;
      await tester.tap(link);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(link);
      await tester.pump();
      expect(browser.opened, [kSourceUrl]);
      opening.complete(true);
      await tester.pumpAndSettle();
      expect(linkFailed, findsNothing);
      // Once it has opened, a tap opens it again.
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(browser.opened, [kSourceUrl, kSourceUrl]);
    });

    testWidgets('an error opening it is logged, and said', (tester) async {
      final logged = <String>[];
      final previous = errorLogSink;
      errorLogSink = logged.add;
      addTearDown(() => errorLogSink = previous);
      final browser = FakeBrowser()
        ..answer = PlatformException(code: 'no_activity');
      await pumpAbout(tester, browser);
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(linkFailed, findsOneWidget);
      expect(logged.single, contains('AboutPage, opening the link'));
      expect(logged.single, contains('no_activity'));
    });
  });

  group('by keyboard', () {
    testWidgets('Tab goes to Back, then the text, then the link and '
        'Licenses, each with a ring; the text\'s ring goes as the link gets '
        'the focus', (tester) async {
      await pumpAbout(tester, FakeBrowser());
      await press(tester, LogicalKeyboardKey.tab);
      expect(backFocused(), isTrue);
      final back = find.byType(BackButton);
      final backRing = rings(tester).single;
      expect(backRing.left, greaterThanOrEqualTo(0),
          reason: 'all of the ring on screen');
      // Around the button as drawn, not the app bar's whole leading space.
      expect(backRing.width, lessThan(tester.getSize(back).width + 10));

      await press(tester, LogicalKeyboardKey.tab);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      // Just inside the edge of the text's whole area.
      expect(rings(tester), [tester.getRect(text)]);

      await press(tester, LogicalKeyboardKey.tab);
      expect(focusOf(tester, link).hasPrimaryFocus, isTrue);
      final shown = rings(tester);
      expect(shown, hasLength(1));
      expect(shown.single, tester.getRect(link).inflate(FocusRing.outset));

      await press(tester, LogicalKeyboardKey.tab);
      expect(focusOf(tester, licenses).hasPrimaryFocus, isTrue);
      expect(rings(tester), hasLength(1));
    });

    testWidgets('the arrow keys scroll the text by a line, Page Up and Page '
        'Down by most of a screen, Home and End all the way; Down at the '
        'end goes on to the link, Up at the top back to Back',
        (tester) async {
      await pumpAbout(tester, FakeBrowser());
      textFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      final scroll = position(tester);
      expect(scroll.maxScrollExtent, greaterThan(scroll.viewportDimension),
          reason: 'the text is longer than the screen');

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(scroll.pixels, kArrowScrollStep);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(scroll.pixels, 2 * kArrowScrollStep);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(scroll.pixels, kArrowScrollStep);
      await press(tester, LogicalKeyboardKey.pageDown);
      expect(scroll.pixels,
          kArrowScrollStep + 0.8 * scroll.viewportDimension);
      await press(tester, LogicalKeyboardKey.pageUp);
      expect(scroll.pixels, kArrowScrollStep);
      await press(tester, LogicalKeyboardKey.end);
      expect(scroll.pixels, scroll.maxScrollExtent);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.home);
      expect(scroll.pixels, 0);
      await press(tester, LogicalKeyboardKey.pageDown);
      await press(tester, LogicalKeyboardKey.pageUp);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(scroll.pixels, kArrowScrollStep);
      // Not past the top.
      await press(tester, LogicalKeyboardKey.pageUp);
      expect(scroll.pixels, 0);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(backFocused(), isTrue);
      expect(scroll.pixels, 0);

      textFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      // Not past the end either.
      for (var i = 0; i < 20; i++) {
        await press(tester, LogicalKeyboardKey.pageDown);
      }
      expect(scroll.pixels, scroll.maxScrollExtent);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusOf(tester, link).hasPrimaryFocus, isTrue);
    });

    testWidgets('a key held down goes on from where the last press is '
        'heading', (tester) async {
      await pumpAbout(tester, FakeBrowser());
      textFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      // Faster than the scroll: no frame in between.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(position(tester).pixels, 4 * kArrowScrollStep);
    });

    testWidgets('a key held down stops at the end; only a fresh press '
        'moves on', (tester) async {
      await pumpAbout(tester, FakeBrowser());
      textFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      final scroll = position(tester);
      scroll.jumpTo(scroll.maxScrollExtent - kArrowScrollStep / 2);
      await tester.pump();
      // The first press scrolls to the end; the repeats come before it
      // gets there.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      }
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();
      expect(scroll.pixels, scroll.maxScrollExtent);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      // Still held, now with the end in view.
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusOf(tester, link).hasPrimaryFocus, isTrue);
    });

    testWidgets('a second quick press, before the end is in view, waits too',
        (tester) async {
      await pumpAbout(tester, FakeBrowser());
      textFocus(tester).requestFocus();
      await tester.pumpAndSettle();
      final scroll = position(tester);
      scroll.jumpTo(scroll.maxScrollExtent - kArrowScrollStep / 2);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(scroll.pixels, scroll.maxScrollExtent);
      expect(textFocus(tester).hasPrimaryFocus, isTrue);
    });

    testWidgets("on the link or Licenses, the arrows move the focus as "
        "usual, and Enter opens the link", (tester) async {
      final browser = FakeBrowser();
      await pumpAbout(tester, browser);
      focusOf(tester, link).requestFocus();
      await tester.pumpAndSettle();
      // (Were the text's keys still at work, Down would scroll instead.)
      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusOf(tester, licenses).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusOf(tester, link).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(browser.opened, [kSourceUrl]);
    });

    testWidgets('back from the licence page, the focus is on Licenses '
        'again, and only it has a ring', (tester) async {
      await pumpAbout(tester, FakeBrowser());
      for (var i = 0; i < 4; i++) {
        await press(tester, LogicalKeyboardKey.tab);
      }
      expect(focusOf(tester, licenses).hasPrimaryFocus, isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(LicensePage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focusOf(tester, licenses).hasPrimaryFocus, isTrue);
      // (Around the button as drawn: its Material.)
      expect(rings(tester), [
        tester
            .getRect(find
                .descendant(of: licenses, matching: find.byType(Material))
                .first)
            .inflate(FocusRing.outset)
      ]);
    });

    testWidgets('Back goes back', (tester) async {
      await pumpAbout(tester, FakeBrowser());
      await press(tester, LogicalKeyboardKey.tab);
      expect(backFocused(), isTrue);
      await press(tester, LogicalKeyboardKey.enter);
      expect(find.byType(AboutPage), findsNothing);
      expect(find.text('Open'), findsOneWidget);
    });
  });

  testWidgets('fits a small screen at a large font size, in the dark theme '
      'too: all of it can be scrolled to', (tester) async {
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpAbout(tester, FakeBrowser(), brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(licenses, 200,
          scrollable: find.descendant(of: text, matching: find.byType(Scrollable)));
      expect(licenses.hitTestable(), findsOneWidget);
      expect(link.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The link's address wraps rather than running off the screen.
      expect(tester.getRect(find.text(kSourceLabel)).right,
          lessThanOrEqualTo(320));
    }
  });
}
