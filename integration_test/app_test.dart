// Create and Delete against the device's real address book (the Android
// contacts provider), through the app's UI.
//
// These tests add and delete contacts, so they need an emulator whose
// address book is empty, with the contacts permission already granted.
// tool/integration_test.sh sets that up and runs them. Each test checks that
// the address book is empty before it starts, and leaves it empty again.

import 'dart:convert';

import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/main.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

    await tapAndCancel(tester, kCreate, 'Create 4 fake contacts?');
    expect(describeAll(await readAddressBook()), describeAll(real));
    expect(await storedLedger(), isEmpty);

    expect(
        await tapAndWaitForResult(tester, kCreate,
            confirm: 'Create 4 fake contacts?'),
        'Created 4 fake contacts.');

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

    await tapAndCancel(tester, kDelete, 'Delete 4 fake contacts?');
    expect(describeAll(await readAddressBook()), describeAll(withFakes));
    expect(await storedLedger(), ledgerWithFakes);

    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 4 fake contacts?'),
        'Deleted 4 fake contacts.');

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

    expect(
        await tapAndWaitForResult(tester, kDelete,
            confirm: 'Delete 3 fake contacts?'),
        'Deleted 3 fake contacts. 1 was merged with another contact and '
        'was left alone.');

    final book = await readAddressBook();
    expect(book, hasLength(real.length + 1));
    expectUnchanged(book, real);
    // The linked contact is still there, fake and all.
    final zach = contactWithRawId(book, zachRawId);
    expect(rawIdsOf(zach), unorderedEquals(rawIdsOf(merged)));
    expect(phonesOf(zach), contains('+15555550104'));
  });

  testWidgets('S1: a ledger whose raw IDs point at real contacts deletes '
      'nothing', (tester) async {
    await startWithEmptyAddressBook(tester);
    final real = await seed([
      ...kRealContacts,
      (first: 'Zoe', last: 'Zen', phone: '+15555550101', email: null),
    ]);
    String rawIdOf(String name) =>
        rawIdsOf(real.values.firstWhere((c) => c.displayName == name)).single;
    // As if the ledger came from another phone, where these raw IDs were
    // fakes. One entry is in the old name-only format.
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
      rawIdOf('Zoe Zen'): 'Zoe Zen',
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLedgerPrefsKey, jsonEncode(ledger));
    await launchApp(tester);

    // Nothing to delete, so no dialog.
    expect(await tapAndWaitForResult(tester, kDelete),
        "No fake contacts to delete. 3 no longer match what this app created "
        "(edited, or the app's records came from another phone) and were left "
        "alone.");

    expect(describeAll(await readAddressBook()), describeAll(real));
    // Skipped entries stay in the ledger, and the name-only one is saved
    // with the details it was checked against.
    expect(await storedLedger(), {
      ...ledger,
      rawIdOf('Zoe Zen'): {
        'name': 'Zoe Zen',
        'phone': '+447700900010',
        'email': 'Zoe.Zen@example.com',
      },
    });
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

Future<void> launchApp(WidgetTester tester) async {
  await tester.pumpWidget(const MyApp());
  // The buttons are enabled once the settings are loaded.
  await pumpUntil(tester, () => createButtonEnabled(tester), 'settings loaded');
}

bool createButtonEnabled(WidgetTester tester) {
  final button = find.byType(ElevatedButton);
  return button.evaluate().isNotEmpty &&
      tester.widget<ElevatedButton>(button).enabled;
}

/// Taps the button labelled [label] and returns the text of the snack bar
/// with the result. The app talks to the real contacts provider, so this
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
  await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty,
      'result of "$label"');
  final bar = tester.widget<SnackBar>(find.byType(SnackBar));
  final text = (bar.content as Text).data!;
  // Remove it, so the next action's result can't be mistaken for this one.
  tester
      .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
      .removeCurrentSnackBar();
  await pumpUntil(tester, () => createButtonEnabled(tester), 'app idle');
  await tester.pumpAndSettle();
  return text;
}

/// Taps the button labelled [label], expects the dialog that asks to go
/// ahead, with the title [title], and taps Cancel.
Future<void> tapAndCancel(
    WidgetTester tester, String label, String title) async {
  await tapAndWaitForAnswer(tester, label);
  expectDialog(tester, title);
  await tester.tap(dialogButton('Cancel'));
  await pumpUntil(tester, () => find.byType(AlertDialog).evaluate().isEmpty,
      'dialog closed');
  await pumpUntil(tester, () => createButtonEnabled(tester), 'app idle');
  await tester.pumpAndSettle();
  expect(find.byType(SnackBar), findsNothing);
}

/// Taps the button labelled [label] and waits until the app either asks to
/// go ahead or shows a result.
Future<void> tapAndWaitForAnswer(WidgetTester tester, String label) async {
  // An earlier result still on screen would end the wait below too early.
  expect(find.byType(SnackBar), findsNothing);
  final button = find.text(label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await pumpUntil(
      tester,
      () =>
          find.byType(AlertDialog).evaluate().isNotEmpty ||
          find.byType(SnackBar).evaluate().isNotEmpty,
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

Future<void> pumpUntil(
    WidgetTester tester, bool Function() condition, String what) async {
  final deadline = DateTime.now().add(kActionTimeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $kActionTimeout waiting for: $what');
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

/// The ledger the app stored, decoded from JSON.
Future<Map<String, Object?>> storedLedger() async {
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
