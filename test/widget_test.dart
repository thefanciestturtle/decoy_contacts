import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/main.dart';

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
}
