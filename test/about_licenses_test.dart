// Flutter's licence page from About (U9), in a file of its own: the
// licences are registered once per run, and another test registering the
// app's own first would hide a failure to register it here.

import 'package:fake_contacts/about_page.dart';
import 'package:fake_contacts/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets("Licenses shows Flutter's licence page, with the app's name, "
      'version and own licence', (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: appTheme(Brightness.light), home: const AboutPage()));
    final licenses = find.byKey(AboutPage.keyLicenses);
    await tester.ensureVisible(licenses);
    await tester.pumpAndSettle();
    await tester.tap(licenses);
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('Fake Contacts'), findsOneWidget);
    expect(find.text(kAppVersion), findsOneWidget);
    await tester.scrollUntilVisible(find.text(kLicensePackage), 200,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text(kLicensePackage));
    await tester.pumpAndSettle();
    expect(find.text('Copyright (c) 2021 Bill Dietrich'), findsOneWidget);
  });
}
