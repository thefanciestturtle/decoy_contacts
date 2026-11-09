import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/home_page.dart';
import 'package:fake_contacts/main.dart';
import 'package:fake_contacts/settings_store.dart';

import 'in_memory_contacts_gateway.dart';

const String kDefaultPreview =
    '27 last names × 28 first names = 756 fake contacts.\n'
    'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com';

/// The preview under the fields, or null if there is none.
String? previewText(WidgetTester tester) {
  final found = find.byKey(const Key('Preview'));
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

/// Loads the settings only when [loaded] is completed.
class _SlowSettingsStore extends SettingsStore {
  final Completer<void> loaded = Completer();

  @override
  Future<Settings> load() async {
    await loaded.future;
    return Settings.defaults;
  }

  @override
  Future<void> save(Settings settings) async {}
}

/// The part of the screen not covered by the app bar or the keyboard.
Rect visibleArea(WidgetTester tester) {
  final view = tester.view;
  return Rect.fromLTRB(
      0,
      tester.getBottomLeft(find.byType(AppBar)).dy,
      view.physicalSize.width / view.devicePixelRatio,
      (view.physicalSize.height - view.viewInsets.bottom) /
          view.devicePixelRatio);
}

/// Where the text of the field with [key] is, caret included.
Rect editableTextOf(WidgetTester tester, Key key) => tester.getRect(
    find.descendant(of: find.byKey(key), matching: find.byType(EditableText)));

/// Whether [inner] is within [outer] from top to bottom.
bool containsVertically(Rect outer, Rect inner) =>
    inner.top >= outer.top - 0.01 && inner.bottom <= outer.bottom + 0.01;

/// Scrolls the field with [key] to the bottom of the screen (where the
/// keyboard will cover it and the preview is furthest away), taps it and
/// opens a keyboard [keyboardHeight] physical pixels high, as Android does:
/// first focus, then the keyboard.
Future<void> editWithKeyboard(
    WidgetTester tester, Key key, double keyboardHeight) async {
  await Scrollable.ensureVisible(tester.element(find.byKey(key)),
      alignment: 1.0);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pump();
  tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Home screen shows the settings fields and action buttons',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Last names'), findsOneWidget);
    expect(find.text('First names'), findsOneWidget);
    expect(find.text('Phone number template'), findsOneWidget);
    expect(find.text('Email address template'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Create Fake Contacts'),
        findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Delete Fake Contacts'),
        findsOneWidget);
    // There is no contacts plugin in widget tests, so the permission can't
    // be checked: no status line, and no error.
    expect(tester.widget<Text>(find.byKey(const Key('Status'))).data, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('First launch fills in the default settings',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('FIRST.LAST@example.com'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sEmailAddressTemplate'), 'FIRST.LAST@example.com');
    expect(prefs.getString('sListOfLastNames'), startsWith('Zen,'));
    expect(prefs.getString('sPhoneNumberTemplate'), kDefaultPhoneTemplate);
  });

  testWidgets('Old +213 default phone template is migrated',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'sListOfLastNames': 'Zen',
      'sListOfFirstNames': 'Zoe',
      'sPhoneNumberTemplate': kLegacyDefaultPhoneTemplate,
      'sEmailAddressTemplate': kDefaultEmailTemplate,
    });
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text(kDefaultPhoneTemplate), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sPhoneNumberTemplate'), kDefaultPhoneTemplate);
  });

  testWidgets('A customised phone template is left alone',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({
      'sListOfLastNames': 'Zen',
      'sListOfFirstNames': 'Zoe',
      'sPhoneNumberTemplate': '+15555550nnn',
      'sEmailAddressTemplate': kDefaultEmailTemplate,
    });
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('+15555550nnn'), findsOneWidget);
  });

  testWidgets('Edits are saved once typing pauses, not on every keystroke',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();

    await tester.enterText(
        find.byKey(const Key('LastNames')), 'Zen, Zima');
    await tester.pump(const Duration(milliseconds: 100));
    expect(prefs.getString('sListOfLastNames'), startsWith('Zen,Zaragoza'));

    await tester.pump(kSaveDelay);
    await tester.pumpAndSettle();
    expect(prefs.getString('sListOfLastNames'), 'Zen, Zima');
  });

  testWidgets('An edit survives a rebuild (settings are not reloaded)',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('FirstNames')), 'Zelda');
    // Rebuild immediately, before the debounced save has run.
    tester.view.physicalSize = const Size(1080, 2000);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pump();
    expect(find.text('Zelda'), findsOneWidget);
    await tester.pumpAndSettle(kSaveDelay);
  });

  testWidgets('Short screens scroll instead of overflowing',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(720, 900);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.scrollUntilVisible(
        find.text('Delete Fake Contacts'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Delete Fake Contacts').hitTestable(), findsOneWidget);
  });

  testWidgets('Delete button text is readable and it greys out when disabled',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    final style = button.style!;
    expect(style.foregroundColor!.resolve({}), Colors.white);
    expect(style.backgroundColor!.resolve({}), Colors.pink);
    expect(style.backgroundColor!.resolve({WidgetState.disabled}),
        isNot(Colors.pink));
  });

  testWidgets('The dialog before Delete fits a small screen at a large font '
      'size', (WidgetTester tester) async {
    // A small phone (320 x 568 dp) with the text at twice the normal size.
    tester.view.physicalSize = const Size(640, 1136);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      'sListOfLastNames': 'Zen, Zima',
      'sListOfFirstNames': 'Zoe, Zach',
      'sPhoneNumberTemplate': kDefaultPhoneTemplate,
      'sEmailAddressTemplate': kDefaultEmailTemplate,
    });
    final book = InMemoryContactsGateway();
    final alice = book.add('Alice Example');
    await tester.pumpWidget(MyApp(contacts: book));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;

    Future<void> tapButton(String label) async {
      await tester.scrollUntilVisible(find.text(label), 100,
          scrollable: scrollable);
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    await tapButton('Create Fake Contacts');
    await tester.tap(find.widgetWithText(TextButton, 'Create'));
    await tester.pumpAndSettle();
    // The longest text the dialog can show: some fakes left alone for both
    // reasons.
    book.merge(into: alice, from: book.idOf('Zach Zen'));
    book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);
    // On a screen this small, the result of Create covers the Delete button.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tapButton('Delete Fake Contacts');
    expect(tester.takeException(), isNull);

    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.textContaining(
        'will be left alone.', findRichText: true)), findsOneWidget);
    // Both buttons can be reached, and the text scrolls to its end.
    for (final label in ['Cancel', 'Delete']) {
      expect(find.widgetWithText(TextButton, label).hitTestable(),
          findsOneWidget);
    }
    final body = find.descendant(
        of: dialog, matching: find.byType(Scrollable));
    await tester.drag(body, const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(TextButton, 'Delete').hitTestable(),
        findsOneWidget);
  });
  group('preview under the fields (U2)', () {
    testWidgets('shows what the settings make, with an example',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();

      expect(previewText(tester), kDefaultPreview);

      // What TalkBack reads: words instead of signs, and the phone number
      // digit by digit.
      final semantics = tester.ensureSemantics();
      final label =
          tester.getSemantics(find.byKey(const Key('Preview'))).attributedLabel;
      expect(label.string,
          '27 last names times 28 first names makes 756 fake contacts.\n'
          'For example: Zoe Zen, +447700900010, Zoe.Zen@example.com');
      final spellOut = label.attributes.single as SpellOutStringAttribute;
      expect(spellOut.range.textInside(label.string), '+447700900010');
      semantics.dispose();
    });

    testWidgets('follows every edit at once, before it is saved',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();

      Future<void> type(String key, String text) async {
        await tester.enterText(find.byKey(Key(key)), text);
        await tester.pump();
      }

      await type('LastNames', 'Zima, Zen');
      expect(previewText(tester),
          '2 last names × 28 first names = 56 fake contacts.\n'
          'For example: Zoe Zima · +447700900059 · Zoe.Zima@example.com');
      await type('FirstNames', 'Zach');
      expect(previewText(tester),
          '2 last names × 1 first name = 2 fake contacts.\n'
          'For example: Zach Zima · +447700900059 · Zach.Zima@example.com');
      await type('PhoneNumberTemplate', '+1 555 01nn');
      await type('EmailAddressTemplate', 'LAST.FIRST@example.org');
      expect(previewText(tester),
          '2 last names × 1 first name = 2 fake contacts.\n'
          'For example: Zach Zima · +1 555 0105 · Zima.Zach@example.org');
      await type('LastNames', 'Zima');
      expect(previewText(tester),
          '1 last name × 1 first name = 1 fake contact:\n'
          'Zach Zima · +1 555 0105 · Zima.Zach@example.org');
      await type('LastNames', ' , ');
      expect(previewText(tester),
          '0 last names × 1 first name = no fake contacts.\n'
          'Enter at least one last name.');
      await type('FirstNames', '');
      expect(previewText(tester),
          '0 last names × 0 first names = no fake contacts.\n'
          'Enter at least one last name and one first name.');
      await type('LastNames', 'Zen');
      expect(previewText(tester),
          '1 last name × 0 first names = no fake contacts.\n'
          'Enter at least one first name.');

      // None of it was saved yet.
      expect(prefs.getString('sListOfLastNames'), startsWith('Zen,Zaragoza'));
      await tester.pumpAndSettle(kSaveDelay);
    });

    testWidgets('moving only the cursor doesn\'t rebuild it',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('LastNames'));
      await tester.tap(field);
      await tester.pump();
      final before = tester.widget<Text>(find.byKey(const Key('Preview')));

      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('Preview'))),
          same(before));

      // A change to the text still shows.
      controller.text = 'Zima';
      await tester.pump();
      expect(previewText(tester), startsWith('1 last name × 28 first names'));
      await tester.pumpAndSettle(kSaveDelay);
    });

    testWidgets('none until the settings are loaded',
        (WidgetTester tester) async {
      final store = _SlowSettingsStore();
      await tester.pumpWidget(MaterialApp(
          home: MyHomePage(
              title: 'Fake Contacts',
              contacts: InMemoryContactsGateway(),
              settingsStore: store)));
      await tester.pump();
      expect(previewText(tester), isNull);

      store.loaded.complete();
      await tester.pumpAndSettle();
      expect(previewText(tester), kDefaultPreview);
    });

    testWidgets('editing never touches the address book or asks for the '
        'permission', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'sListOfLastNames': 'Zen',
        'sListOfFirstNames': 'Zoe',
        'sPhoneNumberTemplate': kDefaultPhoneTemplate,
        'sEmailAddressTemplate': kDefaultEmailTemplate,
        // So the status line has to read the address book once.
        kLedgerPrefsKey: '{"1": "Zoe Zen"}',
      });
      final book = InMemoryContactsGateway()..add('Zoe Zen');
      await tester.pumpWidget(MyApp(contacts: book));
      await tester.pumpAndSettle();
      final reads = book.getAllCalls;
      expect(reads, greaterThan(0));

      for (final text in ['Zen, Zima', '', 'Zen, Zima, Zhao']) {
        await tester.enterText(find.byKey(const Key('LastNames')), text);
        await tester.pump();
      }
      await tester.enterText(
          find.byKey(const Key('PhoneNumberTemplate')), '+447700900nn');
      await tester.pumpAndSettle(kSaveDelay);

      expect(previewText(tester), startsWith('3 last names × 1 first name'));
      expect(book.getAllCalls, reads);
      expect(book.permissionRequests, 0);
      expect(book.createAllCalls, isEmpty);
      expect(book.deleteAllCalls, isEmpty);
    });

    group('stays above the keyboard while a template is edited', () {
      // A phone like the emulator's: 411 x 914 dp, the keyboard 337 dp high.
      void phoneScreen(WidgetTester tester) {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
      }

      // A shorter one (411 x 686 dp): with the keyboard open, the page
      // can scroll the preview out of view.
      void shortPhoneScreen(WidgetTester tester) {
        tester.view.physicalSize = const Size(1080, 1800);
        tester.view.devicePixelRatio = 2.625;
        addTearDown(tester.view.reset);
      }

      for (final key in ['EmailAddressTemplate', 'PhoneNumberTemplate']) {
        testWidgets(key, (WidgetTester tester) async {
          phoneScreen(tester);
          await tester.pumpWidget(const MyApp());
          await tester.pumpAndSettle();

          await editWithKeyboard(tester, Key(key), 885);

          final visible = visibleArea(tester);
          final preview = tester.getRect(find.byKey(const Key('Preview')));
          expect(containsVertically(visible, preview), isTrue,
              reason: 'preview $preview should be within $visible');
          expect(containsVertically(visible, editableTextOf(tester, Key(key))), isTrue);

          // Still when the preview gets longer while typing.
          await tester.enterText(find.byKey(Key(key)),
              'FIRST.LAST.FIRST.LAST.FIRST.LAST.FIRST.LAST@example.com');
          await tester.pumpAndSettle();
          final longer = tester.getRect(find.byKey(const Key('Preview')));
          expect(longer.height, greaterThan(preview.height));
          final visibleNow = visibleArea(tester);
          expect(containsVertically(visibleNow, longer), isTrue,
              reason: 'preview $longer should be within $visibleNow');
        });
      }

      testWidgets('also when it grows by several lines, at a larger font '
          'size', (WidgetTester tester) async {
        phoneScreen(tester);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        const key = Key('EmailAddressTemplate');
        await editWithKeyboard(tester, key, 885);
        final before = tester.getRect(find.byKey(const Key('Preview')));

        await tester.enterText(find.byKey(key),
            '${List.filled(12, 'FIRST.LAST').join('.')}@example.com');
        await tester.pumpAndSettle();
        final after = tester.getRect(find.byKey(const Key('Preview')));
        expect(after.height, greaterThan(before.height + 60));
        final visible = visibleArea(tester);
        expect(containsVertically(visible, after), isTrue,
            reason: 'preview $after should be within $visible');
        expect(containsVertically(visible, editableTextOf(tester, key)), isTrue);
      });

      testWidgets('also when moving to it from another field with the '
          'keyboard open', (WidgetTester tester) async {
        shortPhoneScreen(tester);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        await editWithKeyboard(tester, const Key('FirstNames'), 885);

        // The email field just above the keyboard, the preview under it.
        const key = Key('EmailAddressTemplate');
        await Scrollable.ensureVisible(tester.element(find.byKey(key)),
            alignment: 1.0);
        await tester.pumpAndSettle();
        expect(tester.getRect(find.byKey(const Key('Preview'))).top,
            greaterThan(visibleArea(tester).bottom));
        await tester.tap(find.byKey(key));
        await tester.pumpAndSettle();

        final visible = visibleArea(tester);
        final preview = tester.getRect(find.byKey(const Key('Preview')));
        expect(containsVertically(visible, preview), isTrue,
            reason: 'preview $preview should be within $visible');
      });

      testWidgets('also when code changes the template',
          (WidgetTester tester) async {
        phoneScreen(tester);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        const key = Key('EmailAddressTemplate');
        await editWithKeyboard(tester, key, 885);

        tester.widget<TextField>(find.byKey(key)).controller!.text =
            '${List.filled(12, 'FIRST.LAST').join('.')}@example.com';
        await tester.pumpAndSettle();
        final visible = visibleArea(tester);
        final preview = tester.getRect(find.byKey(const Key('Preview')));
        expect(containsVertically(visible, preview), isTrue,
            reason: 'preview $preview should be within $visible');
        await tester.pumpAndSettle(kSaveDelay);
      });

      testWidgets('closing the keyboard doesn\'t scroll back to the field',
          (WidgetTester tester) async {
        // A small screen at a large font size: the page is much taller than
        // the screen.
        tester.view.physicalSize = const Size(640, 1136);
        tester.view.devicePixelRatio = 2.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        const key = Key('EmailAddressTemplate');
        await editWithKeyboard(tester, key, 570);

        // Scroll down to the buttons, then close the keyboard; the field
        // keeps the focus.
        final scrollable = find.byType(SingleChildScrollView).first;
        await tester.drag(scrollable, const Offset(0, -5000));
        await tester.pumpAndSettle();
        tester.view.resetViewInsets();
        await tester.pumpAndSettle();

        expect(tester.binding.focusManager.primaryFocus?.hasPrimaryFocus,
            isTrue);
        final position = tester
            .state<ScrollableState>(find
                .descendant(of: scrollable, matching: find.byType(Scrollable))
                .first)
            .position;
        expect(position.pixels, position.maxScrollExtent,
            reason: 'still scrolled to the end');
        expect(tester.getRect(find.byKey(key)).bottom,
            lessThan(visibleArea(tester).top));
      });

      testWidgets('but not while the names are edited',
          (WidgetTester tester) async {
        shortPhoneScreen(tester);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();

        for (final key in ['LastNames', 'FirstNames']) {
          await editWithKeyboard(tester, Key(key), 885);
          await tester.enterText(find.byKey(Key(key)), 'Zen, Zima, Zhao');
          await tester.pumpAndSettle();

          final visible = visibleArea(tester);
          expect(containsVertically(visible, editableTextOf(tester, Key(key))), isTrue,
              reason: key);
          // The page only scrolled as far as the field needs.
          expect(tester.getRect(find.byKey(const Key('Preview'))).top,
              greaterThan(visible.bottom), reason: key);

          FocusManager.instance.primaryFocus!.unfocus();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
        }
      });

      testWidgets('on a small screen at a large font size, the field comes '
          'first', (WidgetTester tester) async {
        // 320 x 568 dp with twice the normal text size; the keyboard
        // leaves about 280 dp, less the app bar.
        tester.view.physicalSize = const Size(640, 1136);
        tester.view.devicePixelRatio = 2.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();

        for (final key in ['EmailAddressTemplate', 'PhoneNumberTemplate']) {
          await editWithKeyboard(tester, Key(key), 570);

          final visible = visibleArea(tester);
          final field = editableTextOf(tester, Key(key));
          expect(containsVertically(visible, field), isTrue,
              reason: '$key $field should be within $visible');
          // The preview doesn't fit as well, so as much as fits is shown.
          final preview = tester.getRect(find.byKey(const Key('Preview')));
          expect(preview.top, lessThan(visible.bottom), reason: key);
          expect(tester.takeException(), isNull);

          FocusManager.instance.primaryFocus!.unfocus();
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
        }
      });

      testWidgets('on a small screen, typing after scrolling away brings the '
          'caret back', (WidgetTester tester) async {
        tester.view.physicalSize = const Size(640, 1136);
        tester.view.devicePixelRatio = 2.0;
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(const MyApp());
        await tester.pumpAndSettle();
        const key = Key('EmailAddressTemplate');
        await editWithKeyboard(tester, key, 570);

        // Scroll all the way down, so the field is out of view above.
        await tester.drag(find.byType(SingleChildScrollView).first,
            const Offset(0, -3000));
        await tester.pumpAndSettle();
        expect(editableTextOf(tester, key).bottom,
            lessThan(visibleArea(tester).top));

        await tester.enterText(find.byKey(key), 'FIRST@example.com');
        await tester.pumpAndSettle();
        final visible = visibleArea(tester);
        final field = editableTextOf(tester, key);
        expect(containsVertically(visible, field), isTrue,
            reason: 'field $field should be within $visible');
      });
    });
  });
}
