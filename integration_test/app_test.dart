// Create and Delete against the device's real address book (the Android
// contacts provider), through the app's UI.
//
// These tests add and delete contacts, so they need an emulator whose
// address book is empty, with the contacts permission already granted.
// tool/integration_test.sh sets that up and runs them. Each test checks that
// the address book is empty before it starts, and leaves it empty again.

import 'dart:async';
import 'dart:convert';

import 'package:decoy_contacts/about_page.dart'
    show AboutPage, kAppVersion, kLicensePackage;
import 'package:decoy_contacts/contact_actions.dart'
    show kCreateChunkSize, kDeleteChunkSize;
import 'package:decoy_contacts/contacts_gateway.dart' show NewContact;
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/flutter_contacts_gateway.dart';
import 'package:decoy_contacts/main.dart';
import 'package:decoy_contacts/settings_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/focus_helpers.dart';
import '../test/talkback_announcements.dart';

/// 2 last names x 2 first names, so Create makes the four fakes in [kFakes].
const Map<String, String> kSettings = {
  SettingsStore.kLastNamesKey: 'Zen, Zima',
  SettingsStore.kFirstNamesKey: 'Zoe, Zach',
  SettingsStore.kPhoneTemplateKey: '+447700900nnn',
  SettingsStore.kEmailTemplateKey: 'FIRST.LAST@example.com',
};

/// The fakes [kSettings] gives, with their phone number and email address.
/// Written out by hand rather than generated with the app's code.
const Map<String, (String, String)> kFakes = {
  'Zoe Zen': ('+447700900010', 'Zoe.Zen@example.com'),
  'Zach Zen': ('+447700900010', 'Zach.Zen@example.com'),
  'Zoe Zima': ('+447700900059', 'Zoe.Zima@example.com'),
  'Zach Zima': ('+447700900059', 'Zach.Zima@example.com'),
};

typedef RealContact = ({String first, String last, String? phone, String? email});

/// "Real" contacts that every test starts with. None of them is one of the
/// fakes, so Delete must leave all of them alone.
const List<RealContact> kRealContacts = [
  (first: 'Alice', last: 'Example', phone: '+15555550103', email: 'alice@example.org'),
  // Its name starts like a fake's.
  (first: 'Zoe', last: 'Zenith', phone: '+15555550102', email: null),
  (first: 'Bob', last: 'Example', phone: null, email: 'bob@example.org'),
];

/// An account for contacts that aren't stored on the device. It isn't
/// registered with Android, but the contacts provider accepts it. Deleting
/// such a contact only marks its raw contact as deleted (normally a sync
/// adapter removes it later), so one hidden raw contact is left behind;
/// tool/integration_test.sh --wipe-contacts clears it.
const Account kOtherAccount =
    Account(id: '', name: 'Other account', type: 'com.example.contacts');

const String kCreate = 'Create Fake Contacts';
const String kDelete = 'Delete Fake Contacts';

const Duration kActionTimeout = Duration(seconds: 60);

/// The device's address book, but while [stop] is set, Create and Delete
/// do the first [after] contacts and then fail, as the plugin does when a
/// later batch fails (it then doesn't say what it did).
class StopsPartway extends FlutterContactsGateway {
  StopsPartway(this.after);

  final int after;
  bool stop = true;

  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    if (!stop) return super.createAll(contacts);
    await super.createAll(contacts.take(after).toList());
    throw Exception('stopped on purpose');
  }

  @override
  Future<void> deleteAll(List<String> contactIds) async {
    if (!stop) return super.deleteAll(contactIds);
    await super.deleteAll(contactIds.take(after).toList());
    throw Exception('stopped on purpose');
  }
}

/// The device's address book, but the create call numbered [hangOn] (from
/// 0) creates its contacts and then never returns, as if the app had been
/// killed during it.
class HangsAfterCreating extends FlutterContactsGateway {
  HangsAfterCreating(this.hangOn);

  final int hangOn;
  int calls = 0;

  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    final ids = await super.createAll(contacts);
    if (calls++ == hangOn) await Completer<void>().future;
    return ids;
  }
}

/// The device's address book, but each create call waits a moment first,
/// so a test can tap Stop while the first one runs.
class SlowCreate extends FlutterContactsGateway {
  const SlowCreate();

  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return super.createAll(contacts);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    // Without the permission the app would show the system dialog, and the
    // test would wait for a tap that never comes.
    final status =
        await FlutterContacts.permissions.check(PermissionType.readWrite);
    if (status != PermissionStatus.granted) {
      fail('The contacts permission is not granted ($status). Grant it before '
          'running these tests; tool/integration_test.sh does that.');
    }
  });

  testWidgets('Create adds each fake with its phone and email, and a second '
      'Create adds none', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    await expectStatus(tester, 'No fake contacts on this phone.');
    // The preview under the fields shows the first of kFakes.
    expect(tester.widget<Text>(find.byKey(const Key('Preview'))).data,
        '2 last names × 2 first names = 4 fake contacts.\n'
        'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');

    await tapAndCancel(tester, kCreate, 'Create 4 fake contacts?');
    expect(describeAll(await readAddressBook()), describeAll(real));
    expect(await storedLedger(), isEmpty);

    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 4 fake contacts.');
    await expectStatus(tester, '4 fake contacts on this phone.');

    final book = await readAddressBook();
    final fakes = book.values.where((c) => !real.containsKey(c.id)).toList();
    expect(fakes.map((c) => c.displayName), unorderedEquals(kFakes.keys));
    for (final fake in fakes) {
      final (phone, email) = kFakes[fake.displayName]!;
      expect(phonesOf(fake), [phone], reason: fake.displayName);
      expect(emailsOf(fake), [email], reason: fake.displayName);
      expect(rawIdsOf(fake), hasLength(1), reason: fake.displayName);
    }
    expectUnchanged(book, real);

    // The ledger records each fake's raw contact with its details.
    expect(await storedLedger(), {
      for (final fake in fakes)
        rawIdsOf(fake).single: {
          'name': fake.displayName,
          'phone': kFakes[fake.displayName]!.$1,
          'email': kFakes[fake.displayName]!.$2,
        },
    });
    final ledgerAfterFirst = await storedLedger();

    expect(await tapAndWaitForResult(tester, kCreate),
        'Nothing to create. 4 fake contacts already exist.');
    expect(describeAll(await readAddressBook()), describeAll(book));
    expect(await storedLedger(), ledgerAfterFirst);

    // U4: these settings give no warnings, and without last names Create
    // is disabled (the preview says why).
    for (final key in ['PhoneNumberTemplate', 'EmailAddressTemplate']) {
      expect(tester.widget<TextField>(find.byKey(Key(key))).decoration!.helper,
          isNull, reason: key);
    }
    await tester.enterText(find.byKey(const Key('LastNames')), '');
    await tester.pumpAndSettle();
    expect(createButtonEnabled(tester), isFalse);
    expect(tester.widget<Text>(find.byKey(const Key('Preview'))).data,
        endsWith('\nEnter at least one last name.'));
    await tester.enterText(find.byKey(const Key('LastNames')), 'Zen, Zima');
    await tester.pumpAndSettle();
    expect(createButtonEnabled(tester), isTrue);
  });

  testWidgets('Delete removes the fakes, and every real contact survives',
      (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 4 fake contacts.');
    final withFakes = await readAddressBook();
    expect(withFakes, hasLength(real.length + kFakes.length));
    final ledgerWithFakes = await storedLedger();

    await expectStatus(tester, '4 fake contacts on this phone.');
    await tapAndCancel(tester, kDelete, 'Delete 4 fake contacts?');
    await expectStatus(tester, '4 fake contacts on this phone.');
    expect(describeAll(await readAddressBook()), describeAll(withFakes));
    expect(await storedLedger(), ledgerWithFakes);

    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 4 fake contacts.');
    await expectStatus(tester, 'No fake contacts on this phone.');

    final book = await readAddressBook();
    expect(describeAll(book), describeAll(real));
    expect(await storedLedger(), isEmpty);

    expect(await tapAndWaitForResult(tester, kDelete),
        'No fake contacts to delete.');
    expect(describeAll(await readAddressBook()), describeAll(real));
  });

  testWidgets('Delete leaves alone a fake that Android merged into a real '
      'contact', (tester) async {
    await startWithEmptyAddressBook(tester);
    // Same name as a fake but other details, in another account, as if
    // synced from an online account. Android links contacts that have the
    // same name and come from different accounts, so the fake "Zach Zima"
    // (which is stored on the device) ends up inside this contact.
    final synced = await seed(
      [(first: 'Zach', last: 'Zima', phone: '+15555550104', email: null)],
      account: kOtherAccount,
    );
    final zachRawId = rawIdsOf(synced.values.single).single;
    final real = await seed(kRealContacts);
    await launchApp(tester);

    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 4 fake contacts.');
    // Linking can give the contact a new contact ID; its raw contact keeps
    // its ID.
    final merged = contactWithRawId(await readAddressBook(), zachRawId);
    expect(merged.displayName, 'Zach Zima');
    expect(rawIdsOf(merged), hasLength(2),
        reason: 'Android should have linked the fake Zach Zima into the real '
            'one: $merged');
    // The linked fake isn't counted: its details can't be checked.
    await expectStatus(tester, '3 fake contacts on this phone.');

    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 3 fake contacts?'),
        'Deleted 3 fake contacts. 1 was merged with another contact and '
        'was left alone.');
    // The linked fake is still there, so it doesn't say there are none.
    await expectStatus(tester, 'No fake contacts this app can delete.');

    final book = await readAddressBook();
    expect(book, hasLength(real.length + 1));
    expectUnchanged(book, real);
    // The linked contact is still there, fake and all.
    final zach = contactWithRawId(book, zachRawId);
    expect(rawIdsOf(zach), unorderedEquals(rawIdsOf(merged)));
    expect(phonesOf(zach), contains('+15555550104'));
  });

  testWidgets('U6: a Create or Delete that stops partway says how far it '
      'got, and trying again does the rest', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    final gateway = StopsPartway(2);
    await launchApp(tester, contacts: gateway);

    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 2 of 4 fake contacts, then something went wrong. Try again '
        'to create the rest.');
    // The two it created were found and recorded, so they are counted.
    await expectStatus(tester, '2 fake contacts on this phone.');
    var book = await readAddressBook();
    expect(book, hasLength(real.length + 2));
    expectUnchanged(book, real);
    expect((await storedLedger()).keys, unorderedEquals([
      for (final c in book.values)
        if (!real.containsKey(c.id)) ...rawIdsOf(c),
    ]));
    // The two it didn't find stay pending, in case that read was wrong (U8).
    expect(await storedPending(), isNotNull);

    gateway.stop = false;
    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 2 fake contacts?'),
        'Created 2 fake contacts. 2 already existed.');
    await expectStatus(tester, '4 fake contacts on this phone.');

    gateway.stop = true;
    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 2 of 4 fake contacts, then something went wrong. Try again '
        'to delete the rest.');
    await expectStatus(tester, '2 fake contacts on this phone.');
    book = await readAddressBook();
    expect(book, hasLength(real.length + 2));
    expectUnchanged(book, real);
    // The ledger is left as it was; entries for the deleted ones do no harm.
    expect(await storedLedger(), hasLength(4));

    gateway.stop = false;
    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 2 fake contacts?'),
        'Deleted 2 fake contacts.');
    await expectStatus(tester, 'No fake contacts on this phone.');
    expect(describeAll(await readAddressBook()), describeAll(real));
    expect(await storedLedger(), isEmpty);
  });

  testWidgets('U8: Create and Delete in chunks show progress and can be '
      'stopped', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester,
        contacts: const SlowCreate(), createChunkSize: 1, deleteChunkSize: 1);

    // Stop while the first chunk runs: it stops after that one.
    await tapAndConfirm(tester, kCreate, 'Create 4 fake contacts?');
    await pumpUntil(tester, () => progressText(tester) == 'Created 0 of 4',
        'progress');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    expect(await waitForResult(tester, 'Create'),
        'Stopped after creating 1 of 4 fake contacts.');
    await expectStatus(tester, '1 fake contact on this phone.');
    expect(await storedLedger(), hasLength(1));
    expect(await readAddressBook(), hasLength(real.length + 1));

    // The rest, then Delete in chunks.
    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 3 fake contacts?'),
        'Created 3 fake contacts. 1 already existed.');
    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 4 fake contacts.');
    await expectStatus(tester, 'No fake contacts on this phone.');
    expect(describeAll(await readAddressBook()), describeAll(real));
    expect(await storedLedger(), isEmpty);
  });

  testWidgets('U8: after the app is killed during a Create, Delete removes '
      'everything it made', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester,
        contacts: HangsAfterCreating(1), createChunkSize: 2);
    await tapAndConfirm(tester, kCreate, 'Create 4 fake contacts?');
    await pumpUntil(tester, () => progressText(tester) == 'Created 2 of 4',
        'the first chunk');
    // The second chunk is created, but the app never hears back.
    await pumpUntil(
        tester,
        () => false,
        'nothing',
        timeout: const Duration(seconds: 3),
        failOnTimeout: false);
    expect(await readAddressBook(), hasLength(real.length + 4));
    expect(await storedLedger(), hasLength(2));
    expect(await storedPending(), isNotNull);

    // A new start of the app.
    await tester.pumpWidget(const SizedBox.shrink());
    await launchApp(tester);
    await expectStatus(tester, '4 fake contacts on this phone.');
    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 4 fake contacts.');
    expect(describeAll(await readAddressBook()), describeAll(real));
    expect(await storedLedger(), isEmpty);
    expect(await storedPending(), isNull);
  });

  testWidgets('U7: all by keyboard, the focus comes back to the button '
      'after the dialog and the result, which stays under the buttons',
      (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    await expectStatus(tester, 'No fake contacts on this phone.');

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    /// Tabs until the button labelled [label] has the focus.
    Future<void> tabTo(String label) async {
      for (var i = 0; i < 12 && focusedButton() != label; i++) {
        await press(LogicalKeyboardKey.tab);
      }
      expect(focusedButton(), label);
    }

    for (final (button, title, answer, result) in [
      (kCreate, 'Create 4 fake contacts?', 'Create', 'Created 4 fake contacts.'),
      (kDelete, 'Delete 4 fake contacts?', 'Delete', 'Deleted 4 fake contacts.'),
    ]) {
      await tabTo(button);
      await press(LogicalKeyboardKey.enter);
      await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,
          'dialog of "$button"');
      expectDialog(tester, title);
      // The dialog has the focus: Tab reaches its buttons.
      await tabTo(answer);
      await press(LogicalKeyboardKey.enter);
      expect(await waitForResult(tester, button), result);
      await pumpUntil(tester, () => focusedButton() == button,
          'focus back on "$button"');
    }
    // The last result stays (a snack bar used to go after 4 s, or 10 s).
    await tester.pump(const Duration(seconds: 11));
    expect(tester.widget<Text>(resultFinder).data, 'Deleted 4 fake contacts.');
    expect(describeAll(await readAddressBook()), describeAll(real));
  });

  testWidgets('U12: with only the arrow keys and the centre button (the keys '
      'a D-pad sends), the focus goes through the fields to the buttons and '
      'back',
      (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    await expectStatus(tester, 'No fake contacts on this phone.');
    // Into the app (a D-pad's first press focuses something), then up to
    // the menu, which is at the top.
    await pressAll(tester, LogicalKeyboardKey.arrowDown, 1);
    for (var i = 0; i < 8 && focusedPlace(tester) != 'menu'; i++) {
      await pressAll(tester, LogicalKeyboardKey.arrowUp, 1);
    }
    expect(focusedPlace(tester), 'menu');
    expect(await pressAll(tester, LogicalKeyboardKey.arrowDown, 5),
        [...kFieldKeys, kCreate]);
    // The centre button presses Create; in the dialog, Right to its Create
    // button (after Cancel) and the centre button confirm.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty,
        'dialog of "$kCreate"');
    expectDialog(tester, 'Create 4 fake contacts?');
    for (var i = 0; i < 4 && focusedButton() != 'Create'; i++) {
      await pressAll(tester, LogicalKeyboardKey.arrowRight, 1);
    }
    expect(focusedButton(), 'Create');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(await waitForResult(tester, kCreate), 'Created 4 fake contacts.');
    await pumpUntil(
        tester, () => focusedPlace(tester) == kCreate, 'focus back on Create');

    // Back up: each field's caret to the start of its line first.
    expect(await pressAll(tester, LogicalKeyboardKey.arrowUp, 9), [
      for (final key in kFieldKeys.reversed) ...[key, key],
      'menu',
    ]);
    // Nothing was typed on the way.
    expect([
      for (final key in kFieldKeys)
        tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
    ], kSettings.values);
    final book = await readAddressBook();
    expect(
        book.values.where((c) => !real.containsKey(c.id)).map((c) => c.displayName),
        unorderedEquals(kFakes.keys));
    expectUnchanged(book, real);

    await tapAndWaitForResult(tester, kDelete,
        confirm: 'Delete 4 fake contacts?');
    expect(describeAll(await readAddressBook()), describeAll(real));
  });

  testWidgets('U9: Reset to defaults puts the settings back and saves them; '
      'the fakes made before stay recorded, and Delete removes them',
      (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 4 fake contacts.');
    final ledger = await storedLedger();
    await expectStatus(tester, '4 fake contacts on this phone.');

    await tester.tap(find.byKey(const Key('Menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('Reset')));
    await tester.pumpAndSettle();
    expectDialog(tester, 'Reset to defaults?');
    await tester.tap(dialogButton('Reset'));
    // The message itself: until the next frame, Create's result is still
    // on screen.
    await pumpUntil(
        tester,
        () => resultText(tester) == 'Names and templates reset to the defaults.',
        'the reset message');
    await tester.pumpAndSettle();

    // On disk, not only in the plugin's memory.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect({for (final key in kSettings.keys) key: prefs.getString(key)}, {
      SettingsStore.kLastNamesKey: kDefaultLastNames,
      SettingsStore.kFirstNamesKey: kDefaultFirstNames,
      SettingsStore.kPhoneTemplateKey: kDefaultPhoneTemplate,
      SettingsStore.kEmailTemplateKey: kDefaultEmailTemplate,
    });
    expect(await storedLedger(), ledger);
    await expectStatus(tester, '4 fake contacts on this phone.');

    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 4 fake contacts.');
    expect(describeAll(await readAddressBook()), describeAll(real));
  });

  testWidgets('U13: the result of a quick Create and Delete waits for the '
      'dialog to go, so TalkBack reads it out', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed(kRealContacts);
    await launchApp(tester);
    await expectStatus(tester, 'No fake contacts on this phone.');
    final heard = LiveRegionAnnouncements(tester);
    await tester.pump();

    for (final (label, title, result) in [
      (kCreate, 'Create 4 fake contacts?', 'Created 4 fake contacts.'),
      (kDelete, 'Delete 4 fake contacts?', 'Deleted 4 fake contacts.'),
    ]) {
      await tapAndConfirm(tester, label, title);
      // With the real contacts provider, done before the dialog has gone;
      // the result must wait. (Checked often: the dialog closes in 0.15 s.)
      final deadline = DateTime.now().add(kActionTimeout);
      while (find.byType(AlertDialog).evaluate().isNotEmpty) {
        expect(resultFinder, findsNothing, reason: label);
        expect(DateTime.now().isBefore(deadline), isTrue,
            reason: 'dialog of "$label" gone');
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(await waitForResult(tester, label), result);
    }
    expect(heard.texts, ['Created 4 fake contacts.', 'Deleted 4 fake contacts.']);
    expect(heard.missed, isEmpty);
    heard.dispose();
    expect(describeAll(await readAddressBook()), describeAll(real));
  });

  testWidgets("U9: About shows the version, and its licence page lists the "
      "app's own licence among the packages' (the real list, from the "
      "build)", (tester) async {
    await startWithEmptyAddressBook(tester);
    await launchApp(tester);
    await tester.tap(find.byKey(const Key('Menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('About')));
    await tester.pumpAndSettle();
    expect(find.text('Version $kAppVersion'), findsOneWidget);

    final licenses = find.byKey(const Key('Licenses'));
    await tester.scrollUntilVisible(licenses, 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(licenses);
    // The list is read from the build's own notices, in the background.
    await pumpUntil(
        tester,
        () =>
            find.byType(LicensePage).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
        'the list of licences');
    await tester.pumpAndSettle();
    final app = find.text(kLicensePackage);
    await tester.scrollUntilVisible(app, 300,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(app);
    await tester.pumpAndSettle();
    expect(find.text('Copyright (c) 2021 Bill Dietrich'), findsOneWidget);

    // Back to the app's page (how many pages that takes depends on the
    // licence page's layout, which on a wide screen is one page).
    // (About is offstage while the licence pages cover it.)
    final about = find.byType(AboutPage, skipOffstage: false);
    for (var i = 0; i < 4 && about.evaluate().isNotEmpty; i++) {
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
    }
    expect(about, findsNothing);
    expect(find.text('Create Fake Contacts'), findsOneWidget);
  });

  testWidgets('S1: a ledger whose raw IDs point at real contacts deletes '
      'nothing', (tester) async {
    await startWithEmptyAddressBook(tester);
    final (fakePhone, fakeEmail) = kFakes['Zoe Zen']!;
    final real = await seed([
      ...kRealContacts,
      // Two of a fake's name: one with another number, one with exactly
      // the fake's details.
      (first: 'Zoe', last: 'Zen', phone: '+15555550101', email: null),
      (first: 'Zoe', last: 'Zen', phone: fakePhone, email: fakeEmail),
    ]);
    Contact seeded(String name, [String? phone]) =>
        real.values.firstWhere((c) =>
            c.displayName == name &&
            (phone == null || c.phones.any((p) => p.number == phone)));
    String rawIdOf(String name, [String? phone]) =>
        rawIdsOf(seeded(name, phone)).single;
    // As if the ledger came from another phone, where these raw IDs were
    // fakes. The last entry has only a name, as early test builds stored
    // them: it can't be checked, so it is dropped when read, and that Zoe
    // Zen is left alone although it has exactly a fake's details.
    final ledger = {
      rawIdOf('Alice Example'): {
        'name': 'Zoe Zen',
        'phone': '+447700900010',
        'email': 'Zoe.Zen@example.com',
      },
      rawIdOf('Bob Example'): {
        'name': 'Zach Zen',
        'phone': '+447700900010',
        'email': 'Zach.Zen@example.com',
      },
      rawIdOf('Zoe Zen', '+15555550101'): {
        'name': 'Zoe Zen',
        'phone': fakePhone,
        'email': fakeEmail,
      },
      rawIdOf('Zoe Zen', fakePhone): 'Zoe Zen',
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLedgerPrefsKey, jsonEncode(ledger));
    await launchApp(tester);
    // None of them counts: their contacts no longer match the ledger.
    await expectStatus(tester, 'No fake contacts this app can delete.');
    // Counting changed nothing.
    expect(await storedLedger(), ledger);

    // Nothing to delete, so no dialog.
    expect(await tapAndWaitForResult(tester, kDelete),
        "No fake contacts to delete. 3 no longer match what this app created "
        "(edited, or the app's records came from another phone) and were left "
        "alone.");

    expect(describeAll(await readAddressBook()), describeAll(real));
    // Delete itself didn't run, and its preview had nothing to record, so
    // nothing was saved.
    expect(await storedLedger(), ledger);
  });
}

/// Checks the address book is empty, then sets up the app's settings and an
/// empty ledger. Once the test is over, deletes every contact and clears the
/// app's data again.
///
/// Refusing to start on a non-empty address book means the clean-up only
/// ever deletes contacts this test made.
Future<void> startWithEmptyAddressBook(WidgetTester tester) async {
  final existing = await FlutterContacts.getAll();
  expect(existing, isEmpty,
      reason: 'These tests need an empty address book (run them on an '
          'emulator via tool/integration_test.sh --wipe-contacts). Found '
          '${existing.length} contact(s).');

  final prefs = await SharedPreferences.getInstance();
  addTearDown(() async {
    // Unmount the app first, so it can't save anything after the clean-up.
    await tester.pumpWidget(const SizedBox.shrink());
    final left = await FlutterContacts.getAll();
    await FlutterContacts.deleteAll([for (final c in left) c.id!]);
    await prefs.clear();
    expect(await FlutterContacts.getAll(), isEmpty,
        reason: 'clean-up left contacts behind');
  });

  await prefs.clear();
  for (final MapEntry(:key, :value) in kSettings.entries) {
    await prefs.setString(key, value);
  }
}

/// Adds [contacts] to the address book (stored on the device, unless an
/// [account] is given) and returns them as stored, by contact ID.
Future<Map<String, Contact>> seed(List<RealContact> contacts,
    {Account? account}) async {
  final ids = await FlutterContacts.createAll([
    for (final c in contacts)
      Contact(
        name: Name(first: c.first, last: c.last),
        phones: [if (c.phone != null) Phone(number: c.phone!)],
        emails: [if (c.email != null) Email(address: c.email!)],
      ),
  ], account: account);
  final book = await readAddressBook();
  final seeded = {for (final id in ids) id: book[id]!};
  for (final c in seeded.values) {
    expect(rawIdsOf(c), hasLength(1),
        reason: 'each seeded contact should be on its own: $c');
  }
  return seeded;
}

/// Starts the app, with the device's address book unless [contacts] is
/// given.
Future<void> launchApp(WidgetTester tester,
    {FlutterContactsGateway contacts = const FlutterContactsGateway(),
    int createChunkSize = kCreateChunkSize,
    int deleteChunkSize = kDeleteChunkSize}) async {
  await tester.pumpWidget(MyApp(
      contacts: contacts,
      createChunkSize: createChunkSize,
      deleteChunkSize: deleteChunkSize));
  // The buttons are enabled once the settings are loaded.
  await pumpUntil(tester, () => appIdle(tester), 'settings loaded');
}

/// Whether the app is ready for a tap: the settings are loaded and no
/// Create or Delete is running. (Delete, not Create: Create is also disabled
/// while a name list is empty.)
bool appIdle(WidgetTester tester) {
  final button = find.byKey(const Key('Delete'));
  return button.evaluate().isNotEmpty &&
      tester.widget<OutlinedButton>(button).enabled;
}

bool createButtonEnabled(WidgetTester tester) {
  final button = find.byKey(const Key('Create'));
  return button.evaluate().isNotEmpty &&
      tester.widget<FilledButton>(button).enabled;
}

/// The result under the buttons, if any.
final Finder resultFinder = find.byKey(const Key('Result'));

/// The result under the buttons, or null if there is none.
String? resultText(WidgetTester tester) => resultFinder.evaluate().isEmpty
    ? null
    : tester.widget<Text>(resultFinder).data;

/// Taps the button labelled [label] and returns the text of the result
/// under the buttons. The app talks to the real contacts provider, so this
/// waits in real time rather than relying on pumpAndSettle.
///
/// If [confirm] is given, expects the dialog that asks to go ahead, with
/// that title, and confirms it. Otherwise expects the result without a
/// dialog.
Future<String> tapAndWaitForResult(WidgetTester tester, String label,
    {String? confirm}) async {
  await tapAndWaitForAnswer(tester, label);
  if (confirm != null) {
    expectDialog(tester, confirm);
    await tester.tap(dialogButton(label.split(' ').first));
  } else {
    expect(find.byType(AlertDialog), findsNothing,
        reason: '"$label" should not ask here');
  }
  return waitForResult(tester, label);
}

/// Taps the button labelled [label], expects the dialog that asks to go
/// ahead, with the title [title], and confirms it; then returns at once,
/// without waiting for the result (see [waitForResult]).
Future<void> tapAndConfirm(
    WidgetTester tester, String label, String title) async {
  await tapAndWaitForAnswer(tester, label);
  expectDialog(tester, title);
  await tester.tap(dialogButton(label.split(' ').first));
  await tester.pump();
}

/// Waits for the result of [label] under the buttons and returns its text.
/// The app talks to the real contacts provider, so this waits in real time
/// rather than relying on pumpAndSettle. (The result stays until the next
/// Create or Delete starts, which clears it.)
Future<String> waitForResult(WidgetTester tester, String label) async {
  await pumpUntil(tester, () => resultFinder.evaluate().isNotEmpty,
      'result of "$label"');
  final text = tester.widget<Text>(resultFinder).data!;
  await pumpUntil(tester, () => appIdle(tester), 'app idle');
  await tester.pumpAndSettle();
  return text;
}

/// The progress shown under the buttons, or null.
String? progressText(WidgetTester tester) {
  final found = find.byKey(const Key('Progress'));
  return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
}

/// Waits until the status line says [text].
Future<void> expectStatus(WidgetTester tester, String text) async {
  String? status() {
    final found = find.byKey(const Key('Status'));
    return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
  }

  await pumpUntil(tester, () => status() == text, 'status line "$text"');
}

/// Taps the button labelled [label], expects the dialog that asks to go
/// ahead, with the title [title] (and text containing [body], if given),
/// and taps Cancel.
Future<void> tapAndCancel(WidgetTester tester, String label, String title,
    {String? body}) async {
  await tapAndWaitForAnswer(tester, label);
  expectDialog(tester, title);
  if (body != null) {
    expect(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.textContaining(body)),
        findsOneWidget);
  }
  await tester.tap(dialogButton('Cancel'));
  await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty,
      'dialog closed');
  await pumpUntil(tester, () => appIdle(tester), 'app idle');
  await tester.pumpAndSettle();
  expect(resultFinder, findsNothing);
}

/// Taps the button labelled [label] and waits until the app either asks to
/// go ahead or shows a result.
Future<void> tapAndWaitForAnswer(WidgetTester tester, String label) async {
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pump();
  // The earlier result is cleared at once (else it would end the wait
  // below too early).
  expect(resultFinder, findsNothing);
  await pumpUntil(
      tester,
      () =>
          find.byType(AlertDialog).evaluate().isNotEmpty ||
          resultFinder.evaluate().isNotEmpty,
      'answer to "$label"');
  await tester.pumpAndSettle();
}

void expectDialog(WidgetTester tester, String title) {
  expect(find.byType(AlertDialog), findsOneWidget,
      reason: 'expected the dialog "$title"');
  expect(
      find.descendant(of: find.byType(AlertDialog), matching: find.text(title)),
      findsOneWidget);
}

Finder dialogButton(String label) => find.descendant(
    of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, label));

/// Pumps until [condition] holds. After [timeout], fails, or with
/// [failOnTimeout] false just returns.
Future<void> pumpUntil(
    WidgetTester tester, bool Function() condition, String what,
    {Duration timeout = kActionTimeout, bool failOnTimeout = true}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      if (!failOnTimeout) return;
      fail('Timed out after $timeout waiting for: $what');
    }
    // In an integration test this waits in real time.
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Every contact in the address book, by contact ID.
Future<Map<String, Contact>> readAddressBook() async {
  final contacts = await FlutterContacts.getAll(properties: {
    ContactProperty.identifiers,
    ContactProperty.name,
    ContactProperty.phone,
    ContactProperty.email,
  });
  return {for (final c in contacts) c.id!: c};
}

/// The ledger the app stored, decoded from JSON, without the pending
/// record of a Create (see [storedPending]).
Future<Map<String, Object?>> storedLedger() async =>
    {...await _storedJson()}..remove(kPendingCreateKey);

/// The pending record of a Create stored with the ledger, or null.
Future<Object?> storedPending() async => (await _storedJson())[kPendingCreateKey];

Future<Map<String, Object?>> _storedJson() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  final json = prefs.getString(kLedgerPrefsKey);
  return json == null ? {} : (jsonDecode(json) as Map<String, Object?>);
}

List<String> rawIdsOf(Contact c) => [
      for (final r in c.android?.identifiers?.rawContacts ?? const <RawContact>[])
        if (r.rawContactId != null) r.rawContactId!,
    ];

/// The contact that [rawId] is part of.
Contact contactWithRawId(Map<String, Contact> book, String rawId) =>
    book.values.firstWhere((c) => rawIdsOf(c).contains(rawId),
        orElse: () => fail('No contact has raw contact $rawId'));

List<String> phonesOf(Contact c) => [for (final p in c.phones) p.number];

List<String> emailsOf(Contact c) => [for (final e in c.emails) e.address];

/// A contact's name, details and raw contacts, for comparing snapshots.
String describe(Contact c) => [
      c.displayName,
      (phonesOf(c)..sort()).join(','),
      (emailsOf(c)..sort()).join(','),
      (rawIdsOf(c)..sort()).join(','),
    ].join(' | ');

Map<String, String> describeAll(Map<String, Contact> book) =>
    {for (final MapEntry(:key, :value) in book.entries) key: describe(value)};

/// Checks each contact in [before] is still in [book], unchanged.
void expectUnchanged(Map<String, Contact> book, Map<String, Contact> before) {
  for (final MapEntry(key: id, value: contact) in before.entries) {
    expect(book[id], isNotNull, reason: '${contact.displayName} was deleted');
    expect(describe(book[id]!), describe(contact));
  }
}
