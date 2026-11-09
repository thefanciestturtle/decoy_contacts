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

const String kDenied = 'Permission to access contacts was denied.';
const String kMergedSuffix =
    ' were merged with other contacts and were left alone.';
const String kChangedSuffix =
    " no longer match what this app created (edited, or the app's records"
    " came from another phone) and were left alone.";

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
  await tester.pumpWidget(MyApp(contacts: contacts));
  await tester.pumpAndSettle();
}

Future<void> tapCreate(WidgetTester tester) async {
  await tester.tap(find.text('Create Fake Contacts'));
  await tester.pumpAndSettle();
}

Future<void> tapDelete(WidgetTester tester) async {
  await tester.tap(find.text('Delete Fake Contacts'));
  await tester.pumpAndSettle();
}

String snackBarText(WidgetTester tester) {
  final bar = tester.widget<SnackBar>(find.byType(SnackBar));
  return (bar.content as Text).data!;
}

Future<String?> storedLedgerJson() async =>
    (await SharedPreferences.getInstance()).getString(kLedgerPrefsKey);

Future<Ledger> storedLedger() async => Ledger.decode(await storedLedgerJson());

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

      expect(snackBarText(tester), 'Created 4 fake contact(s).');
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

      await tapCreate(tester);

      expect(snackBarText(tester), 'Created 0 fake contact(s). 4 already existed.');
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

      expect(snackBarText(tester), 'Created 2 fake contact(s). 4 already existed.');
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

      expect(snackBarText(tester), 'Created 3 fake contact(s). 1 already existed.');
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

      expect(snackBarText(tester), 'Created 4 fake contact(s).');
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

      expect(snackBarText(tester), 'Created 4 fake contact(s).');
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
          'Created 4 fake contact(s). Warning: 1 could not be recorded and '
          'must be deleted by hand.');
      expect(lossy.all, hasLength(4));
      expect((await storedLedger()).length, 3);
    });

    testWidgets('permission denied: nothing is read or created', (tester) async {
      book.permissionGranted = false;
      await pumpApp(tester, book);
      await tapCreate(tester);

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
      await tapCreate(tester);

      expect(snackBarText(tester),
          'Error while creating contacts: Exception: no provider');
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
    });

    testWidgets('taps while busy are ignored', (tester) async {
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      await tester.tap(find.text('Create Fake Contacts'));
      await tester.pump();
      expect(buttonsEnabled(tester), isFalse);
      await tester.tap(find.text('Create Fake Contacts'), warnIfMissed: false);
      await tester.tap(find.text('Delete Fake Contacts'), warnIfMissed: false);
      await tester.pump();

      slow.permission.complete(true);
      await tester.pumpAndSettle();

      expect(slow.permissionRequests, 1);
      expect(slow.createAllCalls, hasLength(1));
      expect(slow.deleteAllCalls, isEmpty);
      expect(snackBarText(tester), 'Created 4 fake contact(s).');
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

      expect(snackBarText(tester), 'Deleted 4 fake contact(s).');
      expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
      expect(book.all.firstWhere((c) => c.displayName == 'Zoe Zen').phones,
          ['+1 555 0100']);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    testWidgets('a second Delete finds nothing to delete', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapDelete(tester);
      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 0 fake contact(s).');
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

      expect(snackBarText(tester), 'Deleted 3 fake contact(s). 1$kMergedSuffix');
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

      expect(snackBarText(tester), 'Deleted 3 fake contact(s). 1$kMergedSuffix');
      expect(book.displayNames, ['Alice Example']);
      expect(book.rawIdsOf(alice), hasLength(2));
    });

    testWidgets('leaves a fake that was edited since', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zoe = book.idOf('Zoe Zen');
      book.setPhones(zoe, ['+1 555 0199']);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contact(s). 1$kChangedSuffix');
      expect(book.displayNames, ['Zoe Zen']);
      expect((await storedLedger()).entries.keys, book.rawIdsOf(zoe));
    });

    testWidgets('forgets fakes the user already deleted by hand',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]);

      await tapDelete(tester);

      expect(snackBarText(tester), 'Deleted 3 fake contact(s).');
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

        await tapDelete(tester);

        expect(snackBarText(tester), 'Deleted 0 fake contact(s). 3$kChangedSuffix');
        expect(book.displayNames,
            unorderedEquals(['Alice Example', 'Bob Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, [isEmpty]);
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

        await tapDelete(tester);

        expect(snackBarText(tester), 'Deleted 0 fake contact(s). 2$kChangedSuffix');
        expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, [isEmpty]);
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

        expect(snackBarText(tester), 'Deleted 2 fake contact(s).');
        expect(book.all.map((c) => c.id), [alice]);
      });

      testWidgets('entries for raw IDs that no longer exist are dropped',
          (tester) async {
        final alice = book.add('Alice Example');
        setPrefs(ledger: {
          book.unusedRawId(): fakeEntry('Zoe', 'Zen').toJson(),
        });
        await pumpApp(tester, book);

        await tapDelete(tester);

        expect(snackBarText(tester), 'Deleted 0 fake contact(s).');
        expect(book.all.map((c) => c.id), [alice]);
        expect((await storedLedger()).isEmpty, isTrue);
      });
    });

    testWidgets('permission denied: nothing is read or deleted',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.permissionGranted = false;
      final readsBefore = book.getAllCalls;

      await tapDelete(tester);

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
      expect(snackBarText(tester), 'Deleted 4 fake contact(s).');
      expect(book.all, isEmpty);
    });
  });
}
