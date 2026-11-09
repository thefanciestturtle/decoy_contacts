// The Create and Delete operations: address book plus ledger, no UI.

import 'dart:developer';

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

  /// The ledger as stored, and as checked against the address book.
  final Ledger stored;
  final Ledger ledger;

  final int wanted;
  final List<FakeName> toCreate;

  /// The ledger entry for each of [toCreate], in the same order.
  final List<LedgerEntry> entries;

  _CreatePlan(this.before, this.stored, this.ledger, this.wanted,
      this.toCreate, this.entries);
}

/// Saves [checked] if it differs from the [stored] ledger it came from.
Future<void> _saveIfChanged(
    LedgerStore ledgerStore, Ledger stored, Ledger checked) async {
  if (checked.encode() != stored.encode()) await ledgerStore.save(checked);
}

Future<_CreatePlan> _planCreate(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final everyone = await contacts.getAll();
  final before = addressBookOf(everyone);
  final existingFingerprints = {
    for (final c in everyone) ...fingerprintsOfContact(c),
  };
  final stored = await ledgerStore.load();
  final ledger = stored.prunedTo(allRawIds(before));
  final wanted = allCombinations(settings.firstNames, settings.lastNames);
  LedgerEntry entryOf(FakeName n) =>
      entryFor(n, settings.phoneTemplate, settings.emailTemplate);
  final toCreate = namesToCreate(wanted, ledger, before,
      existingFingerprints: existingFingerprints,
      fingerprintOf: (n) => entryOf(n).fingerprint!);
  return _CreatePlan(before, stored, ledger, wanted.length, toCreate,
      [for (final n in toCreate) entryOf(n)]);
}

/// Works out what [createFakeContacts] would do with the same arguments.
///
/// Creates nothing. Like Create, it drops ledger entries for raw contacts
/// that no longer exist, so that happens even if the user then cancels or
/// there is nothing to create.
Future<CreatePreview> previewCreate(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  await _saveIfChanged(ledgerStore, plan.stored, plan.ledger);
  return CreatePreview(
    toCreate: plan.toCreate.length,
    alreadyExisted: plan.wanted - plan.toCreate.length,
  );
}

/// Creates every first/last name combination from [settings] that doesn't
/// already exist, and records the new raw contacts in the ledger.
///
/// Works everything out afresh from the address book, so a [previewCreate]
/// made earlier is only a forecast of the result.
Future<CreateResult> createFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  final toCreate = plan.toCreate;
  final ledger = plan.ledger;

  var nCreated = 0;
  var nUntracked = 0;
  if (toCreate.isNotEmpty) {
    final entries = plan.entries;
    final newContacts = [
      for (var i = 0; i < toCreate.length; i++)
        NewContact(
          first: toCreate[i].first,
          last: toCreate[i].last,
          phone: entries[i].phone!,
          email: entries[i].email!,
        ),
    ];
    log("createFakeContacts: about to call createAll for ${newContacts.length} contact(s)");
    final ids = await contacts.createAll(newContacts);
    final after = addressBookOf(await contacts.getAll(ids: ids));
    final created = newlyCreatedRawIds(
        created: entries, createdContactIds: ids, before: plan.before, after: after);
    ledger.entries.addAll(created);
    nCreated = ids.length;
    nUntracked = nCreated - created.length;
  }
  await ledgerStore.save(ledger);
  log("createFakeContacts: nCreated $nCreated");
  return CreateResult(
    created: nCreated,
    alreadyExisted: plan.wanted - toCreate.length,
    untracked: nUntracked,
  );
}

/// The ledger as stored, as checked against the address book, and what
/// Delete would do.
typedef _DeleteCheck = ({Ledger stored, Ledger checked, DeletePlan plan});

Future<_DeleteCheck> _planDelete(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final everyone = await contacts.getAll();
  final book = addressBookOf(everyone);
  final fingerprintsByContact = {
    for (final c in everyone) c.id: fingerprintsOfContact(c),
  };
  // Entries from older versions hold only a name: expect the phone and
  // email the current settings would give a fake with that name.
  final current = {
    for (final n in allCombinations(settings.firstNames, settings.lastNames))
      n.displayName: entryFor(n, settings.phoneTemplate, settings.emailTemplate),
  };
  final stored = await ledgerStore.load();
  final checked = stored
      .prunedTo(allRawIds(book))
      .withDetailsForNameOnly((name) => current[name]);
  return (
    stored: stored,
    checked: checked,
    plan: planDelete(checked, book, fingerprintsByContact),
  );
}

/// Works out what [deleteFakeContacts] would do with the same arguments.
///
/// Deletes nothing. Like Delete, it drops ledger entries for raw contacts
/// that no longer exist and saves old name-only entries with the details
/// they were checked against, so that happens even if the user then cancels
/// or there is nothing to delete. (Otherwise those entries would be checked
/// against whatever the settings say at the next Delete.)
Future<DeletePreview> previewDelete(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final (:stored, :checked, :plan) =
      await _planDelete(contacts, ledgerStore, settings);
  await _saveIfChanged(ledgerStore, stored, checked);
  return DeletePreview(
    toDelete: plan.rawContactsDeleted,
    skippedMerged: plan.skippedMerged,
    skippedChanged: plan.skippedChanged,
  );
}

/// Deletes the fake contacts this app created and recorded in the ledger.
///
/// Only contacts recorded in the ledger at creation time are deleted, never
/// anything matched by name, so real contacts with the same name are safe.
/// Each must also still have exactly the recorded name, phone and email, in
/// case its raw contact ID now belongs to someone else (see [planDelete]).
///
/// Works everything out afresh from the address book, so a [previewDelete]
/// made earlier never decides what is deleted.
Future<DeleteResult> deleteFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final (:plan, stored: _, checked: _) =
      await _planDelete(contacts, ledgerStore, settings);
  log("deleteFakeContacts: about to call deleteAll for ${plan.contactIdsToDelete.length} contact(s)");
  await contacts.deleteAll(plan.contactIdsToDelete);
  await ledgerStore.save(plan.remaining);
  log("deleteFakeContacts: nDeleted ${plan.rawContactsDeleted}");
  return DeleteResult(
    deleted: plan.rawContactsDeleted,
    skippedMerged: plan.skippedMerged,
    skippedChanged: plan.skippedChanged,
  );
}
