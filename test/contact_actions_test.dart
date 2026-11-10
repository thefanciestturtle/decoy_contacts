// Create and Delete when saving the ledger fails, e.g. with the phone's
// storage full. (The flow tests can't make saving fail.)

import 'dart:async';

import 'package:fake_contacts/app_log.dart';
import 'package:fake_contacts/contact_actions.dart';
import 'package:fake_contacts/contacts_gateway.dart';
import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/result_messages.dart';
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

/// Lets the first [succeeding] saves through; after that, saves fail and
/// write nothing, as with the storage full once the app has restarted.
class _WritesNothingWhenFull extends LedgerStore {
  _WritesNothingWhenFull({required this.succeeding});

  int succeeding;

  @override
  Future<void> save(Ledger ledger, {required PendingCreate? pending}) async {
    if (succeeding-- <= 0) throw const LedgerNotSaved();
    await super.save(ledger, pending: pending);
  }
}

/// While [empty] is set, the address book reads as empty, as when the
/// contacts provider is missing.
class _ReadsEmpty extends InMemoryContactsGateway {
  bool empty = false;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async =>
      empty ? [] : await super.getAll(ids: ids);
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

  test("Create: if the ledger can't be saved before it starts, it creates "
      'nothing', () async {
    final store = FailingLedgerStore(1);
    final error = await createFakeContacts(book, store, kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<LedgerNotSaved>());
    expect(storageFull(error!), isTrue);
    expect(book.createAllCalls, isEmpty);
  });

  test("Create: if only the save at the end fails, that is logged, without "
      'reading the address book again; Delete can still remove them '
      'meanwhile', () async {
    final store = FailingLedgerStore(1, succeeding: 1);
    final result = await createFakeContacts(book, store, kSettings);

    expect(result!.created, 4);
    expect(logged.single,
        contains('createFakeContacts, saving the ledger: LedgerNotSaved'));
    expect(book.all, hasLength(4));
    // Plan, then look up the new ones; no third read.
    expect(book.getAllCalls, 2);

    final deleted = await deleteFakeContacts(book, store, kSettings);
    expect(deleted!.deleted, 4);
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
    final result = await createFakeContacts(
        book, FailingLedgerStore(1, succeeding: 1), kSettings);

    expect(result!.created, 4);
    expect(logged.last, contains('saving the ledger: LedgerNotSaved'));
  });

  test('Create: a re-read that lost one contact from before is trusted',
      () async {
    // Say, a sync deleted a real contact meanwhile.
    final bob = book.add('Bob Example');
    final bobRaw = book.rawIdsOf(bob).single;
    book.add('Alice Example');
    book.createAllError = Exception('provider gone');
    book.createAllStopsAfter = 2;
    // While creating.
    book.mergeInto = (_) {
      if (book.contactOfRaw(bobRaw) != null) book.deleteAll([bob]);
      return null;
    };
    final error = await createFakeContacts(
            book, const LedgerStore(), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    expect((error! as StoppedPartway).done, 2);
    expect((await stored()).length, 2);
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
            book, FailingLedgerStore(1, succeeding: 1), kSettings)
        .then<Object?>((_) => null, onError: (Object e) => e);

    final stopped = error! as StoppedPartway;
    expect((stopped.done, stopped.planned), (2, 4));
    expect(storageFull(stopped), isTrue);
  });

  test('Delete: everything deleted, then the call failed', () async {
    await createFakeContacts(book, const LedgerStore(), kSettings);
    book.deleteAllError = Exception('provider gone');
    book.deleteAllStopsAfter = 4;

    final result =
        await deleteFakeContacts(book, const LedgerStore(), kSettings);

    expect(result!.deleted, 4);
    expect(book.all, isEmpty);
    expect((await stored()).isEmpty, isTrue);
    expect(logged.single, contains('recovered: Exception: provider gone'));
  });

  test("Delete's preview: a failed save of old entries' details does no "
      'harm', () async {
    // A fake from an older version, which recorded only the name.
    final e = entryFor(const FakeName('Zoe', 'Zen'), kDefaultPhoneTemplate,
        kDefaultEmailTemplate);
    final zoe = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
    await const LedgerStore()
        .save(Ledger({book.rawIdsOf(zoe).single: const LedgerEntry.nameOnly('Zoe Zen')}),
            pending: null);
    final store = FailingLedgerStore(1);

    final preview = await previewDelete(book, store, kSettings);

    expect(preview.toDelete, 1);
    expect(logged.single, contains('previewDelete, saving the ledger'));
    final result = await deleteFakeContacts(book, store, kSettings);
    expect(result!.deleted, 1);
    expect(book.all, isEmpty);
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

  /// Like Android with the storage full after a restart: a failed save
  /// leaves what was saved before.
  test("Create: when a save fails, what is on disk still lets Delete find "
      'every fake', () async {
    // The save at the end fails; so does the one before a third chunk.
    for (final (chunkSize, created) in [(2, 4), (1, 2)]) {
      SharedPreferences.setMockInitialValues({});
      book = InMemoryContactsGateway();
      final store = _WritesNothingWhenFull(succeeding: 2);
      final outcome = await createFakeContacts(book, store, kSettings,
              chunkSize: chunkSize)
          .then<Object?>((r) => r, onError: (Object e) => e);
      if (outcome case StoppedPartway stopped) {
        expect((stopped.done, stopped.planned), (created, 4));
        expect(createFailedMessage(stopped).text,
            'Created 2 of 4 fake contacts before your phone ran out of'
            ' storage.');
      } else {
        expect((outcome! as CreateResult).created, created);
      }
      expect(book.all, hasLength(created));

      // On disk: the chunks before the last one, and that one as a pending
      // record.
      final onDisk = await const LedgerStore().loadWithPending();
      expect(onDisk.ledger.length, created - chunkSize);
      expect(onDisk.pending!.entries, hasLength(chunkSize));
      final preview =
          await previewDelete(book, const LedgerStore(), kSettings);
      expect(preview.toDelete, created);
      final deleted =
          await deleteFakeContacts(book, const LedgerStore(), kSettings);
      expect(deleted!.deleted, created);
      expect(book.all, isEmpty);
    }
  });

  group('in chunks (U8)', () {
    Future<({Ledger ledger, PendingCreate? pending})> storedWithPending() =>
        const LedgerStore().loadWithPending();

    test('Create: one call per chunk, with progress before and after each',
        () async {
      final progress = <(int, int)>[];
      final result = await createFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 3, onProgress: (done, total) => progress.add((done, total)));

      expect(result!.created, 4);
      expect(result.planned, 4);
      expect(result.stopped, isFalse);
      expect([for (final c in book.createAllCalls) c.length], [3, 1]);
      expect(progress, [(0, 4), (3, 4), (4, 4)]);
      final stored = await storedWithPending();
      expect(stored.ledger.length, 4);
      expect(stored.pending, isNull);
    });

    test('Create: no progress when it fits in one chunk', () async {
      final progress = <(int, int)>[];
      await createFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 4, onProgress: (done, total) => progress.add((done, total)));

      expect(book.createAllCalls, hasLength(1));
      expect(progress, isEmpty);
    });

    test('Create: before each call, the ledger holds what was created so far '
        'and the chunk about to be created', () async {
      final seen = <({Ledger ledger, PendingCreate? pending})>[];
      book.beforeCreateAll = (_) async => seen.add(await storedWithPending());
      await createFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 2);

      expect([for (final s in seen) s.ledger.length], [0, 2]);
      expect([for (final s in seen) s.pending!.entries.map((e) => e.name)], [
        ['Zoe Zen', 'Zach Zen'],
        ['Zoe Zima', 'Zach Zima'],
      ]);
      // The highest raw ID before each call: none, then the first chunk's.
      expect(seen[0].pending!.maxRawId, isNull);
      expect(seen[1].pending!.maxRawId,
          maxRawIdOf([for (final c in book.all.take(2)) ...c.rawContactIds]));
    });

    test('Create: Stop stops after the chunk it is on, with the ledger saved',
        () async {
      var bStop = false;
      final result = await createFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 1,
          onProgress: (done, _) => bStop = done == 2,
          stopRequested: () => bStop);

      expect(result!.stopped, isTrue);
      expect((result.created, result.planned), (2, 4));
      expect(book.createAllCalls, hasLength(2));
      final stored = await storedWithPending();
      expect(stored.ledger.length, 2);
      expect(stored.pending, isNull);
    });

    test("Create: Stop isn't asked about before the first chunk",
        () async {
      final result = await createFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 2, stopRequested: () => true);

      expect(result!.stopped, isTrue);
      expect(result.created, 2);
    });

    test('Create: a chunk that stops partway: only that chunk is looked for',
        () async {
      book.beforeCreateAll = (call) async {
        if (call == 1) {
          book.createAllError = Exception('provider gone');
          book.createAllStopsAfter = 1;
        }
      };
      final error = await createFakeContacts(
              book, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (3, 4));
      final stored = await storedWithPending();
      expect(stored.ledger.length, 3);
      // The one not found stays pending, in case the read was wrong.
      expect(stored.pending!.entries.map((e) => e.name), ['Zach Zima']);
      expect(book.all, hasLength(3));
    });

    test('Create: a chunk that was all created before its call failed: it '
        'goes on', () async {
      book.beforeCreateAll = (call) async {
        book.createAllError = call == 0 ? Exception('provider gone') : null;
        book.createAllStopsAfter = call == 0 ? 2 : null;
      };
      final progress = <int>[];
      final result = await createFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 2, onProgress: (done, _) => progress.add(done));

      expect(result!.created, 4);
      expect(progress, [0, 2, 4]);
      expect((await storedWithPending()).ledger.length, 4);
      expect(logged.single, contains('recovered: Exception: provider gone'));
    });

    test("Create: if the ledger can't be saved before a later chunk, it stops "
        'there', () async {
      final store = FailingLedgerStore(1, succeeding: 1);
      final error = await createFakeContacts(book, store, kSettings,
              chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (2, 4));
      expect(storageFull(stopped), isTrue);
      expect(book.createAllCalls, hasLength(1));
    });

    test('Create: killed during a call, the next count, Delete and Create '
        'find what it made', () async {
      final real = book.add('Alice Example', phones: ['+15555550103']);
      // The second call creates its contacts, then the app is gone.
      book.afterCreateAll =
          (call) => call == 1 ? Completer<void>().future : Future.value();
      unawaited(createFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 2));
      await pumpEventQueue();
      expect(book.all, hasLength(5));
      final killed = await storedWithPending();
      expect(killed.ledger.length, 2);
      expect(killed.pending!.entries, hasLength(2));

      // Counting finds all four, but changes nothing.
      final count = await countFakeContacts(book, const LedgerStore());
      expect(count.toDelete, 4);
      expect((await storedWithPending()).pending, isNotNull);

      // So does a second Create: nothing left to create.
      book.afterCreateAll = null;
      final created =
          await createFakeContacts(book, const LedgerStore(), kSettings);
      expect((created!.created, created.alreadyExisted), (0, 4));
      final stored = await storedWithPending();
      expect(stored.ledger.length, 4);
      expect(stored.pending, isNull);

      final deleted =
          await deleteFakeContacts(book, const LedgerStore(), kSettings);
      expect(deleted!.deleted, 4);
      expect(book.all.map((c) => c.id), [real]);
    });

    test("Delete's preview records the fakes of a Create that was killed",
        () async {
      book.afterCreateAll =
          (call) => call == 0 ? Completer<void>().future : Future.value();
      unawaited(createFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 4));
      await pumpEventQueue();
      expect((await storedWithPending()).ledger.isEmpty, isTrue);

      // An empty ledger with a pending record is still counted.
      expect(
          (await countFakeContacts(book, const LedgerStore())).toDelete, 4);
      final preview = await previewDelete(book, const LedgerStore(), kSettings);
      expect(preview.toDelete, 4);
      final stored = await storedWithPending();
      expect(stored.ledger.length, 4);
      expect(stored.pending, isNull);
    });

    test('a pending Create is kept while the address book reads as empty',
        () async {
      final broken = _ReadsEmpty();
      broken.afterCreateAll =
          (call) => call == 0 ? Completer<void>().future : Future.value();
      unawaited(createFakeContacts(broken, const LedgerStore(), kSettings));
      await pumpEventQueue();
      final killed = await storedWithPending();

      // As with the contacts provider missing: nothing is found, and nothing
      // is given up.
      broken.empty = true;
      final none = await previewDelete(broken, const LedgerStore(), kSettings);
      expect(none.toDelete, 0);
      final kept = await storedWithPending();
      expect(kept.pending!.entries, killed.pending!.entries);

      broken.empty = false;
      final preview =
          await previewDelete(broken, const LedgerStore(), kSettings);
      expect(preview.toDelete, 4);
      expect((await storedWithPending()).pending, isNull);
    });

    test('killed during the first call while the address book reads as '
        'empty: the ledger on disk still holds what was recorded', () async {
      final broken = _ReadsEmpty();
      await createFakeContacts(broken, const LedgerStore(), kSettings);
      final before = await storedWithPending();
      expect(before.ledger.length, 4);

      broken.empty = true;
      broken.afterCreateAll =
          (call) => call == 1 ? Completer<void>().future : Future.value();
      unawaited(createFakeContacts(broken, const LedgerStore(), kSettings));
      await pumpEventQueue();
      final killed = await storedWithPending();
      expect(killed.pending, isNotNull);
      expect(killed.ledger.entries, before.ledger.entries);
    });

    test('Delete: one call per chunk, with progress, and Stop keeps the rest '
        'in the ledger', () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      final progress = <(int, int)>[];
      var bStop = false;
      final result = await deleteFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 1,
          onProgress: (done, total) {
            progress.add((done, total));
            bStop = done == 3;
          },
          stopRequested: () => bStop);

      expect(result!.stopped, isTrue);
      expect((result.deleted, result.planned), (3, 4));
      expect(progress, [(0, 4), (1, 4), (2, 4), (3, 4)]);
      expect([for (final c in book.deleteAllCalls) c.length], [1, 1, 1]);
      expect(book.all, hasLength(1));
      final ledger = await const LedgerStore().load();
      expect(ledger.entries.keys, book.all.single.rawContactIds);

      final rest = await deleteFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 1);
      expect((rest!.deleted, rest.stopped), (1, false));
      expect(book.all, isEmpty);
    });

    test('Delete: a chunk that fails says how many it deleted in all',
        () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      book.beforeDeleteAll = (call) async {
        if (call == 1) {
          book.deleteAllError = Exception('provider gone');
          book.deleteAllStopsAfter = 1;
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (3, 4));
      expect(book.all, hasLength(1));
    });

    test("Delete: a chunk that fails is counted on its own: contacts of later "
        "chunks deleted meanwhile don't make up for it", () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      final lastFake = book.all.last.id;
      book.beforeDeleteAll = (call) async {
        if (call == 1) {
          // Meanwhile, say by a sync, a fake of the last chunk goes.
          book.beforeDeleteAll = null;
          await book.deleteAll([lastFake]);
          book.deleteAllError = Exception('provider gone');
          book.deleteAllStopsAfter = 0;
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), kSettings, chunkSize: 1)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (1, 4));
      // The one that wasn't deleted is still recorded.
      final ledger = await const LedgerStore().load();
      for (final c in book.all) {
        expect(ledger.entries.keys, containsAll(c.rawContactIds));
      }
    });

    test("Delete: if what a later chunk did can't be read, it says what the "
        'chunks before deleted', () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      book.beforeDeleteAll = (call) async {
        if (call == 1) {
          book.deleteAllError = Exception('provider gone');
          book.getAllError = Exception('provider gone');
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (2, 4));
    });

    test("Create: if what a later chunk made can't be read, it says what the "
        'chunks before created, and keeps the pending record', () async {
      book.beforeCreateAll = (call) async {
        if (call == 1) {
          book.createAllError = Exception('provider gone');
          book.createAllStopsAfter = 1;
          book.getAllError = Exception('provider gone');
        }
      };
      final error = await createFakeContacts(
              book, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (2, 4));
      final stored = await storedWithPending();
      expect(stored.ledger.length, 2);
      expect(stored.pending!.entries, hasLength(2));

      // The next Create finds the one the cut-short chunk made.
      book.getAllError = null;
      book.createAllError = null;
      book.beforeCreateAll = null;
      final rest =
          await createFakeContacts(book, const LedgerStore(), kSettings);
      expect((rest!.created, rest.alreadyExisted), (1, 3));
      expect((await storedWithPending()).ledger.length, 4);
    });

    test('a pending record that is left for later survives the saves of '
        "Delete, Delete's preview and a Create with nothing to do", () async {
      final broken = _ReadsEmpty();
      // A fake from an older version, which recorded only the name, so the
      // preview saves its details.
      final e = entryFor(const FakeName('Zoe', 'Zen'), kDefaultPhoneTemplate,
          kDefaultEmailTemplate);
      final zoe = broken.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      final pending = PendingCreate(maxRawId: 5, entries: [e]);
      await const LedgerStore().save(
          Ledger({broken.rawIdsOf(zoe).single: const LedgerEntry.nameOnly('Zoe Zen')}),
          pending: pending);
      broken.empty = true;

      await previewDelete(broken, const LedgerStore(), kSettings);
      var stored = await storedWithPending();
      expect(stored.ledger.entries.values.single.hasDetails, isTrue);
      expect(stored.pending!.entries, pending.entries);

      const noNames = Settings(
          lastNamesText: '',
          firstNamesText: '',
          phoneTemplateText: kDefaultPhoneTemplate,
          emailTemplateText: kDefaultEmailTemplate);
      await createFakeContacts(broken, const LedgerStore(), noNames);
      stored = await storedWithPending();
      expect(stored.pending!.entries, pending.entries);

      // And Delete's own save, with nothing to delete.
      await deleteFakeContacts(broken, const LedgerStore(), kSettings);
      stored = await storedWithPending();
      expect(stored.pending!.entries, pending.entries);
    });

    test('Create: the first chunk fails with the storage full and nothing '
        "made: it says so, not that a list couldn't be saved", () async {
      book.createAllError =
          Exception('database or disk is full (code 13 SQLITE_FULL)');
      final error = await createFakeContacts(
              book, FailingLedgerStore(1, succeeding: 1), kSettings,
              chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect(stopped.done, 0);
      expect(createFailedMessage(stopped).text,
          "Couldn't create fake contacts: your phone's storage is full.");
    });

    test("Create: a re-read that lost the fakes of earlier chunks isn't "
        'trusted, even with no contacts before', () async {
      final broken = _ReadsEmpty();
      broken.beforeCreateAll = (call) async {
        if (call == 1) {
          broken.empty = true;
          broken.createAllError = Exception('provider gone');
        }
      };
      final error = await createFakeContacts(
              broken, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect((error! as StoppedPartway).done, 2);
      expect(logged.last, contains('are missing'));
      // So the pending record stays for later.
      broken.empty = false;
      expect((await storedWithPending()).pending, isNotNull);
    });

    test("Delete: a re-read that lost the fakes of later chunks isn't "
        'trusted, even with only fakes in the address book', () async {
      final broken = _ReadsEmpty();
      await createFakeContacts(broken, const LedgerStore(), kSettings);
      final ledgerBefore = await const LedgerStore().load();
      broken.beforeDeleteAll = (call) async {
        broken.empty = true;
        broken.deleteAllError = Exception('provider gone');
        broken.deleteAllStopsAfter = 0;
      };
      final error = await deleteFakeContacts(
              broken, const LedgerStore(), kSettings, chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect((error! as StoppedPartway).done, isNull);
      broken.empty = false;
      expect(broken.all, hasLength(4));
      expect((await const LedgerStore().load()).entries, ledgerBefore.entries);
    });

    test('Create: two new fakes Android linked into one contact keep the '
        'entry they were recorded with', () async {
      // Zach Zen is linked into the contact Zoe Zen was just created as.
      String? zoeContact;
      book.mergeInto = (c) {
        if (c.first == 'Zoe' && c.last == 'Zen') return null;
        return c.first == 'Zach' && c.last == 'Zen' ? zoeContact : null;
      };
      book.beforeCreateAll = (call) async {
        if (call == 1) zoeContact = book.idOf('Zoe Zen');
      };
      await createFakeContacts(book, const LedgerStore(), kSettings,
          chunkSize: 1);

      final ledger = await const LedgerStore().load();
      final raws = book.rawIdsOf(book.idOf('Zoe Zen'));
      expect(raws, hasLength(2));
      // Recorded when the first chunk was looked up; the second chunk's
      // lookup doesn't take it again.
      expect(ledger.entries[raws.first]!.name, 'Zoe Zen');
    });

    test('Delete: a chunk all deleted before its call failed: it goes on',
        () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      book.beforeDeleteAll = (call) async {
        book.deleteAllError = call == 0 ? Exception('provider gone') : null;
        book.deleteAllStopsAfter = call == 0 ? 2 : null;
      };
      final result = await deleteFakeContacts(
          book, const LedgerStore(), kSettings,
          chunkSize: 2);

      expect((result!.deleted, result.stopped), (4, false));
      expect(book.all, isEmpty);
      expect((await const LedgerStore().load()).isEmpty, isTrue);
    });
  });
}
