// Create and Delete when saving the ledger fails, e.g. with the phone's
// storage full. (The flow tests can't make saving fail.)

import 'dart:async';
import 'dart:convert';

import 'package:decoy_contacts/app_log.dart';
import 'package:decoy_contacts/contact_actions.dart';
import 'package:decoy_contacts/contacts_gateway.dart';
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/result_messages.dart';
import 'package:decoy_contacts/settings_store.dart';
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
/// as when a read comes back empty although it shouldn't (see C14).
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
  Future<void> deleteRawContacts(List<String> rawContactIds) async {
    try {
      return await super.deleteRawContacts(rawContactIds);
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

/// While [empty] is set, the address book reads as empty, as when a read
/// comes back empty although it shouldn't (see C14).
class _ReadsEmpty extends InMemoryContactsGateway {
  bool empty = false;

  /// The next this many reads come back empty, then reads are normal again.
  int emptyReads = 0;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    if (emptyReads > 0) {
      emptyReads--;
      return [];
    }
    return empty ? [] : await super.getAll(ids: ids);
  }
}

/// Once [arrive] is set, it is called once, right after the next read of
/// the address book, which doesn't see what it does: as when a contact
/// arrives between Delete's check and its delete.
class _ChangesAfterRead extends InMemoryContactsGateway {
  void Function()? arrive;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final found = await super.getAll(ids: ids);
    final then = arrive;
    arrive = null;
    then?.call();
    return found;
  }
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

    final deleted = await deleteFakeContacts(book, store);
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
      if (book.contactOfRaw(bobRaw) != null) book.removeContact(bob);
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
    // A read comes back empty although it shouldn't.
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
    broken.deleteRawContactsError = Exception('provider gone');
    broken.deleteRawContactsStopsAfter = 2;
    final error = await deleteFakeContacts(broken, const LedgerStore())
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
    book.deleteRawContactsError = Exception('provider gone');
    book.deleteRawContactsStopsAfter = 4;

    final result = await deleteFakeContacts(book, const LedgerStore());

    expect(result!.deleted, 4);
    expect(book.all, isEmpty);
    expect((await stored()).isEmpty, isTrue);
    expect(logged.single, contains('recovered: Exception: provider gone'));
  });

  test("Delete, and its preview when it records a killed Create's fakes, "
      "save the ledger without the entries they can't read", () async {
    Future<Map<String, Object?>> storedJson() async => jsonDecode(
        (await SharedPreferences.getInstance()).getString(kLedgerPrefsKey)!)
        as Map<String, Object?>;
    // Adds an entry with only a name, as early test builds stored them,
    // for a real contact.
    final alice = book.rawIdsOf(book.add('Alice Example')).single;
    Future<void> addUnreadable() async =>
        (await SharedPreferences.getInstance()).setString(kLedgerPrefsKey,
            jsonEncode({...await storedJson(), alice: 'Alice Example'}));
    book.afterCreateAll =
        (call) => call == 0 ? Completer<void>().future : Future.value();
    unawaited(createFakeContacts(book, const LedgerStore(), kSettings));
    await pumpEventQueue();
    await addUnreadable();

    expect((await previewDelete(book, const LedgerStore())).toDelete, 4);
    final fakes = [for (final c in book.all) ...c.rawContactIds]..remove(alice);
    expect((await storedJson()).keys, unorderedEquals(fakes));

    // One fake is edited, so Delete leaves it alone and saves its entry.
    final edited = book.idOf('Zoe Zen');
    book.setPhones(edited, ['+15555550199']);
    await addUnreadable();
    expect((await deleteFakeContacts(book, const LedgerStore()))!.deleted, 3);
    expect((await storedJson()).keys, book.rawIdsOf(edited));
    expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
  });

  test("Delete's preview: a failed save of the fakes of a Create that was "
      'killed does no harm', () async {
    book.afterCreateAll =
        (call) => call == 0 ? Completer<void>().future : Future.value();
    unawaited(createFakeContacts(book, const LedgerStore(), kSettings));
    await pumpEventQueue();
    final store = _WritesNothingWhenFull(succeeding: 0);

    final preview = await previewDelete(book, store);

    expect(preview.toDelete, 4);
    expect(logged.single, contains('previewDelete, saving the ledger'));
    // Not written: Delete finds them from the pending record again.
    final onDisk = await const LedgerStore().loadWithPending();
    expect((onDisk.ledger.length, onDisk.pending!.entries.length), (0, 4));
    store.succeeding = 1;
    final result = await deleteFakeContacts(book, store);
    expect(result!.deleted, 4);
    expect(book.all, isEmpty);
  });

  test('Delete: if saving the ledger fails, all were still deleted', () async {
    await createFakeContacts(book, const LedgerStore(), kSettings);

    final result = await deleteFakeContacts(book, FailingLedgerStore(1));

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
      final preview = await previewDelete(book, const LedgerStore());
      expect(preview.toDelete, created);
      final deleted = await deleteFakeContacts(book, const LedgerStore());
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

      final deleted = await deleteFakeContacts(book, const LedgerStore());
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
      final preview = await previewDelete(book, const LedgerStore());
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

      // As with a read that comes back empty although it shouldn't: nothing
      // is found, and nothing is given up.
      broken.empty = true;
      final none = await previewDelete(broken, const LedgerStore());
      expect(none.toDelete, 0);
      final kept = await storedWithPending();
      expect(kept.pending!.entries, killed.pending!.entries);

      broken.empty = false;
      final preview = await previewDelete(broken, const LedgerStore());
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
          book, const LedgerStore(),
          chunkSize: 1,
          onProgress: (done, total) {
            progress.add((done, total));
            bStop = done == 3;
          },
          stopRequested: () => bStop);

      expect(result!.stopped, isTrue);
      expect((result.deleted, result.planned), (3, 4));
      expect(progress, [(0, 4), (1, 4), (2, 4), (3, 4)]);
      expect([for (final c in book.deleteRawContactsCalls) c.length], [1, 1, 1]);
      expect(book.all, hasLength(1));
      final ledger = await const LedgerStore().load();
      expect(ledger.entries.keys, book.all.single.rawContactIds);

      final rest = await deleteFakeContacts(book, const LedgerStore(),
          chunkSize: 1);
      expect((rest!.deleted, rest.stopped), (1, false));
      expect(book.all, isEmpty);
    });

    test('Delete: a chunk that fails says how many it deleted in all',
        () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      book.beforeDeleteRawContacts = (call) async {
        if (call == 1) {
          book.deleteRawContactsError = Exception('provider gone');
          book.deleteRawContactsStopsAfter = 1;
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), chunkSize: 2)
          .then<Object?>((_) => null, onError: (Object e) => e);

      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (3, 4));
      expect(book.all, hasLength(1));
    });

    test("Delete: a chunk that fails is counted on its own: contacts of later "
        "chunks deleted meanwhile don't make up for it", () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      final lastFake = book.all.last.id;
      book.beforeDeleteRawContacts = (call) async {
        if (call == 1) {
          // Meanwhile, say by a sync, a fake of the last chunk goes.
          book.removeContact(lastFake);
          book.deleteRawContactsError = Exception('provider gone');
          book.deleteRawContactsStopsAfter = 0;
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), chunkSize: 1)
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
      book.beforeDeleteRawContacts = (call) async {
        if (call == 1) {
          book.deleteRawContactsError = Exception('provider gone');
          book.getAllError = Exception('provider gone');
        }
      };
      final error = await deleteFakeContacts(
              book, const LedgerStore(), chunkSize: 2)
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
        'Delete and a Create with nothing to do', () async {
      // (Delete's preview saves nothing then: see 'a pending Create is kept
      // while the address book reads as empty'.)
      final broken = _ReadsEmpty();
      final e = entryFor(const FakeName('Zoe', 'Zen'), kDefaultPhoneTemplate,
          kDefaultEmailTemplate);
      final zoe = broken.add('Zoe Zen', phones: [e.phone], emails: [e.email]);
      final pending = PendingCreate(maxRawId: 5, entries: [e]);
      await const LedgerStore()
          .save(Ledger({broken.rawIdsOf(zoe).single: e}), pending: pending);
      broken.empty = true;

      const noNames = Settings(
          lastNamesText: '',
          firstNamesText: '',
          phoneTemplateText: kDefaultPhoneTemplate,
          emailTemplateText: kDefaultEmailTemplate);
      await createFakeContacts(broken, const LedgerStore(), noNames);
      var stored = await storedWithPending();
      expect(stored.pending!.entries, pending.entries);
      expect(stored.ledger.entries, {broken.rawIdsOf(zoe).single: e});

      // And Delete's own save, with nothing to delete.
      await deleteFakeContacts(broken, const LedgerStore());
      stored = await storedWithPending();
      expect(stored.pending!.entries, pending.entries);
      expect(stored.ledger.entries, {broken.rawIdsOf(zoe).single: e});
    });

    // C14: a read that comes back empty must never shrink the ledger: a fake
    // whose entry is lost can't be deleted by the app any more.
    group('an empty read (C14)', () {
      test('Delete: the address book reads as empty after the user agreed: '
          'nothing is deleted and the ledger keeps its entries', () async {
        final broken = _ReadsEmpty();
        await createFakeContacts(broken, const LedgerStore(), kSettings);
        final ledgerBefore = await stored();
        final preview = await previewDelete(broken, const LedgerStore());
        expect(preview.toDelete, 4);

        broken.empty = true;
        final result = await deleteFakeContacts(broken, const LedgerStore(),
            atMost: preview.toDelete);
        expect(result!.deleted, 0);
        expect((await stored()).entries, ledgerBefore.entries);

        broken.empty = false;
        expect(
            (await countFakeContacts(broken, const LedgerStore())).toDelete, 4);
        expect(
            (await deleteFakeContacts(broken, const LedgerStore()))!.deleted, 4);
        expect(broken.all, isEmpty);
      });

      test('Create: the first read comes back empty: the ledger keeps the '
          'entries of the fakes that are there', () async {
        final broken = _ReadsEmpty();
        await createFakeContacts(broken, const LedgerStore(), kSettings);
        final ledgerBefore = await stored();

        // (Create makes them again then, as it can't see they exist.)
        broken.emptyReads = 1;
        final result =
            await createFakeContacts(broken, const LedgerStore(), kSettings);
        expect(result!.created, 4);
        expect(broken.all, hasLength(8));
        final after = await stored();
        expect(after.length, 8);
        for (final MapEntry(:key, :value) in ledgerBefore.entries.entries) {
          expect(after.entries[key], value);
        }

        // So Delete can still remove every one of them.
        expect(
            (await deleteFakeContacts(broken, const LedgerStore()))!.deleted, 8);
        expect(broken.all, isEmpty);
      });

      test('an address book that really is empty leaves stale entries, which '
          'the next read that finds contacts drops', () async {
        await createFakeContacts(book, const LedgerStore(), kSettings);
        for (final c in book.all) {
          book.removeContact(c.id);
        }
        expect(book.all, isEmpty);

        // Nothing to delete, and nothing is given up.
        var result = await deleteFakeContacts(book, const LedgerStore());
        expect(result!.deleted, 0);
        expect((await stored()).length, 4);
        expect((await countFakeContacts(book, const LedgerStore())).toDelete, 0);

        // As soon as the address book has a contact, they are pruned.
        book.add('Real Person');
        result = await deleteFakeContacts(book, const LedgerStore());
        expect(result!.deleted, 0);
        expect((await stored()).isEmpty, isTrue);
      });
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
      broken.beforeDeleteRawContacts = (call) async {
        broken.empty = true;
        broken.deleteRawContactsError = Exception('provider gone');
        broken.deleteRawContactsStopsAfter = 0;
      };
      final error = await deleteFakeContacts(
              broken, const LedgerStore(), chunkSize: 2)
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
      expect(ledger.entries[raws.last]!.name, 'Zach Zen');
      expect(ledger.length, 4);
    });

    test('Delete: a chunk all deleted before its call failed: it goes on',
        () async {
      await createFakeContacts(book, const LedgerStore(), kSettings);
      book.beforeDeleteRawContacts = (call) async {
        book.deleteRawContactsError = call == 0 ? Exception('provider gone') : null;
        book.deleteRawContactsStopsAfter = call == 0 ? 2 : null;
      };
      final result = await deleteFakeContacts(book, const LedgerStore(),
          chunkSize: 2);

      expect((result!.deleted, result.stopped), (4, false));
      expect(book.all, isEmpty);
      expect((await const LedgerStore().load()).isEmpty, isTrue);
    });
  });

  group('Delete deletes exactly the fakes it checked (C17)', () {
    for (final (how, keepsTheFakesContact) in [
      // As the Contacts app's "Link" does: the older contact ID stays.
      ('linked into', true),
      // As Android does by itself when a contact of another account arrives
      // with the same name: it gives the merged contact a new ID.
      ('merged by Android with', false),
    ]) {
      test("a real contact $how a fake's contact after Delete checked it: "
          'the fake goes, and the real one stays', () async {
        final changing = _ChangesAfterRead();
        book = changing;
        await createFakeContacts(book, const LedgerStore(), kSettings);
        final fakes = [for (final c in book.all) ...c.rawContactIds];
        final zoe = book.idOf('Zoe Zen');
        final zoeRaw = book.rawIdsOf(zoe).single;
        String? realRaw;
        // Right after Delete's check. Say, a sync brings it in.
        changing.arrive = () {
          final real = book.add('Zoe Zen', phones: ['+15555550101']);
          realRaw = book.rawIdsOf(real).single;
          if (keepsTheFakesContact) {
            book.merge(into: zoe, from: real);
          } else {
            book.merge(into: real, from: zoe);
          }
        };

        final result =
            await deleteFakeContacts(book, const LedgerStore(), atMost: 4);
        expect(realRaw, isNotNull);

        expect((result!.deleted, result.skippedMerged, result.skippedChanged),
            (4, 0, 0));
        expect(book.deleteRawContactsCalls.single, unorderedEquals(fakes));
        expect(book.contactOfRaw(zoeRaw), isNull);
        final [left] = book.all;
        expect(left.rawContactIds, [realRaw]);
        expect(left.phones, ['+15555550101']);
        expect((await stored()).isEmpty, isTrue);
      });
    }
  });

  group('names Android shows in another order (C16)', () {
    // For Chinese, Japanese and Korean names, Android shows the family name
    // first, with no space: the given name 伟 and the family name 王 show as
    // "王伟". (Checked on Android 16.) The name parts are kept as written.
    String familyFirst(String first, String last) => '$last$first';
    Settings names(String last, String first) => Settings(
          lastNamesText: last,
          firstNamesText: first,
          phoneTemplateText: kDefaultPhoneTemplate,
          emailTemplateText: kDefaultEmailTemplate,
        );
    // 2 x 2 = 4 fakes: 伟 王, 芳 王, 伟 李, 芳 李.
    final settings = names('王, 李', '伟, 芳');

    setUp(() {
      book.androidDisplayName = familyFirst;
      book.add('Alice Example', phones: ['+15555550103']);
    });

    test('Create records the names as created; a second Create adds none; '
        'the count, the preview and Delete take all four', () async {
      final result =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((result!.created, result.untracked), (4, 0));
      expect(book.displayNames,
          unorderedEquals(['Alice Example', '王伟', '王芳', '李伟', '李芳']));
      final ledger = await stored();
      expect([for (final e in ledger.entries.values) e.name],
          unorderedEquals(['伟 王', '芳 王', '伟 李', '芳 李']));

      final again =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((again!.created, again.alreadyExisted), (0, 4));
      expect(book.all, hasLength(5));

      expect((await countFakeContacts(book, const LedgerStore())).toDelete, 4);
      final preview = await previewDelete(book, const LedgerStore());
      expect((preview.toDelete, preview.skippedMerged, preview.skippedChanged),
          (4, 0, 0));
      final deleted =
          await deleteFakeContacts(book, const LedgerStore(), atMost: 4);
      expect((deleted!.deleted, deleted.skippedMerged, deleted.skippedChanged),
          (4, 0, 0));
      expect(book.displayNames, ['Alice Example']);
      expect((await stored()).isEmpty, isTrue);
    });

    test('Create finds the fakes by their details when the ledger is lost',
        () async {
      await createFakeContacts(book, const LedgerStore(), settings);
      SharedPreferences.setMockInitialValues({});

      final again =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((again!.created, again.alreadyExisted), (0, 4));
      expect(book.all, hasLength(5));
    });

    test('a name of two scripts: Android puts the family name first with no '
        'space, and the fake is still found', () async {
      book.androidDisplayName = (first, last) => '$last$first';
      final mixed = names('王', 'Anna');
      await createFakeContacts(book, const LedgerStore(), mixed);
      expect(book.displayNames, contains('王Anna'));

      expect((await countFakeContacts(book, const LedgerStore())).toDelete, 1);
      expect((await deleteFakeContacts(book, const LedgerStore()))!.deleted, 1);
      expect(book.displayNames, ['Alice Example']);
    });

    test('a fake that was changed is left alone: another name, or a prefix, '
        'middle name or suffix added', () async {
      await createFakeContacts(book, const LedgerStore(), settings);
      final raws = [for (final c in book.all) ...c.rawContactIds]
        ..removeAt(0); // Alice
      book.rename(raws[0], '王大伟');
      book.setNameParts(raws[1], const NameParts(prefix: 'Dr', given: '芳', family: '王'));
      book.setNameParts(raws[2], const NameParts(given: '伟', middle: 'M', family: '李'));
      book.setNameParts(raws[3], const NameParts(given: '芳', family: '李', suffix: 'Jr'));

      final preview = await previewDelete(book, const LedgerStore());
      expect((preview.toDelete, preview.skippedMerged, preview.skippedChanged),
          (0, 0, 4));
      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect(deleted!.deleted, 0);
      expect(book.all, hasLength(5));
    });

    test('a real contact with the name parts and the details of a fake, '
        'which the app did not create, is never deleted', () async {
      await createFakeContacts(book, const LedgerStore(), settings);
      final fake = (await stored()).entries.values.firstWhere((e) => e.name == '伟 王');
      final real = book.add('王伟', phones: [fake.phone], emails: [fake.email]);
      book.setNameParts(book.rawIdsOf(real).single,
          const NameParts(given: '伟', family: '王'));

      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect(deleted!.deleted, 4);
      expect(book.displayNames, ['Alice Example', '王伟']);
    });

    test("a name with no parts is compared by its display name, as before",
        () async {
      // A raw contact that has no name, or only an empty one.
      const none = StoredRawContact(id: '1', displayName: 'Zoe Zen');
      const empty = StoredRawContact(
          id: '2', displayName: 'Zoe Zen', nameParts: NameParts());
      const parts = StoredRawContact(
          id: '3',
          displayName: '王伟',
          nameParts: NameParts(given: '伟', family: '王'));
      expect([none.name, empty.name, parts.name], ['Zoe Zen', 'Zoe Zen', '伟 王']);
      expect(fingerprintsOfRawContact(parts), {
        contactFingerprint('伟 王', '', ''),
      });
    });
  });

  group('fakes that Android merged with each other (C15)', () {
    // Zen and Zena give the same phone number, so the fakes "Zena Zen" and
    // "Zen Zena" (the same letters) get the same number, and Android merges
    // them: see [mergeReversed].
    Settings names(String last, String first) => Settings(
          lastNamesText: last,
          firstNamesText: first,
          phoneTemplateText: kDefaultPhoneTemplate,
          emailTemplateText: kDefaultEmailTemplate,
        );
    final settings = names('Zen, Zena', 'Zen, Zena');

    /// From now on, a new contact whose name is another's in reverse is
    /// merged into that one, as Android does when they also share a number.
    void mergeReversed() {
      book.mergeInto = (c) {
        if (c.first == c.last) return null;
        final reversed = '${c.last} ${c.first}';
        for (final contact in book.all) {
          if (contact.rawContacts.any((r) => r.displayName == reversed)) {
            return contact.id;
          }
        }
        return null;
      };
    }

    /// The two raw contacts of the merged contact, "Zena Zen" (created
    /// first, so its name is shown) and "Zen Zena".
    List<String> mergedPair() {
      final raws = book.rawIdsOf(book.idOf('Zena Zen'));
      expect(raws, hasLength(2));
      return raws;
    }

    setUp(() {
      book.add('Alice Example', phones: ['+15555550103']);
      mergeReversed();
    });

    test('Create records each with its own details; the count, the preview '
        'and Delete take all four', () async {
      final result =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((result!.created, result.untracked), (4, 0));
      // Found among the contacts the call gave, without reading every
      // contact again (once before, once for those).
      expect(book.getAllCalls, 2);
      expect(book.all, hasLength(4)); // Alice, and the fakes in three
      final [zenaZen, zenZena] = mergedPair();
      final ledger = await stored();
      expect(ledger.length, 4);
      expect(ledger.entries[zenaZen], entryFor(const FakeName('Zena', 'Zen'),
          kDefaultPhoneTemplate, kDefaultEmailTemplate));
      expect(ledger.entries[zenZena], entryFor(const FakeName('Zen', 'Zena'),
          kDefaultPhoneTemplate, kDefaultEmailTemplate));

      expect((await countFakeContacts(book, const LedgerStore())).toDelete, 4);
      final preview = await previewDelete(book, const LedgerStore());
      expect((preview.toDelete, preview.skippedMerged, preview.skippedChanged),
          (4, 0, 0));
      final deleted =
          await deleteFakeContacts(book, const LedgerStore(), atMost: 4);
      expect((deleted!.deleted, deleted.skippedMerged, deleted.skippedChanged),
          (4, 0, 0));
      expect(book.displayNames, ['Alice Example']);
      expect((await stored()).isEmpty, isTrue);
    });

    test('the first of the pair moved into the second one\'s contact during '
        'the call: both are recorded, by their details', () async {
      // As Android does when they are written in two batches: the contact ID
      // the call gave for "Zena Zen" is gone by the time it returns.
      book.mergeInto = null;
      late String gone;
      book.afterCreateAll = (_) async {
        gone = book.idOf('Zena Zen');
        book.merge(into: book.idOf('Zen Zena'), from: gone);
      };
      final result =
          await createFakeContacts(book, const LedgerStore(), settings);

      expect((result!.created, result.untracked), (4, 0));
      // Found in what was read for the call's contacts, without reading
      // every contact again.
      expect(book.getAllCalls, 2);
      expect(book.all.map((c) => c.id), isNot(contains(gone)));
      final [zenZena, zenaZen] = book.rawIdsOf(book.idOf('Zen Zena'));
      final ledger = await stored();
      expect((ledger.entries[zenaZen]!.name, ledger.entries[zenZena]!.name),
          ('Zena Zen', 'Zen Zena'));
      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect((deleted!.deleted, deleted.skippedChanged), (4, 0));
    });

    test('two fakes with the same name, phone and email that Android merged: '
        'both recorded and deleted', () async {
      // "A B" "C" and "A" "B C" are both "A B C"; with no n in the phone
      // template and no email, their details are the same too.
      book.mergeInto = (c) =>
          c.first == 'A' && c.last == 'B C' ? book.idOf('A B C') : null;
      const same = Settings(
        lastNamesText: 'C, B C',
        firstNamesText: 'A B, A',
        phoneTemplateText: '+447700900123',
        emailTemplateText: '',
      );
      final result = await createFakeContacts(book, const LedgerStore(), same);

      expect((result!.created, result.untracked), (4, 0));
      expect(book.rawIdsOf(book.idOf('A B C')), hasLength(2));
      expect((await stored()).length, 4);
      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect((deleted!.deleted, deleted.skippedChanged), (4, 0));
      expect(book.displayNames, ['Alice Example']);

      // After a call that fails once it has made them all, the two can't be
      // told from a copy synced meanwhile: they stay pending, the others
      // are recorded.
      book.createAllError = Exception('provider gone');
      book.createAllStopsAfter = 4;
      final error = await createFakeContacts(book, const LedgerStore(), same)
          .then<Object?>((_) => null, onError: (Object e) => e);
      final stopped = error! as StoppedPartway;
      expect((stopped.done, stopped.planned), (2, 4));
      final left = await const LedgerStore().loadWithPending();
      expect(left.ledger.entries.values.map((e) => e.name),
          unorderedEquals(['A C', 'A B B C']));
      expect(left.pending!.entries.map((e) => e.name), ['A B C', 'A B C']);
    });

    test('a second Create finds all four, also with the ledger lost: the one '
        "shown under the other's name too", () async {
      await createFakeContacts(book, const LedgerStore(), settings);
      final again =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((again!.created, again.alreadyExisted), (0, 4));

      SharedPreferences.setMockInitialValues({});
      final afterLoss =
          await createFakeContacts(book, const LedgerStore(), settings);
      expect((afterLoss!.created, afterLoss.alreadyExisted), (0, 4));
      expect(book.createAllCalls, hasLength(1));
    });

    test('merged across two Creates: Delete removes both', () async {
      await createFakeContacts(book, const LedgerStore(),
          names('Zen', 'Zena'));
      final second = await createFakeContacts(book, const LedgerStore(),
          names('Zena', 'Zen'));
      expect((second!.created, second.untracked), (1, 0));
      final [zenaZen, zenZena] = mergedPair();
      final ledger = await stored();
      expect((ledger.entries[zenaZen]!.name, ledger.entries[zenZena]!.name),
          ('Zena Zen', 'Zen Zena'));

      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect((deleted!.deleted, deleted.skippedChanged), (2, 0));
      expect(book.displayNames, ['Alice Example']);
    });

    test('one of the pair edited: Delete leaves both, that one as no longer '
        'matching, the other as merged', () async {
      await createFakeContacts(book, const LedgerStore(), settings);
      final [zenaZen, zenZena] = mergedPair();
      book.rename(zenZena, 'Zen Zena Jr');

      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect((deleted!.deleted, deleted.skippedMerged, deleted.skippedChanged),
          (2, 1, 1));
      expect(book.displayNames, unorderedEquals(['Alice Example', 'Zena Zen']));
      expect((await stored()).entries.keys, unorderedEquals([zenaZen, zenZena]));
    });

    group('Delete in chunks of one fake (Zen Zen, the pair, Zena Zena)', () {
      setUp(() => createFakeContacts(book, const LedgerStore(), settings));

      test('Stop after the pair: both of its fakes are counted, and the rest '
          'stays recorded', () async {
        final result = await deleteFakeContacts(book, const LedgerStore(),
            chunkSize: 1,
            stopRequested: () => book.deleteRawContactsCalls.length == 3);

        expect((result!.deleted, result.planned, result.stopped),
            (3, 4, true));
        expect(book.displayNames,
            unorderedEquals(['Alice Example', 'Zena Zena']));
        expect((await stored()).entries.values.map((e) => e.name),
            ['Zena Zena']);
      });

      test("Stop between the pair's two fakes: the one left stays recorded, "
          'and the next Delete removes it', () async {
        final [zenaZen, zenZena] = mergedPair();
        final result = await deleteFakeContacts(book, const LedgerStore(),
            chunkSize: 1,
            stopRequested: () => book.deleteRawContactsCalls.length == 2);

        expect((result!.deleted, result.planned, result.stopped),
            (2, 4, true));
        expect(book.contactOfRaw(zenaZen), isNull);
        expect(book.rawIdsOf(book.contactOfRaw(zenZena)!), [zenZena]);
        expect((await stored()).entries.keys,
            unorderedEquals([zenZena, ...book.rawIdsOf(book.idOf('Zena Zena'))]));
        final again = await deleteFakeContacts(book, const LedgerStore());
        expect((again!.deleted, again.skippedMerged, again.skippedChanged),
            (2, 0, 0));
        expect(book.displayNames, ['Alice Example']);
      });

      test('a call that fails after deleting its fake: it goes on', () async {
        book.beforeDeleteRawContacts = (call) async {
          book.deleteRawContactsError =
              call == 1 ? Exception('provider gone') : null;
          book.deleteRawContactsStopsAfter = call == 1 ? 1 : null;
        };
        final result = await deleteFakeContacts(book, const LedgerStore(),
            chunkSize: 1);

        expect((result!.deleted, result.stopped), (4, false));
        expect(book.displayNames, ['Alice Example']);
        expect((await stored()).isEmpty, isTrue);
      });

      test('a call that fails before deleting one of the pair says how many '
          'it deleted, and the pair stays recorded', () async {
        final pair = mergedPair();
        book.beforeDeleteRawContacts = (call) async {
          book.deleteRawContactsError =
              call == 1 ? Exception('provider gone') : null;
          book.deleteRawContactsStopsAfter = call == 1 ? 0 : null;
        };
        final error = await deleteFakeContacts(book, const LedgerStore(),
                chunkSize: 1)
            .then<Object?>((_) => null, onError: (Object e) => e);

        final stopped = error! as StoppedPartway;
        expect((stopped.done, stopped.planned), (1, 4));
        expect((await stored()).entries.keys, containsAll(pair));
        // Trying again deletes the rest.
        book.beforeDeleteRawContacts = null;
        book.deleteRawContactsError = null;
        final again = await deleteFakeContacts(book, const LedgerStore());
        expect(again!.deleted, 3);
        expect(book.displayNames, ['Alice Example']);
      });
    });

    test('a call that fails after making the pair: each is found by its own '
        'details', () async {
      // Zen Zen, Zena Zen and Zen Zena are created; Zena Zena isn't.
      book.createAllError = Exception('provider gone');
      book.createAllStopsAfter = 3;
      final error = await createFakeContacts(
              book, const LedgerStore(), settings)
          .then<Object?>((_) => null, onError: (Object e) => e);

      expect((error! as StoppedPartway).done, 3);
      final [zenaZen, zenZena] = mergedPair();
      final ledger = await stored();
      expect(ledger.length, 3);
      expect((ledger.entries[zenaZen]!.name, ledger.entries[zenZena]!.name),
          ('Zena Zen', 'Zen Zena'));
    });

    test('killed during the call that made the pair: Delete finds and '
        'deletes both', () async {
      book.afterCreateAll = (_) => Completer<void>().future;
      unawaited(createFakeContacts(book, const LedgerStore(), settings));
      await pumpEventQueue();
      expect((await stored()).isEmpty, isTrue);

      final deleted = await deleteFakeContacts(book, const LedgerStore());
      expect((deleted!.deleted, deleted.skippedChanged), (4, 0));
      expect(book.displayNames, ['Alice Example']);
    });
  });
}
