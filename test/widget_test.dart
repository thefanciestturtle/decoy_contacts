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
    await tester.pumpWidget(MyApp());
    await tester.pumpAndSettle();

    expect(find.text('Last names'), findsOneWidget);
    expect(find.text('First names'), findsOneWidget);
    expect(find.text('Phone number template'), findsOneWidget);
    expect(find.text('Email address template'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Create Fake Contacts'),
        findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Delete Fake Contacts'),
        findsOneWidget);
  });

  testWidgets('First launch fills in the default settings',
      (WidgetTester tester) async {
    await tester.pumpWidget(MyApp());
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
    await tester.pumpWidget(MyApp());
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
    await tester.pumpWidget(MyApp());
    await tester.pumpAndSettle();

    expect(find.text('+15555550nnn'), findsOneWidget);
  });
}
