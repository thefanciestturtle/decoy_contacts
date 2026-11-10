// The Create and Delete operations: address book plus ledger, no UI.

import 'dart:developer';

import 'app_log.dart';
import 'contacts_gateway.dart';
import 'fake_contacts_core.dart';
import 'settings_store.dart';

class CreateResult {
  final int created;
  final int alreadyExisted;

  /// Created, but their raw contact IDs couldn't be found to record them.
  final int untracked;

  const CreateResult({
    required this.created,
    required this.alreadyExisted,
    required this.untracked,
  });
}

/// A Create or Delete that failed after it may have changed the address
/// book. The address book was read again to find out how far it got.
class StoppedPartway implements Exception {
  /// How many fake contacts it created, or deleted, before it stopped; null
  /// if that couldn't be found out.
  final int? done;

  /// How many it set out to create or delete.
  final int planned;

  /// False if the fakes a Create made were found but the ledger couldn't
  /// be saved (say, with the phone's storage full). Until the app is
  /// closed, the ledger still holds them (see [LedgerStore.save]), so
  /// Delete can still remove them.
  final bool recorded;

  /// What stopped it, and where.
  final Object cause;
  final StackTrace stackTrace;

  const StoppedPartway(
      {required this.done,
      required this.planned,
      this.recorded = true,
      required this.cause,
      required this.stackTrace});

  /// How far it got, for the log.
  String get progress => 'stopped after ${done ?? "an unknown number"} of'
      ' $planned${recorded ? '' : ', not recorded'}';

  @override
  String toString() => 'StoppedPartway: $progress: $cause';
}

/// Whether [error] (for a [StoppedPartway], what stopped it, which its text
/// includes) says the phone's storage is full: SQLite's "database or disk
/// is full", which the contacts provider passes on. Newer Android versions
/// add "(code 13 SQLITE_FULL)".
bool storageFull(Object error) {
  final text = error.toString();
  return text.contains('SQLITE_FULL') ||
      text.contains('database or disk is full');
}

class DeleteResult {
  final int deleted;
  final int skippedMerged;
  final int skippedChanged;

  const DeleteResult({
    required this.deleted,
    required this.skippedMerged,
    required this.skippedChanged,
  });
}

/// Contact ID -> raw contact IDs (Android only).
AddressBook addressBookOf(List<StoredContact> contacts) => {
      for (final c in contacts) c.id: c.rawContactIds,
    };

/// Every name/phone/email fingerprint of [c] (see [fingerprintsOf]).
Set<String> fingerprintsOfContact(StoredContact c) =>
    fingerprintsOf(c.displayName, c.phones, c.emails).toSet();

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

/// [entryFor] always fills in the phone number and email address.
FakeSample _sampleOf(LedgerEntry entry) =>
    (name: entry.name, phone: entry.phone!, email: entry.email!);

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

/// The address book, the ledger and what Create would add to them.
class _CreatePlan {
  final AddressBook before;

  /// The ledger, checked against [before].
  final Ledger ledger;

  final int wanted;

  /// Each name to create, with its ledger entry.
  final List<(FakeName, LedgerEntry)> toCreate;

  _CreatePlan(this.before, this.ledger, this.wanted, this.toCreate);

  int get alreadyExisted => wanted - toCreate.length;
}

Future<_CreatePlan> _planCreate(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final everyone = await contacts.getAll();
  final before = addressBookOf(everyone);
  final existingFingerprints = {
    for (final c in everyone) ...fingerprintsOfContact(c),
  };
  final ledger = (await ledgerStore.load()).prunedTo(allRawIds(before));
  final wanted = allCombinations(settings.firstNames, settings.lastNames);
  LedgerEntry entryOf(FakeName n) =>
      entryFor(n, settings.phoneTemplate, settings.emailTemplate);
  final toCreate = namesToCreate(wanted, ledger, before,
      existingFingerprints: existingFingerprints,
      fingerprintOf: (n) => entryOf(n).fingerprint!);
  return _CreatePlan(before, ledger, wanted.length,
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
/// If creating fails, reads the address book again to record what was
/// created, and throws [StoppedPartway] saying how far it got; unless it
/// got everything done after all (say, only looking up the new contacts
/// failed). An error before it starts creating is thrown as it is.
Future<CreateResult?> createFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings,
    {int? atMost}) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  final toCreate = plan.toCreate;
  if (atMost != null && toCreate.length > atMost) {
    log("createFakeContacts: ${toCreate.length} to create, more than $atMost");
    return null;
  }
  if (toCreate.isEmpty) {
    await ledgerStore.save(plan.ledger);
    return CreateResult(
        created: 0, alreadyExisted: plan.alreadyExisted, untracked: 0);
  }
  final newContacts = [
    for (final (name, entry) in toCreate)
      NewContact(
        first: name.first,
        last: name.last,
        phone: entry.phone!,
        email: entry.email!,
      ),
  ];
  final entries = [for (final (_, entry) in toCreate) entry];
  // From here on, contacts may have been created, so an error must not lose
  // track of them.
  try {
    log("createFakeContacts: about to call createAll for ${newContacts.length} contact(s)");
    final ids = await contacts.createAll(newContacts);
    final after = addressBookOf(await contacts.getAll(ids: ids));
    final created = newlyCreatedRawIds(
        created: entries,
        createdContactIds: ids,
        before: plan.before,
        after: after);
    await ledgerStore.save(Ledger({...plan.ledger.entries, ...created}));
    log("createFakeContacts: nCreated ${ids.length}");
    return CreateResult(
      created: ids.length,
      alreadyExisted: plan.alreadyExisted,
      untracked: ids.length - created.length,
    );
  } catch (e, st) {
    final found = await _recordCreatedBeforeFailure(
        contacts, ledgerStore, plan, entries);
    if (found != null && found.saved && found.count == entries.length) {
      // Everything was created and is now recorded; only the step after
      // failed (e.g. looking up the new contacts).
      logError("createFakeContacts, recovered", e, st);
      return CreateResult(
          created: entries.length,
          alreadyExisted: plan.alreadyExisted,
          untracked: 0);
    }
    throw StoppedPartway(
        done: found?.count,
        planned: entries.length,
        recorded: found?.saved ?? false,
        cause: e,
        stackTrace: st);
  }
}

/// After creating failed: reads the address book again, records in the
/// ledger the fakes from [entries] that were created (see
/// [createdBeforeFailure]), and returns how many, and whether saving them
/// worked; null if the address book couldn't be read.
///
/// Only adds to the ledger as stored. Nothing is dropped for not being
/// found, in case that read was wrong too: with the contacts provider
/// missing, reads find no contacts at all rather than failing.
Future<({int count, bool saved})?> _recordCreatedBeforeFailure(
    ContactsGateway contacts,
    LedgerStore ledgerStore,
    _CreatePlan plan,
    List<LedgerEntry> entries) async {
  final Map<String, LedgerEntry> created;
  try {
    final everyone = await contacts.getAll();
    created = createdBeforeFailure(
      planned: entries,
      before: plan.before,
      after: addressBookOf(everyone),
      fingerprintsByContact: {
        for (final c in everyone) c.id: fingerprintsOfContact(c),
      },
    );
  } catch (e, st) {
    logError("createFakeContacts, finding what was created", e, st);
    return null;
  }
  // Each planned fake is recorded with all of its new raw contacts.
  final count = created.values.toSet().length;
  if (created.isEmpty) return (count: 0, saved: true);
  try {
    final stored = await ledgerStore.load();
    await ledgerStore.save(Ledger({...stored.entries, ...created}));
    return (count: count, saved: true);
  } catch (e, st) {
    logError("createFakeContacts, recording what was created", e, st);
    return (count: count, saved: false);
  }
}

/// What Delete would do, and the ledger with details filled in for old
/// name-only entries.
class _DeleteCheck {
  final DeletePlan plan;

  /// The stored ledger (not pruned), with old name-only entries given the
  /// details they were checked against, and how many of them got any.
  final Ledger withDetails;
  final int detailsFilledIn;

  /// The address book the plan was made from.
  final AddressBook book;

  _DeleteCheck(this.plan, this.withDetails, this.detailsFilledIn, this.book);
}

int _nameOnlyEntries(Ledger ledger) =>
    ledger.entries.values.where((e) => !e.hasDetails).length;

/// Plans a Delete against the [stored] ledger. Old name-only entries get
/// the details the current [settings] would give a fake with that name; with
/// no [settings] they stay name-only, so they are never deleted or counted.
Future<_DeleteCheck> _planDelete(
    ContactsGateway contacts, Ledger stored, Settings? settings) async {
  final everyone = await contacts.getAll();
  final book = addressBookOf(everyone);
  final fingerprintsByContact = {
    for (final c in everyone) c.id: fingerprintsOfContact(c),
  };
  final nameOnly = _nameOnlyEntries(stored);
  final current = (nameOnly == 0 || settings == null)
      ? const <String, LedgerEntry>{}
      : {
          for (final n in allCombinations(settings.firstNames, settings.lastNames))
            n.displayName:
                entryFor(n, settings.phoneTemplate, settings.emailTemplate),
        };
  final withDetails = stored.withDetailsForNameOnly((name) => current[name]);
  final plan = planDelete(
      withDetails.prunedTo(allRawIds(book)), book, fingerprintsByContact);
  return _DeleteCheck(
      plan, withDetails, nameOnly - _nameOnlyEntries(withDetails), book);
}

DeletePreview _previewOf(DeletePlan plan) => DeletePreview(
      toDelete: plan.rawContactsDeleted,
      skippedMerged: plan.skippedMerged,
      skippedChanged: plan.skippedChanged,
    );

/// Works out what [deleteFakeContacts] would do with the same arguments.
///
/// Deletes nothing, and changes the ledger in one way only, the same way
/// Delete does: old name-only entries are saved with the phone and email
/// they were checked against. That happens even if the user then cancels or
/// there is nothing to delete, so they are never checked again against
/// different settings. (Otherwise, after the templates were changed to give
/// exactly a real contact's details, Delete would offer to delete it.) A
/// wrong guess only means that contact is always left alone.
Future<DeletePreview> previewDelete(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final check = await _planDelete(contacts, await ledgerStore.load(), settings);
  if (check.detailsFilledIn > 0) await ledgerStore.save(check.withDetails);
  return _previewOf(check.plan);
}

/// What Delete would find, for the status line: [DeletePreview.toDelete] is
/// how many fakes are still in the address book, counting only those this
/// app can confirm. Not counted, but in the skipped counts: entries that no
/// longer match what was created, fakes merged into another contact (their
/// details can't be checked, and the raw contact may not be a fake at all;
/// see [planDelete]), and old name-only entries (no guessing from the
/// settings here, so the count doesn't depend on what is being typed).
///
/// Changes nothing, not even the ledger, and doesn't read the address book
/// if the ledger is empty.
Future<DeletePreview> countFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore) async {
  final stored = await ledgerStore.load();
  if (stored.isEmpty) {
    return const DeletePreview(toDelete: 0, skippedMerged: 0, skippedChanged: 0);
  }
  return _previewOf((await _planDelete(contacts, stored, null)).plan);
}

/// Deletes the fake contacts this app created and recorded in the ledger.
///
/// Only contacts recorded in the ledger at creation time are deleted, never
/// anything matched by name, so real contacts with the same name are safe.
/// Each must also still have exactly the recorded name, phone and email, in
/// case its raw contact ID now belongs to someone else (see [planDelete]).
///
/// Works everything out afresh from the address book, so a [previewDelete]
/// made earlier never decides what is deleted. If that would now delete
/// more than [atMost] (the number the user agreed to), deletes nothing and
/// returns null.
///
/// If deleting fails, reads the address book again and throws
/// [StoppedPartway] saying how far it got; unless all were deleted (say,
/// only saving the ledger failed). An error before it starts deleting is
/// thrown as it is.
Future<DeleteResult?> deleteFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings,
    {int? atMost}) async {
  final check = await _planDelete(contacts, await ledgerStore.load(), settings);
  final plan = check.plan;
  if (atMost != null && plan.rawContactsDeleted > atMost) {
    log("deleteFakeContacts: ${plan.rawContactsDeleted} to delete, more than $atMost");
    return null;
  }
  final result = DeleteResult(
    deleted: plan.rawContactsDeleted,
    skippedMerged: plan.skippedMerged,
    skippedChanged: plan.skippedChanged,
  );
  try {
    log("deleteFakeContacts: about to call deleteAll for ${plan.contactIdsToDelete.length} contact(s)");
    await contacts.deleteAll(plan.contactIdsToDelete);
    await ledgerStore.save(plan.remaining);
  } catch (e, st) {
    final done = await _countDeletedBeforeFailure(contacts, check);
    if (done == plan.rawContactsDeleted) {
      // All were deleted; only saving the ledger failed. No harm done:
      // entries whose raw contacts are gone are dropped when next read.
      logError("deleteFakeContacts, recovered", e, st);
      return result;
    }
    throw StoppedPartway(
        done: done, planned: plan.rawContactsDeleted, cause: e, stackTrace: st);
  }
  log("deleteFakeContacts: nDeleted ${plan.rawContactsDeleted}");
  return result;
}

/// After deleting failed: reads the address book again, and returns how
/// many of the raw contacts in [check]'s plan are gone; null if that
/// failed.
///
/// The ledger is left as it was. Its entries for the deleted ones do no
/// harm (they are dropped when next read), and pruning it to what this
/// read finds could lose the rest if the read was wrong too (see
/// [_recordCreatedBeforeFailure]).
Future<int?> _countDeletedBeforeFailure(
    ContactsGateway contacts, _DeleteCheck check) async {
  try {
    final present = allRawIds(addressBookOf(await contacts.getAll()));
    return [
      for (final contactId in check.plan.contactIdsToDelete)
        ...check.book[contactId]!,
    ].where((raw) => !present.contains(raw)).length;
  } catch (e, st) {
    logError("deleteFakeContacts, finding what was deleted", e, st);
    return null;
  }
}
