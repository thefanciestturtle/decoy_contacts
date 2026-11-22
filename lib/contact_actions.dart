// The Create and Delete operations: address book plus ledger, no UI.

import 'dart:developer';
import 'dart:math' as math;

import 'app_log.dart';
import 'contacts_gateway.dart';
import 'fake_contacts_core.dart';
import 'settings_store.dart';

/// How many contacts Create makes per call to the address book. Measured on
/// an emulator (API 36), 10,000 took 34 s in chunks of 100 and 36 s in one
/// call, ledger saves included: small enough for progress about three
/// times a second and a quick Stop, with nothing lost in speed.
const int kCreateChunkSize = 100;

/// How many fakes (raw contacts) Delete deletes per call, by raw contact ID.
/// Measured on an emulator (API 36), 10,000 took about 4 s in chunks of 200.
const int kDeleteChunkSize = 200;

/// Told how many of [total] contacts a Create or Delete has done so far: 0
/// before it starts, then after each chunk. Only for one of more than one
/// chunk; a smaller one is over too soon to show progress.
typedef ProgressCallback = void Function(int done, int total);

class CreateResult {
  final int created;
  final int alreadyExisted;

  /// Created, but their raw contact IDs couldn't be found to record them.
  final int untracked;

  /// How many it set out to create; more than [created] only if [stopped].
  final int planned;

  /// The user stopped it before it was done.
  final bool stopped;

  const CreateResult({
    required this.created,
    required this.alreadyExisted,
    required this.untracked,
    int? planned,
    this.stopped = false,
  }) : planned = planned ?? created;
}

/// A Create or Delete that failed after it may have changed the address
/// book. The address book was read again to find out how far it got.
class StoppedPartway implements Exception {
  /// How many fake contacts it created, or deleted, before it stopped; null
  /// if that couldn't be found out.
  final int? done;

  /// How many it set out to create or delete.
  final int planned;

  /// What stopped it, and where.
  final Object cause;
  final StackTrace stackTrace;

  const StoppedPartway(
      {required this.done,
      required this.planned,
      required this.cause,
      required this.stackTrace});

  /// How far it got, for the log.
  String get progress =>
      'stopped after ${done ?? "an unknown number"} of $planned';

  @override
  String toString() => 'StoppedPartway: $progress: $cause';
}

/// Whether [error] (for a [StoppedPartway], what stopped it, which its text
/// includes) says the phone's storage is full: SQLite's "database or disk
/// is full", which the contacts provider passes on (newer Android versions
/// add "(code 13 SQLITE_FULL)"), or the ledger couldn't be written, which in
/// practice means the same.
bool storageFull(Object error) {
  if (error is LedgerNotSaved ||
      (error is StoppedPartway && error.cause is LedgerNotSaved)) {
    return true;
  }
  final text = error.toString();
  return text.contains('SQLITE_FULL') ||
      text.contains('database or disk is full');
}

class DeleteResult {
  final int deleted;
  final int skippedMerged;
  final int skippedChanged;

  /// How many it set out to delete; more than [deleted] only if [stopped].
  final int planned;

  /// The user stopped it before it was done.
  final bool stopped;

  const DeleteResult({
    required this.deleted,
    required this.skippedMerged,
    required this.skippedChanged,
    int? planned,
    this.stopped = false,
  }) : planned = planned ?? deleted;
}

/// Contact ID -> raw contact IDs (Android only).
AddressBook addressBookOf(List<StoredContact> contacts) => {
      for (final c in contacts) c.id: c.rawContactIds,
    };

/// Every name/phone/email fingerprint of the raw contact [r], from its own
/// details (see [fingerprintsOf]).
Set<String> fingerprintsOfRawContact(StoredRawContact r) =>
    fingerprintsOf(r.displayName, r.phones, r.emails).toSet();

/// Raw contact ID -> its fingerprints (see [fingerprintsOfRawContact]), for
/// every raw contact of [contacts].
Map<String, Set<String>> fingerprintsByRawOf(List<StoredContact> contacts) => {
      for (final c in contacts)
        for (final r in c.rawContacts) r.id: fingerprintsOfRawContact(r),
    };

/// One fake contact as Create would make it: its name, phone number and
/// email address ('' if it gets none).
typedef FakeSample = ({String name, String phone, String email});

/// What a set of [Settings] makes, for the preview under the fields.
class SettingsPreview {
  /// How many different last and first names there are.
  final int lastNameCount;
  final int firstNameCount;

  /// The first fake the settings make, or null if they make none.
  final FakeSample? sample;

  /// [sample] is null exactly when there are no combinations.
  const SettingsPreview({
    required this.lastNameCount,
    required this.firstNameCount,
    required this.sample,
  }) : assert((sample == null) == (lastNameCount * firstNameCount == 0));

  /// How many fakes the settings make: every last name with every first
  /// name. Create adds those that don't exist yet.
  int get combinations => lastNameCount * firstNameCount;
}

/// Works out what [settings] make, the same way Create does. Reads neither
/// the address book nor the ledger, so it is cheap enough for every
/// keystroke.
SettingsPreview previewSettings(Settings settings) {
  final lastNames = settings.lastNames;
  final firstNames = settings.firstNames;
  final first = firstCombination(firstNames, lastNames);
  return SettingsPreview(
    lastNameCount: lastNames.length,
    firstNameCount: firstNames.length,
    sample: first == null
        ? null
        : _sampleOf(
            entryFor(first, settings.phoneTemplate, settings.emailTemplate)),
  );
}

FakeSample _sampleOf(LedgerEntry entry) =>
    (name: entry.name, phone: entry.phone, email: entry.email);

/// What Create would do right now, worked out without changing anything.
class CreatePreview {
  /// Contacts Create would add.
  final int toCreate;

  /// Name combinations skipped because they already exist.
  final int alreadyExisted;

  const CreatePreview({required this.toCreate, required this.alreadyExisted});
}

/// What Delete would do right now, worked out without changing anything.
class DeletePreview {
  final int toDelete;
  final int skippedMerged;
  final int skippedChanged;

  const DeletePreview({
    required this.toDelete,
    required this.skippedMerged,
    required this.skippedChanged,
  });
}

/// The ledger as [stored], with the fakes of a Create that was cut short
/// added (see [createdByPending]), if it left a [PendingCreate]; and
/// whether it did. Only adds to the ledger, and saves nothing.
///
/// If the address book reads as empty (a provider that can't be reached
/// makes the read fail instead, but a read can come back empty when it
/// shouldn't), the pending record is left for later ([left]; saves pass it
/// on). (A Create run meanwhile replaces it, and its fakes then stay
/// unrecorded; it would fail anyway.)
({Ledger ledger, bool resolved, PendingCreate? left}) _withPendingResolved(
    ({Ledger ledger, PendingCreate? pending}) stored,
    List<StoredContact> everyone,
    Map<String, Set<String>> fingerprintsByRaw) {
  final pending = stored.pending;
  if (pending == null || everyone.isEmpty) {
    return (ledger: stored.ledger, resolved: false, left: pending);
  }
  final found = createdByPending(pending,
      recorded: stored.ledger.entries.keys.toSet(),
      after: addressBookOf(everyone),
      fingerprintsByRaw: fingerprintsByRaw);
  log("found ${found.length} of ${pending.entries.length} fake(s) from an"
      " unfinished Create");
  return (
    ledger: Ledger({...stored.ledger.entries, ...found}),
    resolved: true,
    left: null,
  );
}

/// [stored] without the entries whose raw contacts the read [everyone]
/// didn't find, so that the ledger doesn't list what is gone.
///
/// A read that finds nothing at all prunes nothing: the address book may
/// really be empty, but a read can also come back empty when it shouldn't
/// (say, the contacts provider is restarting; one that can't be reached at
/// all makes the read fail instead), and an entry lost to such a
/// read can never be got back: Delete wouldn't know its fake any more. An
/// entry that is kept wrongly does no harm to Delete, which only acts on raw
/// contacts that are there and checks each one's name, phone number and
/// email. The next read that finds contacts prunes it. (Create would take
/// the name for a fake that exists if the provider's storage was reset and
/// handed its raw contact ID to another contact meanwhile: see C18.)
Ledger _prunedToRead(Ledger stored, List<StoredContact> everyone) {
  if (everyone.isEmpty) return stored;
  return stored.prunedTo(allRawIds(addressBookOf(everyone)));
}

/// The address book, the ledger and what Create would add to them.
class _CreatePlan {
  final AddressBook before;

  /// The ledger as stored, with the fakes of an unfinished Create (see
  /// [_withPendingResolved]); and the same checked against [before].
  final Ledger stored;
  final Ledger ledger;

  /// A pending record that couldn't be resolved yet (see
  /// [_withPendingResolved]).
  final PendingCreate? pendingLeft;

  final int wanted;

  /// Each name to create, with its ledger entry.
  final List<(FakeName, LedgerEntry)> toCreate;

  _CreatePlan(this.before, this.stored, this.ledger, this.pendingLeft,
      this.wanted, this.toCreate);

  int get alreadyExisted => wanted - toCreate.length;
}

Future<_CreatePlan> _planCreate(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final everyone = await contacts.getAll();
  final before = addressBookOf(everyone);
  final fingerprintsByRaw = fingerprintsByRawOf(everyone);
  final existingFingerprints = {
    for (final fingerprints in fingerprintsByRaw.values) ...fingerprints,
  };
  final (ledger: stored, resolved: _, :left) = _withPendingResolved(
      await ledgerStore.loadWithPending(), everyone, fingerprintsByRaw);
  final ledger = _prunedToRead(stored, everyone);
  final wanted = allCombinations(settings.firstNames, settings.lastNames);
  LedgerEntry entryOf(FakeName n) =>
      entryFor(n, settings.phoneTemplate, settings.emailTemplate);
  final toCreate = namesToCreate(wanted, ledger, before,
      existingFingerprints: existingFingerprints,
      fingerprintOf: (n) => entryOf(n).fingerprint);
  return _CreatePlan(before, stored, ledger, left, wanted.length,
      [for (final n in toCreate) (n, entryOf(n))]);
}

/// Works out what [createFakeContacts] would do with the same arguments.
/// Reads the address book and the ledger, but changes neither.
Future<CreatePreview> previewCreate(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  return CreatePreview(
    toCreate: plan.toCreate.length,
    alreadyExisted: plan.alreadyExisted,
  );
}

/// Creates every first/last name combination from [settings] that doesn't
/// already exist, and records the new raw contacts in the ledger.
///
/// Works everything out afresh from the address book rather than trusting a
/// [previewCreate] made earlier. If that would now create more than
/// [atMost] contacts (the number the user agreed to), creates nothing and
/// returns null.
///
/// Creates them [chunkSize] at a time, telling [onProgress] how far it got
/// after each chunk. Once [stopRequested] says so, it stops after the chunk
/// it is on ([CreateResult.stopped]).
///
/// Before each chunk it saves the ledger, with what it recorded so far and
/// the chunk it is about to create (a [PendingCreate]): if the app is killed
/// meanwhile, the next Create, Delete or count finds that chunk's fakes. At
/// the end it saves the ledger without entries whose raw contacts are gone.
///
/// If creating fails, reads the address book again to record what that
/// chunk created, and throws [StoppedPartway] saying how far it got; unless
/// the whole chunk was created after all (say, only looking up the new
/// contacts failed), and then it goes on. If that can't be found out, the
/// pending record stays for the next Create or Delete, and
/// [StoppedPartway.done] counts what the chunks before created (null if
/// none). If saving the ledger fails before a later chunk, it stops with
/// [StoppedPartway]; what it made is still recorded, as the save before is
/// on disk (the chunk as a pending record), and the ledger stays in memory
/// while the app is open (see [LedgerStore.save]). If only the save at the
/// end fails, that is logged. An error before it creates anything is
/// thrown as it is.
Future<CreateResult?> createFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings,
    {int? atMost,
    int chunkSize = kCreateChunkSize,
    ProgressCallback? onProgress,
    bool Function()? stopRequested}) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  final toCreate = plan.toCreate;
  if (atMost != null && toCreate.length > atMost) {
    log("createFakeContacts: ${toCreate.length} to create, more than $atMost");
    return null;
  }
  if (toCreate.isEmpty) {
    try {
      // Only drops entries whose raw contacts are gone (and adds those of
      // an unfinished Create).
      await ledgerStore.save(plan.ledger, pending: plan.pendingLeft);
    } catch (e, st) {
      logError("createFakeContacts, saving the ledger", e, st);
    }
    return CreateResult(
        created: 0, alreadyExisted: plan.alreadyExisted, untracked: 0);
  }
  final total = toCreate.length;
  final bChunked = total > chunkSize;
  // What this Create recorded so far, and every raw contact known to exist:
  // those from before, and those it created.
  final created = <String, LedgerEntry>{};
  final known = allRawIds(plan.before);
  var maxRawId = maxRawIdOf(known);
  var done = 0;
  var untracked = 0;
  var bStopped = false;
  if (bChunked) onProgress?.call(0, total);
  for (var start = 0; start < total; start += chunkSize) {
    if (start > 0 && (stopRequested?.call() ?? false)) {
      log("createFakeContacts: stopped after $done of $total");
      bStopped = true;
      break;
    }
    final chunk = toCreate.sublist(start, math.min(start + chunkSize, total));
    final entries = [for (final (_, entry) in chunk) entry];
    final pending = PendingCreate(maxRawId: maxRawId, entries: entries);
    try {
      // Only adds to the ledger as stored: entries are dropped at the end.
      await ledgerStore.save(Ledger({...plan.stored.entries, ...created}),
          pending: pending);
    } catch (e, st) {
      if (done == 0) rethrow; // nothing created yet
      // The save before the last chunk holds it as a pending record.
      throw StoppedPartway(
          done: done, planned: total, cause: e, stackTrace: st);
    }
    final newContacts = [
      for (final (name, entry) in chunk)
        NewContact(
          first: name.first,
          last: name.last,
          phone: entry.phone,
          email: entry.email,
        ),
    ];
    // From here on, contacts may have been created, so an error must not
    // lose track of them.
    Map<String, LedgerEntry> found;
    try {
      log("createFakeContacts: about to call createAll for ${newContacts.length} contact(s)");
      final ids = await contacts.createAll(newContacts);
      // (Android may have merged two of them: then their contact ID is the
      // same.)
      final createdContacts = await contacts.getAll(ids: ids.toSet().toList());
      final after = addressBookOf(createdContacts);
      found = newlyCreatedRawIds(
          created: entries,
          createdContactIds: ids,
          oldRawIds: known,
          after: after,
          fingerprintsByRaw: fingerprintsByRawOf(createdContacts));
      done += ids.length;
      final missing = entriesNotFound(entries, found.values);
      if (missing.isNotEmpty) {
        // Not under the contact IDs the call gave (say, Android linked one
        // with another contact meanwhile, which changes its ID): look for
        // them by their details, as after a failure. Raw contacts already
        // recorded with another entry aren't taken.
        final more = await _findByDetails(contacts, {...known, ...found.keys},
            PendingCreate(maxRawId: pending.maxRawId, entries: missing));
        found = {...found, ...?more?.created};
      }
      final seen = {...allRawIds(after), ...found.keys};
      known.addAll(seen);
      maxRawId = _higher(maxRawId, maxRawIdOf(seen));
      untracked += entriesNotFound(entries, found.values).length;
    } catch (e, st) {
      // What this chunk created isn't known: work it out from the address
      // book.
      // (Those of the ledger that are still there are among [known].)
      final recovered =
          await _findByDetails(contacts, known, pending, untouched: known);
      if (recovered == null) {
        // The pending record stays: the next Create or Delete looks again.
        // What the chunks before created is known (and recorded).
        throw StoppedPartway(
            done: done > 0 ? done : null,
            planned: total,
            cause: e,
            stackTrace: st);
      }
      found = recovered.created;
      final count = found.length; // a raw contact per fake
      if (count != entries.length) {
        // Those not found stay pending, in case this read was wrong: the
        // next Create or Delete looks again.
        final unfound = entriesNotFound(entries, found.values);
        try {
          await ledgerStore.save(
              Ledger({...plan.stored.entries, ...created, ...found}),
              pending:
                  PendingCreate(maxRawId: pending.maxRawId, entries: unfound));
        } catch (e2, st2) {
          // The save before the chunk still holds it as a pending record.
          logError("createFakeContacts, recording what was created", e2, st2);
        }
        throw StoppedPartway(
            done: done + count, planned: total, cause: e, stackTrace: st);
      }
      // The whole chunk was created; only the step after it failed (e.g.
      // looking up the new contacts).
      logError("createFakeContacts, recovered", e, st);
      known.addAll(recovered.present);
      maxRawId = _higher(maxRawId, maxRawIdOf(recovered.present));
      done += count;
    }
    created.addAll(found);
    if (bChunked) onProgress?.call(done, total);
  }
  try {
    // Drops entries whose raw contacts are gone, and the pending record.
    await ledgerStore.save(Ledger({...plan.ledger.entries, ...created}),
        pending: null);
  } catch (e, st) {
    // No harm done: the save before the last chunk holds that one as a
    // pending record (the next Create or Delete records it), and the
    // ledger stays in memory while the app is open.
    logError("createFakeContacts, saving the ledger", e, st);
  }
  log("createFakeContacts: nCreated $done");
  return CreateResult(
    created: done,
    alreadyExisted: plan.alreadyExisted,
    untracked: untracked,
    planned: total,
    stopped: bStopped,
  );
}

/// The higher of two raw contact IDs, either of which may be missing.
int? _higher(int? a, int? b) =>
    a == null ? b : (b == null ? a : (a > b ? a : b));

/// Whether a read of the address book made after a failed Create or Delete
/// ([after]) can be trusted: unless there are none, some of the raw
/// contacts that must still be there ([untouched]: those from before that
/// it left alone, and those it created) are. A read that comes back empty
/// when it shouldn't (a provider that can't be reached makes it fail
/// instead) would look like everything was deleted, or nothing created.
/// (Some may be gone for other reasons, say deleted by a sync meanwhile.)
bool _plausibleAfterFailure(Set<String> untouched, AddressBook after) {
  final present = allRawIds(after);
  return untouched.isEmpty || untouched.any(present.contains);
}

/// Reads the address book and returns the fakes of [pending] in it (see
/// [createdByPending]; [recorded] are raw contacts not to be taken for
/// them), and every raw contact found; null if it can't be read.
///
/// After a failed call, [untouched] are the raw contacts that must still be
/// there: a read without any of them isn't trusted either (see
/// [_plausibleAfterFailure]).
Future<({Map<String, LedgerEntry> created, Set<String> present})?>
    _findByDetails(ContactsGateway contacts, Set<String> recorded,
        PendingCreate pending,
        {Set<String>? untouched}) async {
  try {
    final everyone = await contacts.getAll();
    final after = addressBookOf(everyone);
    if (untouched != null && !_plausibleAfterFailure(untouched, after)) {
      throw StateError("all contacts that were there before are missing");
    }
    return (
      created: createdByPending(pending,
          recorded: recorded,
          after: after,
          fingerprintsByRaw: fingerprintsByRawOf(everyone)),
      present: allRawIds(after),
    );
  } catch (e, st) {
    logError("createFakeContacts, looking for new contacts by their details",
        e, st);
    return null;
  }
}

/// What Delete would do, and the ledger it was worked out from.
class _DeleteCheck {
  final DeletePlan plan;

  /// The stored ledger (not pruned), with the fakes of an unfinished Create
  /// added (see [_withPendingResolved]); and whether there was one.
  final Ledger ledger;
  final bool pendingResolved;

  /// A pending record that couldn't be resolved yet, which saves keep.
  final PendingCreate? pendingLeft;

  /// The address book the plan was made from.
  final AddressBook book;

  _DeleteCheck(this.plan, this.ledger, this.pendingResolved, this.pendingLeft,
      this.book);
}

/// Plans a Delete against the [loaded] ledger, with the fakes of an
/// unfinished Create added (see [_withPendingResolved]). Only the ledger and
/// the address book decide it, never the settings.
Future<_DeleteCheck> _planDelete(ContactsGateway contacts,
    ({Ledger ledger, PendingCreate? pending}) loaded) async {
  final everyone = await contacts.getAll();
  final book = addressBookOf(everyone);
  final fingerprintsByRaw = fingerprintsByRawOf(everyone);
  final (ledger: stored, :resolved, :left) =
      _withPendingResolved(loaded, everyone, fingerprintsByRaw);
  var plan =
      planDelete(_prunedToRead(stored, everyone), book, fingerprintsByRaw);
  if (everyone.isEmpty) {
    // Nothing to delete, and nothing to give up (see [_prunedToRead]): what
    // the plan leaves is the whole ledger.
    plan = DeletePlan(
        rawContactIdsToDelete: plan.rawContactIdsToDelete,
        skippedMerged: plan.skippedMerged,
        skippedChanged: plan.skippedChanged,
        remaining: stored);
  }
  return _DeleteCheck(plan, stored, resolved, left, book);
}

DeletePreview _previewOf(DeletePlan plan) => DeletePreview(
      toDelete: plan.rawContactsDeleted,
      skippedMerged: plan.skippedMerged,
      skippedChanged: plan.skippedChanged,
    );

/// Works out what [deleteFakeContacts] would do with the same arguments.
///
/// Deletes nothing, and changes the ledger in one way only, as Delete does:
/// the fakes of a Create that was cut short are recorded (see
/// [createdByPending]), even if the user then cancels or there is nothing
/// to delete. (Like every save, that one leaves out entries it can't read:
/// see [Ledger.decode].)
Future<DeletePreview> previewDelete(
    ContactsGateway contacts, LedgerStore ledgerStore) async {
  final check =
      await _planDelete(contacts, await ledgerStore.loadWithPending());
  if (check.pendingResolved) {
    try {
      await ledgerStore.save(check.ledger, pending: check.pendingLeft);
    } catch (e, st) {
      // Not written (say, with the storage full), but kept in memory while
      // the app stays open; and on disk, the pending record is still there
      // for Delete to resolve again.
      logError("previewDelete, saving the ledger", e, st);
    }
  }
  return _previewOf(check.plan);
}

/// What Delete would find, for the status line: [DeletePreview.toDelete] is
/// how many fakes are still in the address book, counting only those this
/// app can confirm. Not counted, but in the skipped counts: entries that no
/// longer match what was created, and fakes in a contact that also holds a
/// raw contact that isn't the app's, or a fake that changed (see
/// [planDelete]). Fakes merged only with each other, unchanged, are
/// counted.
///
/// The fakes of a Create that was cut short are counted too (see
/// [createdByPending]), but only recorded by the next Create or Delete.
///
/// Changes nothing, not even the ledger, and doesn't read the address book
/// if the ledger is empty (with no Create cut short).
Future<DeletePreview> countFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore) async {
  final loaded = await ledgerStore.loadWithPending();
  if (loaded.ledger.isEmpty && loaded.pending == null) {
    return const DeletePreview(toDelete: 0, skippedMerged: 0, skippedChanged: 0);
  }
  return _previewOf((await _planDelete(contacts, loaded)).plan);
}

/// Deletes the fake contacts this app created and recorded in the ledger.
///
/// Only contacts recorded in the ledger at creation time are deleted, never
/// anything matched by name, so real contacts with the same name are safe.
/// Each must also still have exactly the recorded name, phone and email, in
/// case its raw contact ID now belongs to someone else (see [planDelete]).
/// It deletes exactly the raw contacts it checked, not their contacts: if
/// Android merges someone else's raw contact into one of those contacts
/// meanwhile (say, a contact that a sync brings in, with a fake's name),
/// that one stays.
///
/// Works everything out afresh from the address book, so a [previewDelete]
/// made earlier never decides what is deleted. If that would now delete
/// more than [atMost] (the number the user agreed to), deletes nothing and
/// returns null.
///
/// Deletes them [chunkSize] at a time, telling [onProgress] how far it got
/// after each chunk. Once [stopRequested] says so, it stops after the chunk
/// it is on ([DeleteResult.stopped]).
///
/// If deleting fails, reads the address book again and throws
/// [StoppedPartway] saying how far it got, unless all of that chunk were
/// deleted after all, and then it goes on. If only saving the ledger
/// fails, that is logged: entries whose raw contacts are gone do no harm.
/// An error before it starts deleting is thrown as it is.
Future<DeleteResult?> deleteFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore,
    {int? atMost,
    int chunkSize = kDeleteChunkSize,
    ProgressCallback? onProgress,
    bool Function()? stopRequested}) async {
  final check =
      await _planDelete(contacts, await ledgerStore.loadWithPending());
  final plan = check.plan;
  final ids = plan.rawContactIdsToDelete;
  final total = ids.length;
  if (atMost != null && total > atMost) {
    log("deleteFakeContacts: $total to delete, more than $atMost");
    return null;
  }
  final bChunked = total > chunkSize;
  var done = 0; // the first [done] of [ids] are deleted
  if (bChunked) onProgress?.call(0, total);
  for (var start = 0; start < total; start += chunkSize) {
    if (start > 0 && (stopRequested?.call() ?? false)) {
      log("deleteFakeContacts: stopped after $done of $total");
      break;
    }
    final chunk = ids.sublist(start, math.min(start + chunkSize, total));
    try {
      log("deleteFakeContacts: about to delete ${chunk.length} raw contact(s)");
      await contacts.deleteRawContacts(chunk);
    } catch (e, st) {
      final gone = await _countDeletedBeforeFailure(
          contacts, check, ids.sublist(0, start + chunk.length), chunk);
      if (gone == null || gone < chunk.length) {
        // What the chunks before deleted is known.
        throw StoppedPartway(
            done: gone == null ? (done > 0 ? done : null) : done + gone,
            planned: total,
            cause: e,
            stackTrace: st);
      }
      // All of them were deleted before it failed.
      logError("deleteFakeContacts, recovered", e, st);
    }
    done += chunk.length;
    if (bChunked) onProgress?.call(done, total);
  }
  final bStopped = done < total;
  try {
    // The entries of those it left alone, or didn't get to.
    await ledgerStore.save(Ledger({
      ...plan.remaining.entries,
      for (final raw in ids.skip(done)) raw: check.ledger.entries[raw]!,
    }), pending: check.pendingLeft);
  } catch (e, st) {
    logError("deleteFakeContacts, saving the ledger", e, st);
  }
  log("deleteFakeContacts: nDeleted $done");
  return DeleteResult(
    deleted: done,
    skippedMerged: plan.skippedMerged,
    skippedChanged: plan.skippedChanged,
    planned: total,
    stopped: bStopped,
  );
}

/// After deleting the raw contacts [chunk] failed: reads the address book
/// again, and returns how many of them are gone; null if that failed. (Only
/// that chunk's: a fake of a later chunk deleted meanwhile, say by a sync,
/// mustn't make up for one of this chunk that is still there.) [touched]
/// are the raw contacts it may have deleted so far, [chunk] included; those
/// of later chunks must still be there (see [_plausibleAfterFailure]).
///
/// The ledger is left as it was. Its entries for the deleted ones do no
/// harm (they are dropped when next read), and pruning it to what this
/// read finds could lose the rest if the read was wrong too (see
/// [_plausibleAfterFailure]).
Future<int?> _countDeletedBeforeFailure(ContactsGateway contacts,
    _DeleteCheck check, List<String> touched, List<String> chunk) async {
  try {
    final after = addressBookOf(await contacts.getAll());
    if (!_plausibleAfterFailure(
        allRawIds(check.book).difference(touched.toSet()), after)) {
      throw StateError("all contacts that weren't to be deleted are missing");
    }
    final present = allRawIds(after);
    return chunk.where((raw) => !present.contains(raw)).length;
  } catch (e, st) {
    logError("deleteFakeContacts, finding what was deleted", e, st);
    return null;
  }
}
