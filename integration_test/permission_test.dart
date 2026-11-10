// What Create and Delete do when Android no longer asks for the contacts
// permission (U5), against the device's real permission system.
//
// These tests need the permission permanently denied: revoked, with
// Android's "user fixed" flag set, as two "Don't allow" taps leave it. Then
// asking returns at once without a system dialog, which a test couldn't
// tap. tool/integration_test.sh sets that up and runs this file after the
// other tests.

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_test.dart'
    show
        dialogButton,
        expectDialog,
        kCreate,
        kActionTimeout,
        kDelete,
        launchApp,
        tapAndCancel,
        tapAndWaitForAnswer;

const String kTitle = 'Contacts access is off';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final status =
        await FlutterContacts.permissions.check(PermissionType.readWrite);
    // Android says "denied" only while it would still ask (show its
    // dialog); "not determined" covers both never asked and won't ask.
    if (status == PermissionStatus.granted ||
        status == PermissionStatus.denied) {
      fail('The contacts permission is $status. These tests need it '
          'permanently denied; tool/integration_test.sh sets that up.');
    }
  });

  testWidgets('Create and Delete offer the settings, and Open settings '
      'opens them', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // the default settings
    addTearDown(prefs.clear);
    await launchApp(tester);

    // Without the permission there is no status line.
    expect(tester.widget<Text>(find.byKey(const Key('Status'))).data, isEmpty);

    // No system dialog comes up (the test would time out waiting for it),
    // only the app's own.
    await tapAndCancel(tester, kCreate, kTitle, body: 'To create fake contacts');

    await tapAndWaitForAnswer(tester, kDelete);
    expectDialog(tester, kTitle);
    expect(find.textContaining('To delete fake contacts'), findsOneWidget);

    // The system settings come to the front: the app is no longer resumed.
    // (Waits without pumping: in the background the app draws no frames.)
    await tester.tap(dialogButton('Open settings'));
    final deadline = DateTime.now().add(kActionTimeout);
    while (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      if (DateTime.now().isAfter(deadline)) {
        fail('The settings did not come to the front.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });
}
