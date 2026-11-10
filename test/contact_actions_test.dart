// Create and Delete when saving the ledger fails, e.g. with the phone's
// storage full. (The flow tests can't make saving fail.)

import 'package:fake_contacts/app_log.dart';
import 'package:fake_contacts/contact_actions.dart';
import 'package:fake_contacts/contacts_gateway.dart';
import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'failing_ledger_store.dart';
import 'in_memory_contacts_gateway.dart';

/// 2 last names x 2 first names = 4 fakes.
const Settings kSettings = Settings(
  lastNamesText: 'Zen, Zima',
  firstNamesText: 'Zoe, Zach',
  phoneTemplateText: kDefaultPhoneTemplate,
  emailTemplateText: kDefaultEmailTemplate,
);

/// Once creating or deleting has failed, the address book reads as empty,
/// as when the contacts provider has gone.
class _EmptyAfterCreateFails extends InMemoryContactsGateway {
  bool _broken = false;

  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    try {
      return await super.createAll(contacts);
    } catch (_) {
      _broken = true;
      rethrow;
    }
  }

  @override
  Future<void> deleteAll(List<String> contactIds) async {
    try {
      return await super.deleteAll(contactIds);
    } catch (_) {
      _broken = true;
      rethrow;
    }
  }

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async =>
      _broken ? [] : await super.getAll(ids: ids);
}

void main() {
  late InMemoryContactsGateway book;
  late List<String> logged;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    book = InMemoryContactsGateway();
    logged = [];
    final previous = errorLogSink;
    errorLogSink = logged.add;
    addTearDown(() => errorLogSink = previous);
  });

  Future<Ledger> stored() => const LedgerStore().load();

  test("Create: if the ledger can't be saved, it says they aren't recorded, "
      "without reading the address book again; Delete can still remove "
      "them meanwhile", () async {
    final store = FailingLedgerStore(1);
    final error = await createFakeContacts(book, store, kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<StoppedPartway>());
    final stopped = error! as StoppedPartway;
    expect(stopped.done, 4);
    expect(stopped.planned, 4);
    expect(stopped.recorded, isFalse);
    expect(stopped.cause, isA<LedgerNotSaved>());
    expect(book.all, hasLength(4));
    // Plan, then look up the new ones; no third read.
    expect(book.getAllCalls, 2);

    final result = await deleteFakeContacts(book, store, kSettings);
    expect(result!.deleted, 4);
    expect(book.all, isEmpty);
  });

  test('Create with nothing to create: a failed save does no harm',
      () async {
    await createFakeContacts(book, const LedgerStore(), kSettings);
    final result =
        await createFakeContacts(book, FailingLedgerStore(1), kSettings);

    expect(result!.created, 0);
    expect(result.alreadyExisted, 4);
    expect(logged.single, contains('saving the ledger: LedgerNotSaved'));
  });

  test('Create: everything created, then the call failed', () async {
    book.createAllError = Exception('provider gone');
    book.createAllStopsAfter = 4;
    final result =
        await createFakeContacts(book, const LedgerStore(), kSettings);

    expect(result!.created, 4);
    expect((await stored()).length, 4);
    expect(logged.single, contains('recovered: Exception: provider gone'));
  });

  test('Create: everything created, then the call failed, and the ledger '
      "can't be saved", () async {
    book.createAllError = Exception('provider gone');
    book.createAllStopsAfter = 4;
    final error = await createFakeContacts(
            book, FailingLedgerStore(1), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    final stopped = error! as StoppedPartway;
    expect((stopped.done, stopped.planned, stopped.recorded), (4, 4, false));
  });

  test("Create: a re-read that lost contacts from before isn't trusted",
      () async {
    // With the provider gone, reads find nothing rather than failing.
    final broken = _EmptyAfterCreateFails()..add('Alice Example');
    broken.createAllError = Exception('provider gone');
    broken.createAllStopsAfter = 2;
    final error = await createFakeContacts(
            broken, const LedgerStore(), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect((error! as StoppedPartway).done, isNull);
    expect(logged.single, contains('are missing'));
  });

  test("Delete: a re-read that lost contacts it didn't delete isn't trusted",
      () async {
    final broken = _EmptyAfterCreateFails()..add('Alice Example');
    await createFakeContacts(broken, const LedgerStore(), kSettings);
    broken.deleteAllError = Exception('provider gone');
    broken.deleteAllStopsAfter = 2;
    final error = await deleteFakeContacts(
            broken, const LedgerStore(), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    final stopped = error! as StoppedPartway;
    expect((stopped.done, stopped.planned), (null, 4));
    expect(logged.single, contains('are missing'));
  });

  test('Create: a partial Create whose ledger can\'t be saved', () async {
    book.createAllError = Exception('database or disk is full');
    book.createAllStopsAfter = 2;
    final error = await createFakeContacts(
            book, FailingLedgerStore(1), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    final stopped = error! as StoppedPartway;
    expect((stopped.done, stopped.planned, stopped.recorded), (2, 4, false));
    expect(storageFull(stopped), isTrue);
  });

  test('Delete: if saving the ledger fails, all were still deleted', () async {
    await createFakeContacts(book, const LedgerStore(), kSettings);

    final result =
        await deleteFakeContacts(book, FailingLedgerStore(1), kSettings);

    expect(result!.deleted, 4);
    expect(result.skippedMerged + result.skippedChanged, 0);
    expect(book.all, isEmpty);
    expect(logged.single, contains('deleteFakeContacts, saving the ledger'));
    expect(logged.single, contains('LedgerNotSaved'));
  });
}
