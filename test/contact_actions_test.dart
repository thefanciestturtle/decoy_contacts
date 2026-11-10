// Create and Delete when saving the ledger fails, e.g. with the phone's
// storage full. (The flow tests can't make saving fail.)

import 'package:fake_contacts/app_log.dart';
import 'package:fake_contacts/contact_actions.dart';
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

  test('Create: if saving the ledger fails once, trying again records them',
      () async {
    final result =
        await createFakeContacts(book, FailingLedgerStore(1), kSettings);

    expect(result!.created, 4);
    expect(result.untracked, 0);
    expect((await stored()).length, 4);
    expect(logged.single, contains('LedgerNotSaved'));
  });

  test("Create: if the ledger can't be saved at all, it says they aren't "
      "recorded, and Delete can still remove them meanwhile", () async {
    final store = FailingLedgerStore(2);
    final error = await createFakeContacts(book, store, kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<StoppedPartway>());
    final stopped = error! as StoppedPartway;
    expect(stopped.done, 4);
    expect(stopped.planned, 4);
    expect(stopped.recorded, isFalse);
    expect(stopped.cause, isA<LedgerNotSaved>());
    expect(book.all, hasLength(4));
    expect(logged, [
      contains('recording what was created: LedgerNotSaved'),
    ]);

    final result = await deleteFakeContacts(book, store, kSettings);
    expect(result!.deleted, 4);
    expect(book.all, isEmpty);
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
    expect(logged.single, contains('deleteFakeContacts, recovered'));
    expect(logged.single, contains('LedgerNotSaved'));
  });
}
