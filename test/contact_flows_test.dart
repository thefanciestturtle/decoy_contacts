// Full Create and Delete flows, through the UI, against an in-memory address
// book.

import 'dart:async';
import 'dart:convert';

import 'package:fake_contacts/contacts_gateway.dart';
import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'in_memory_contacts_gateway.dart';

/// 2 last names x 2 first names = these 4 fakes.
const Map<String, Object> kSettings = {
  'sListOfLastNames': 'Zen, Zima',
  'sListOfFirstNames': 'Zoe, Zach',
  'sPhoneNumberTemplate': kDefaultPhoneTemplate,
  'sEmailAddressTemplate': kDefaultEmailTemplate,
};
const List<String> kFakeNames = ['Zoe Zen', 'Zach Zen', 'Zoe Zima', 'Zach Zima'];

const String kCreateButton = 'Create Fake Contacts';
const String kDeleteButton = 'Delete Fake Contacts';

const String kDenied = 'Permission to access contacts was denied.';
const String kOneMerged =
    ' 1 was merged with another contact and was left alone.';
const String kOneChanged =
    " 1 no longer matches what this app created (edited, or the app's"
    " records came from another phone) and was left alone.";
String someChanged(int n) =>
    " $n no longer match what this app created (edited, or the app's records"
    " came from another phone) and were left alone.";
const String kCreateBody = 'They are added to the contacts on this phone.';
const String kDeleteBody = 'Only contacts this app created are deleted.';

/// The entry a fake with this name gets under [kSettings].
LedgerEntry fakeEntry(String first, String last) =>
    entryFor(FakeName(first, last), kDefaultPhoneTemplate, kDefaultEmailTemplate);

void setPrefs({Map<String, Object> ledger = const {}}) {
  SharedPreferences.setMockInitialValues({
    ...kSettings,
    if (ledger.isNotEmpty) kLedgerPrefsKey: jsonEncode(ledger),
  });
}

Future<void> pumpApp(WidgetTester tester, ContactsGateway contacts) async {
  // Tall enough that both buttons are on screen.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Unmount the app while the test still runs: an edit that wasn't saved
  // yet (say, the test failed) is saved on dispose, and must not land in
  // the next test's settings.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(MyApp(contacts: contacts));
  await tester.pumpAndSettle();
}

/// Taps Create, expects the dialog that asks to go ahead, and confirms.
Future<void> tapCreate(WidgetTester tester) =>
    tapAndAnswer(tester, kCreateButton, 'Create');

/// Taps Delete, expects the dialog that asks to go ahead, and confirms.
Future<void> tapDelete(WidgetTester tester) =>
    tapAndAnswer(tester, kDeleteButton, 'Delete');

/// Taps [button], expects a dialog, and taps [answer] in it.
Future<void> tapAndAnswer(
    WidgetTester tester, String button, String answer) async {
  await tapAndOpenDialog(tester, button);
  await tester.tap(dialogButton(answer));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
}

/// Taps [button] and expects the dialog that asks to go ahead.
Future<void> tapAndOpenDialog(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget,
      reason: '"$button" should ask before going ahead');
}

/// Taps [button] and expects a result without a dialog, e.g. when there is
/// nothing to do or the permission is denied.
Future<void> tapExpectingNoDialog(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing,
      reason: '"$button" should not ask here');
}

Finder dialogButton(String label) => find.descendant(
    of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, label));

/// The title and text of the open dialog.
({String title, String body}) dialogText(WidgetTester tester) {
  final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
  return (
    title: (dialog.title! as Text).data!,
    body: (dialog.content! as Text).data!,
  );
}

String snackBarText(WidgetTester tester) {
  final bar = tester.widget<SnackBar>(find.byType(SnackBar));
  return (bar.content as Text).data!;
}

Future<String?> storedLedgerJson() async =>
    (await SharedPreferences.getInstance()).getString(kLedgerPrefsKey);

Future<Ledger> storedLedger() async => Ledger.decode(await storedLedgerJson());

/// The status line's text, or null if it is empty.
String? statusText(WidgetTester tester) {
  final text = tester.widget<Text>(find.byKey(const Key('Status'))).data!;
  return text.isEmpty ? null : text;
}

/// The app goes to the background and comes back.
Future<void> leaveAndReturn(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

bool buttonsEnabled(WidgetTester tester) =>
    tester.widget<ElevatedButton>(find.byType(ElevatedButton)).enabled &&
    tester.widget<FilledButton>(find.byType(FilledButton)).enabled;

/// Answers the permission request only when [permission] is completed.
class _SlowPermission extends InMemoryContactsGateway {
  final Completer<bool> permission = Completer();

  @override
  Future<bool> requestPermission() {
    permissionRequests++;
    return permission.future;
  }
}

/// The first time the address book is read, the answer waits until
/// [firstRead] is completed; later reads answer at once.
class _SlowFirstRead extends InMemoryContactsGateway {
  final Completer<void> firstRead = Completer();
  var _reads = 0;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final found = await super.getAll(ids: ids); // as it was when asked
    if (_reads++ == 0) await firstRead.future;
    return found;
  }
}

/// Reading the address book fails once something has been deleted.
class _FailsAfterDelete extends InMemoryContactsGateway {
  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) {
    if (deleteAllCalls.isNotEmpty) throw Exception('busy syncing');
    return super.getAll(ids: ids);
  }
}

/// The first read of the address book after something was deleted waits
/// until [held] is completed.
class _HoldsReadAfterDelete extends InMemoryContactsGateway {
  final Completer<void> held = Completer();
  var _holding = false;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    if (deleteAllCalls.isEmpty || _holding) return super.getAll(ids: ids);
    _holding = true;
    final found = await super.getAll(ids: ids);
    await held.future;
    return found;
  }
}

/// Can't find the first new contact when looking them up after creating
/// them, so its raw contact can't be recorded.
class _LosesFirstNewContact extends InMemoryContactsGateway {
  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final found = await super.getAll(ids: ids);
    return ids == null ? found : found.where((c) => c.id != ids.first).toList();
  }
}

void main() {
  late InMemoryContactsGateway book;

  setUp(() {
    setPrefs();
    book = InMemoryContactsGateway();
  });

  group('Create', () {
    testWidgets('creates every combination and records each in the ledger',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 4 fake contacts.');
      expect(book.displayNames, unorderedEquals(kFakeNames));
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zen');
      expect(zoe.phones, [fakeEntry('Zoe', 'Zen').phone]);
      expect(zoe.emails, ['Zoe.Zen@example.com']);

      final ledger = await storedLedger();
      expect(ledger.length, 4);
      for (final c in book.all) {
        final entry = ledger.entries[c.rawContactIds.single]!;
        final names = c.displayName.split(' ');
        expect(entry, fakeEntry(names[0], names[1]));
      }
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('a second Create adds no duplicates', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerAfterFirst = await storedLedgerJson();

      await tapExpectingNoDialog(tester, kCreateButton);

      expect(snackBarText(tester), 'Nothing to create. 4 fake contacts already exist.');
      expect(book.all, hasLength(4));
      expect(book.createAllCalls, hasLength(1));
      expect(await storedLedgerJson(), ledgerAfterFirst);
    });

    testWidgets('Create after editing the names adds only the new ones',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      await tester.enterText(find.byKey(const Key('FirstNames')), 'Zoe, Zach, Zelda');
      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 2 fake contacts. 4 already existed.');
      expect(book.displayNames,
          unorderedEquals([...kFakeNames, 'Zelda Zen', 'Zelda Zima']));
      expect((await storedLedger()).length, 6);
    });

    testWidgets('skips a contact identical to a fake even if the ledger is lost',
        (tester) async {
      final e = fakeEntry('Zoe', 'Zen');
      final existing = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 3 fake contacts. 1 already existed.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(1));
      // Not tracked, so Delete will never touch it.
      final ledger = await storedLedger();
      expect(ledger.length, 3);
      expect(ledger.entries.containsKey(book.rawIdsOf(existing).single), isFalse);
    });

    testWidgets('a real contact with a fake\'s name but other details is kept '
        'out of the ledger', (tester) async {
      final real = book.add('Zoe Zen', phones: ['+1 555 0100']);
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 4 fake contacts.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.length, 4);
      expect(ledger.entries.containsKey(book.rawIdsOf(real).single), isFalse);
    });

    testWidgets('a fake merged into an existing contact is recorded, but only '
        'its own raw contact', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      book.mergeInto = (c) => c.first == 'Zoe' && c.last == 'Zen' ? alice : null;
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 4 fake contacts.');
      final raws = book.rawIdsOf(alice);
      expect(raws, hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.length, 4);
      expect(ledger.entries.containsKey(raws[0]), isFalse); // Alice's own
      expect(ledger.entries[raws[1]], fakeEntry('Zoe', 'Zen'));
    });

    testWidgets('warns about created contacts it could not record',
        (tester) async {
      final lossy = _LosesFirstNewContact();
      await pumpApp(tester, lossy);
      await tapCreate(tester);

      expect(snackBarText(tester),
          'Created 4 fake contacts. Warning: 1 could not be recorded and '
          'must be deleted by hand.');
      expect(lossy.all, hasLength(4));
      expect((await storedLedger()).length, 3);
    });

    testWidgets('permission denied: nothing is read or created', (tester) async {
      book.permissionGranted = false;
      await pumpApp(tester, book);
      await tapExpectingNoDialog(tester, kCreateButton);

      expect(snackBarText(tester), kDenied);
      expect(book.permissionRequests, 1);
      expect(book.getAllCalls, 0);
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while creating is shown and nothing is recorded',
        (tester) async {
      book.createAllError = Exception('disk full');
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(snackBarText(tester),
          'Error while creating contacts: Exception: disk full');
      expect(book.all, isEmpty);
      expect(await storedLedgerJson(), isNull);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while reading the address book is shown',
        (tester) async {
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);
      await tapExpectingNoDialog(tester, kCreateButton);

      // It happened before anything was created, and the message says so.
      expect(snackBarText(tester),
          'Error while reading contacts: Exception: no provider');
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
    });

    testWidgets('taps while busy are ignored', (tester) async {
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      expect(buttonsEnabled(tester), isFalse);
      await tester.tap(find.text(kCreateButton), warnIfMissed: false);
      await tester.tap(find.text(kDeleteButton), warnIfMissed: false);
      await tester.pump();

      slow.permission.complete(true);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(slow.permissionRequests, 1);
      expect(slow.createAllCalls, hasLength(1));
      expect(slow.deleteAllCalls, isEmpty);
      expect(snackBarText(tester), 'Created 4 fake contacts.');
    });
  });

  group('Delete', () {
    testWidgets('removes the fakes and leaves real contacts alone',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      book.add('Zoe Zen', phones: ['+1 555 0100'], emails: ['zoe@real.test']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      expect(book.all, hasLength(6));

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 4 fake contacts.');
      expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
      expect(book.all.firstWhere((c) => c.displayName == 'Zoe Zen').phones,
          ['+1 555 0100']);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    testWidgets('a second Delete finds nothing to delete', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapDelete(tester);
      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(snackBarText(tester), 'No fake contacts to delete.');
      expect(book.all, isEmpty);
    });

    testWidgets('leaves a fake that was merged with a real contact',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zach = book.idOf('Zach Zen');
      final zachRaw = book.rawIdsOf(zach).single;
      book.merge(into: alice, from: zach);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(book.displayNames, ['Alice Example']);
      expect(book.rawIdsOf(alice), hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.entries.keys, [zachRaw]);
    });

    testWidgets('leaves a fake that Android merged into a real contact '
        'when it was created', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      book.mergeInto = (c) => c.first == 'Zoe' && c.last == 'Zen' ? alice : null;
      await pumpApp(tester, book);
      await tapCreate(tester);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(book.displayNames, ['Alice Example']);
      expect(book.rawIdsOf(alice), hasLength(2));
    });

    testWidgets('leaves a fake that was edited since', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zoe = book.idOf('Zoe Zen');
      book.setPhones(zoe, ['+1 555 0199']);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(book.displayNames, ['Zoe Zen']);
      expect((await storedLedger()).entries.keys, book.rawIdsOf(zoe));
    });

    testWidgets('forgets fakes the user already deleted by hand',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.');
      expect(book.all, isEmpty);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    group('ledger that no longer matches (S1)', () {
      testWidgets('a ledger from another phone deletes nothing',
          (tester) async {
        // The ledger's raw IDs belong to real contacts on this phone.
        final alice = book.add('Alice Example', phones: ['+1 555 0101']);
        final bob = book.add('Bob Example', emails: ['bob@real.test']);
        final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
        setPrefs(ledger: {
          book.rawIdsOf(alice).single: fakeEntry('Zoe', 'Zen').toJson(),
          book.rawIdsOf(bob).single: fakeEntry('Zach', 'Zen').toJson(),
          book.rawIdsOf(zoe).single: fakeEntry('Zoe', 'Zen').toJson(),
        });
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(snackBarText(tester), 'No fake contacts to delete.${someChanged(3)}');
        expect(book.displayNames,
            unorderedEquals(['Alice Example', 'Bob Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, isEmpty);
        expect((await storedLedger()).length, 3);
      });

      testWidgets('old name-only entries pointing at real contacts delete '
          'nothing', (tester) async {
        final alice = book.add('Alice Example', phones: ['+1 555 0101']);
        final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
        setPrefs(ledger: {
          book.rawIdsOf(alice).single: 'Zoe Zen',
          book.rawIdsOf(zoe).single: 'Zoe Zen',
        });
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(snackBarText(tester), 'No fake contacts to delete.${someChanged(2)}');
        expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, isEmpty);
        // Saved with the details they were checked against, even though
        // nothing was deleted.
        expect((await storedLedger()).entries.values,
            everyElement(fakeEntry('Zoe', 'Zen')));
      });

      testWidgets('once checked, name-only entries stay checked against the '
          'same details', (tester) async {
        final zoe = book.add('Zoe Zen',
            phones: ['+15550100'], emails: ['zoe@real.test']);
        setPrefs(ledger: {book.rawIdsOf(zoe).single: 'Zoe Zen'});
        await pumpApp(tester, book);
        await tapExpectingNoDialog(tester, kDeleteButton);
        expect(snackBarText(tester), 'No fake contacts to delete.$kOneChanged');

        // Templates that happen to give exactly the real contact's details.
        await tester.enterText(
            find.byKey(const Key('PhoneNumberTemplate')), '+15550100');
        await tester.enterText(
            find.byKey(const Key('EmailAddressTemplate')), 'zoe@real.test');
        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(snackBarText(tester), 'No fake contacts to delete.$kOneChanged');
        expect(book.all.map((c) => c.id), [zoe]);
        expect(book.deleteAllCalls, isEmpty);
      });

      testWidgets('old name-only entries for real fakes are still deleted',
          (tester) async {
        // Fakes made by an older version, which recorded only the name.
        final ledger = <String, Object>{};
        for (final (first, last) in [('Zoe', 'Zen'), ('Zach', 'Zima')]) {
          final e = fakeEntry(first, last);
          final id = book.add(e.name, phones: [e.phone!], emails: [e.email!]);
          ledger[book.rawIdsOf(id).single] = e.name;
        }
        final alice = book.add('Alice Example');
        setPrefs(ledger: ledger);
        await pumpApp(tester, book);

        await tapDelete(tester);

        expect(snackBarText(tester), 'Deleted 2 fake contacts.');
        expect(book.all.map((c) => c.id), [alice]);
      });

      testWidgets('entries for raw IDs that no longer exist are dropped',
          (tester) async {
        final alice = book.add('Alice Example');
        final gone = book.unusedRawId();
        setPrefs(ledger: {gone: fakeEntry('Zoe', 'Zen').toJson()});
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(snackBarText(tester), 'No fake contacts to delete.');
        expect(book.all.map((c) => c.id), [alice]);
        // Only a Create or Delete that runs drops it; asking doesn't.
        expect((await storedLedger()).entries.keys, [gone]);
        await tapAndAnswer(tester, kCreateButton, 'Cancel');
        expect((await storedLedger()).entries.keys, [gone]);
        await tapCreate(tester);
        expect((await storedLedger()).entries.keys, isNot(contains(gone)));
      });
    });

    testWidgets('permission denied: nothing is read or deleted',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.permissionGranted = false;
      final readsBefore = book.getAllCalls;

      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(snackBarText(tester), kDenied);
      expect(book.getAllCalls, readsBefore);
      expect(book.deleteAllCalls, isEmpty);
      expect(book.all, hasLength(4));
      expect(await storedLedgerJson(), ledgerBefore);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while deleting is shown and the ledger is kept',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.deleteAllError = Exception('provider gone');

      await tapDelete(tester);

      expect(snackBarText(tester),
          'Error while deleting contacts: Exception: provider gone');
      expect(book.all, hasLength(4));
      expect(await storedLedgerJson(), ledgerBefore);
      expect(buttonsEnabled(tester), isTrue);

      // Once the error is gone, Delete still works.
      book.deleteAllError = null;
      await tapDelete(tester);
      expect(snackBarText(tester), 'Deleted 4 fake contacts.');
      expect(book.all, isEmpty);
    });
  });

  group('asks before acting (U1)', () {
    /// Checks that nothing at all happened.
    Future<void> expectUntouched(WidgetTester tester,
        {required int contacts, String? ledgerJson}) async {
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(book.all, hasLength(contacts));
      expect(await storedLedgerJson(), ledgerJson);
      expect(buttonsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    testWidgets('Create says how many it will add; Cancel adds none',
        (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);

      expect(dialogText(tester),
          (title: 'Create 4 fake contacts?', body: kCreateBody));
      // Nothing is created before the answer, and there's no spinner.
      expect(book.createAllCalls, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(buttonsEnabled(tester), isFalse);

      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 0);
      expect(book.createAllCalls, isEmpty);
    });

    testWidgets('tapping outside the dialog cancels', (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 0);
    });

    testWidgets('Back cancels', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledger = await storedLedgerJson();
      await tapAndOpenDialog(tester, kDeleteButton);
      // The result of Create doesn't linger under the dialog.
      expect(find.byType(SnackBar), findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 4, ledgerJson: ledger);
      expect(book.deleteAllCalls, isEmpty);
      // Still works afterwards.
      await tapDelete(tester);
      expect(snackBarText(tester), 'Deleted 4 fake contacts.');
    });

    testWidgets('Create counts only the new ones', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tester.enterText(find.byKey(const Key('FirstNames')), 'Zoe, Zach, Zelda');

      await tapAndOpenDialog(tester, kCreateButton);

      expect(dialogText(tester), (
        title: 'Create 2 fake contacts?',
        body: '4 already exist and will be skipped. $kCreateBody',
      ));
    });

    testWidgets('Create with an empty name list says so instead of asking',
        (tester) async {
      await pumpApp(tester, book);
      await tester.enterText(find.byKey(const Key('LastNames')), ' , ');

      await tapExpectingNoDialog(tester, kCreateButton);

      expect(snackBarText(tester),
          'Nothing to create. Enter at least one last name and one first name.');
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
    });

    testWidgets('Delete says how many it will delete; Cancel deletes none',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledger = await storedLedgerJson();

      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester),
          (title: 'Delete 4 fake contacts?', body: kDeleteBody));
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 5, ledgerJson: ledger);
      expect(book.deleteAllCalls, isEmpty);
    });

    testWidgets('Delete says which ones it will leave alone', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zach Zen'));
      book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);

      await tapAndOpenDialog(tester, kDeleteButton);

      expect(dialogText(tester), (
        title: 'Delete 2 fake contacts?',
        body: '$kDeleteBody 1 was merged with another contact and will be '
            "left alone. 1 no longer matches what this app created (edited, "
            "or the app's records came from another phone) and will be left "
            'alone.',
      ));
    });

    testWidgets('a fake edited while the dialog is open is not deleted',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 4 fake contacts?');

      final zoe = book.idOf('Zoe Zen');
      book.setPhones(zoe, ['+1 555 0199']);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(book.displayNames, ['Zoe Zen']);
      expect(book.all.single.phones, ['+1 555 0199']);
    });

    testWidgets('Create while the dialog is open checks again for duplicates',
        (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');

      // Meanwhile one of them appears, e.g. from a sync.
      final e = fakeEntry('Zoe', 'Zen');
      book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(snackBarText(tester), 'Created 3 fake contacts. 1 already existed.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(1));
    });

    testWidgets('Create does no more than the dialog said', (tester) async {
      // Identical to a fake, so Create asks about only 3.
      final e = fakeEntry('Zoe', 'Zen');
      final copy = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 3 fake contacts?');

      // Meanwhile it goes away, so there would now be 4 to create.
      await book.deleteAll([copy]);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(snackBarText(tester),
          'Your contacts changed meanwhile, so nothing was done. Try again.');
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
      expect(buttonsEnabled(tester), isTrue);
      // Asking again gives the new count.
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');
    });

    testWidgets('Delete does no more than the dialog said', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zoe = book.idOf('Zoe Zen');
      final phone = book.all.firstWhere((c) => c.id == zoe).phones;
      book.setPhones(zoe, ['+1 555 0199']);
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 3 fake contacts?');

      // Meanwhile the edit is undone, so all 4 would now be deleted.
      book.setPhones(zoe, phone);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(snackBarText(tester),
          'Your contacts changed meanwhile, so nothing was done. Try again.');
      expect(book.deleteAllCalls, isEmpty);
      expect(book.all, hasLength(4));
      expect((await storedLedger()).length, 4);
    });

    testWidgets('an error while deleting after confirming is shown',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapAndOpenDialog(tester, kDeleteButton);
      book.getAllError = Exception('provider gone');

      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(snackBarText(tester),
          'Error while deleting contacts: Exception: provider gone');
      expect(book.deleteAllCalls, isEmpty);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('Delete with nothing to delete says why instead of asking',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      for (final name in ['Zach Zen', 'Zoe Zima', 'Zach Zima']) {
        await book.deleteAll([book.idOf(name)]);
      }
      book.merge(into: alice, from: book.idOf('Zoe Zen'));

      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(snackBarText(tester), 'No fake contacts to delete.$kOneMerged');
      expect(book.deleteAllCalls, hasLength(3)); // only the ones above
    });
  });

  group('status line (U3)', () {
    /// Adds fakes made by this app (as [fakeEntry] gives them) and returns
    /// a ledger that records them.
    Map<String, Object> addFakes(List<(String, String)> names) => {
          for (final (first, last) in names)
            book.rawIdsOf(book.add('$first $last',
                    phones: [fakeEntry(first, last).phone!],
                    emails: [fakeEntry(first, last).email!])).single:
                fakeEntry(first, last).toJson(),
        };

    testWidgets('shows the count at startup without asking for permission',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      setPrefs(ledger: addFakes([('Zoe', 'Zen'), ('Zach', 'Zima')]));
      final ledger = await storedLedgerJson();
      await pumpApp(tester, book);

      expect(statusText(tester), '2 fake contacts on this phone.');
      expect(book.permissionChecks, greaterThan(0));
      expect(book.permissionRequests, 0);
      expect(await storedLedgerJson(), ledger);
    });

    testWidgets('one, and none', (tester) async {
      setPrefs(ledger: addFakes([('Zoe', 'Zen')]));
      await pumpApp(tester, book);
      expect(statusText(tester), '1 fake contact on this phone.');

      await tapDelete(tester);

      expect(statusText(tester), 'No fake contacts on this phone.');
    });

    testWidgets('without the permission there is none, and it is not asked '
        'for', (tester) async {
      book.alreadyGranted = false;
      await pumpApp(tester, book);

      expect(statusText(tester), isNull);
      expect(book.permissionRequests, 0);
      expect(book.getAllCalls, 0);

      // Granted when the user taps Create.
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('follows Create, Cancel and Delete', (tester) async {
      await pumpApp(tester, book);
      expect(statusText(tester), 'No fake contacts on this phone.');

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // One is deleted by hand while the dialog is open; Cancel still
      // updates the count.
      await tapAndOpenDialog(tester, kDeleteButton);
      await book.deleteAll([book.idOf('Zoe Zen')]);
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();
      expect(statusText(tester), '3 fake contacts on this phone.');

      await tapDelete(tester);
      expect(statusText(tester), 'No fake contacts on this phone.');
    });

    testWidgets('the buttons stay put when it appears', (tester) async {
      book.alreadyGranted = false;
      await pumpApp(tester, book);
      final before = tester.getCenter(find.text(kDeleteButton));

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      expect(tester.getCenter(find.text(kDeleteButton)), before);
    });

    testWidgets('counts neither fakes merged into other contacts nor ones '
        'that no longer match', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zach Zen'));
      book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);

      await leaveAndReturn(tester);

      expect(statusText(tester), '2 fake contacts on this phone.');
    });

    testWidgets('a ledger entry landing on part of a real contact is not '
        'counted (S1)', (tester) async {
      // A real contact made of two raw contacts (e.g. two accounts); a
      // ledger from another phone names one of them.
      final bob = book.add('Bob Example', phones: ['+1 555 0102']);
      book.merge(into: bob, from: book.add('Bob Example'));
      setPrefs(ledger: {
        book.rawIdsOf(bob).first: fakeEntry('Zoe', 'Zen').toJson(),
      });
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
    });

    testWidgets('with an empty ledger the address book is not read',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts on this phone.');
      expect(book.getAllCalls, 0);
    });

    testWidgets('a fake merged into a real contact: none to delete, but not '
        '"none on this phone"', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zoe Zen'));

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(statusText(tester), 'No fake contacts this app can delete.');
    });

    testWidgets('a ledger pointing at real contacts counts none (S1)',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
      setPrefs(ledger: {
        book.rawIdsOf(alice).single: fakeEntry('Zoe', 'Zen').toJson(),
        book.rawIdsOf(zoe).single: 'Zoe Zen',
      });
      final ledger = await storedLedgerJson();
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
      // Counting changes nothing, not even old name-only entries.
      expect(await storedLedgerJson(), ledger);
    });

    testWidgets('updates when the app comes back to the foreground',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]); // by hand, in another app

      await leaveAndReturn(tester);

      expect(statusText(tester), '3 fake contacts on this phone.');
    });

    testWidgets('only after the app was in the background, not after the '
        'notification shade', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(statusText(tester), '4 fake contacts on this phone.');

      await leaveAndReturn(tester);
      expect(statusText(tester), '3 fake contacts on this phone.');
    });

    testWidgets('a failed update right after an action shows no count',
        (tester) async {
      final failing = _FailsAfterDelete();
      await pumpApp(tester, failing);
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // One is edited, so it stays in the ledger and the count after Delete
      // has to read the address book. Delete works; that read fails.
      failing.setPhones(failing.idOf('Zoe Zen'), ['+1 555 0199']);
      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(failing.displayNames, ['Zoe Zen']);
      expect(statusText(tester), isNull);
    });

    testWidgets('a failed update that overtakes the one after an action '
        'shows no count either', (tester) async {
      final holding = _HoldsReadAfterDelete();
      await pumpApp(tester, holding);
      await tapCreate(tester);
      holding.setPhones(holding.idOf('Zoe Zen'), ['+1 555 0199']);
      await tapDelete(tester); // its count afterwards is now waiting
      expect(snackBarText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(statusText(tester), '4 fake contacts on this phone.');

      // The user leaves and comes back; that count fails.
      holding.getAllError = Exception('busy syncing');
      await leaveAndReturn(tester);
      expect(statusText(tester), isNull);

      // The count from after Delete arrives last and is out of date.
      holding.held.complete();
      await tester.pumpAndSettle();
      expect(statusText(tester), isNull);
    });

    testWidgets('old name-only entries are not counted, whatever the '
        'templates say', (tester) async {
      // A fake from an older version, which recorded only the name. Its
      // details match the current settings, so Delete would delete it.
      final e = fakeEntry('Zoe', 'Zen');
      final zoe = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      setPrefs(ledger: {book.rawIdsOf(zoe).single: 'Zoe Zen'});
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 1 fake contact?');
    });

    testWidgets('a failed update keeps the last count', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      book.getAllError = Exception('busy syncing');
      await leaveAndReturn(tester);

      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('disappears if the permission is taken away', (tester) async {
      await pumpApp(tester, book);
      expect(statusText(tester), isNotNull);

      book.alreadyGranted = false; // in the system settings
      await leaveAndReturn(tester);

      expect(statusText(tester), isNull);
    });

    testWidgets('an error while counting shows none, and the app still works',
        (tester) async {
      setPrefs(ledger: addFakes([('Zoe', 'Zen')])); // so it reads
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);
      expect(tester.takeException(), isNull);
      expect(statusText(tester), isNull);

      book.getAllError = null;
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('a count that was still running when Create started is not '
        'shown', (tester) async {
      final slow = _SlowFirstRead();
      book = slow;
      setPrefs(ledger: addFakes([('Zoe', 'Zen')])); // so it reads
      await pumpApp(tester, slow); // the startup count is waiting
      expect(statusText(tester), isNull);

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // The startup count answers last, from before Create.
      slow.firstRead.complete();
      await tester.pumpAndSettle();
      expect(statusText(tester), '4 fake contacts on this phone.');
    });
  });
  group('preview under the fields (U2)', () {
    String? previewText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('Preview'))).data;

    testWidgets('its count is what Create asks about, and its example is a '
        'contact Create makes', (tester) async {
      await pumpApp(tester, book);
      expect(previewText(tester),
          '2 last names × 2 first names = 4 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');

      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zen');
      expect(zoe.phones, ['+447700900010']);
      expect(zoe.emails, ['Zoe.Zen@example.com']);
    });

    testWidgets('an edit shows up in the next Create', (tester) async {
      await pumpApp(tester, book);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zhao');
      await tester.enterText(
          find.byKey(const Key('PhoneNumberTemplate')), '+447700900nnn ');
      await tester.enterText(
          find.byKey(const Key('EmailAddressTemplate')), 'LAST@example.org');
      await tester.pump();
      expect(previewText(tester),
          '1 last name × 2 first names = 2 fake contacts.\n'
          'For example: Zoe Zhao · +447700900047 · Zhao@example.org');

      // Straight away, before the edit is saved.
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 2 fake contacts?');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zhao');
      expect(zoe.phones, ['+447700900047']);
      expect(zoe.emails, ['Zhao@example.org']);
    });

    testWidgets('it is about the settings, not about the phone: Create, '
        'Cancel and Delete leave it as it was', (tester) async {
      await pumpApp(tester, book);
      final before = previewText(tester);

      await tapAndAnswer(tester, kCreateButton, 'Cancel');
      expect(previewText(tester), before);
      await tapCreate(tester);
      expect(previewText(tester), before);
      expect(statusText(tester), '4 fake contacts on this phone.');
      await tapDelete(tester);
      expect(previewText(tester), before);
    });

    testWidgets('Create and Delete close the keyboard, and the field '
        'doesn\'t take the focus back after the dialog', (tester) async {
      await pumpApp(tester, book);
      bool fieldFocused() => tester
          .widgetList<EditableText>(find.byType(EditableText))
          .any((e) => e.focusNode.hasFocus);

      for (final (button, answer) in [
        (kCreateButton, 'Cancel'),
        (kCreateButton, 'Create'),
        (kDeleteButton, 'Delete'),
      ]) {
        await tester.tap(find.byKey(const Key('EmailAddressTemplate')));
        await tester.pump();
        expect(fieldFocused(), isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await tapAndOpenDialog(tester, button);
        await tester.tap(dialogButton(answer));
        await tester.pumpAndSettle();
        expect(fieldFocused(), isFalse, reason: '$button, $answer');
        expect(tester.testTextInput.isVisible, isFalse,
            reason: '$button, $answer');
        await tester.pumpAndSettle(const Duration(seconds: 5));
      }
      expect(book.all, isEmpty);
    });

    testWidgets('an error or a refused permission leaves it as it was',
        (tester) async {
      await pumpApp(tester, book);
      final before = previewText(tester);

      book.getAllError = Exception('no provider');
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(snackBarText(tester), startsWith('Error while reading contacts'));
      expect(previewText(tester), before);

      book.getAllError = null;
      book.permissionGranted = false;
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(snackBarText(tester), kDenied);
      expect(previewText(tester), before);
    });
  });
}
