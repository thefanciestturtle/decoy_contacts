import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/home_page.dart';
import 'package:fake_contacts/main.dart';

import 'in_memory_contacts_gateway.dart';

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
}
