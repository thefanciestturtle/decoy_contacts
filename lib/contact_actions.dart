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
Future<CreateResult?> createFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings,
    {int? atMost}) async {
  final plan = await _planCreate(contacts, ledgerStore, settings);
  final toCreate = plan.toCreate;
  if (atMost != null && toCreate.length > atMost) {
    log("createFakeContacts: ${toCreate.length} to create, more than $atMost");
    return null;
  }
  final ledger = plan.ledger;

  var nCreated = 0;
  var nUntracked = 0;
  if (toCreate.isNotEmpty) {
    final newContacts = [
      for (final (name, entry) in toCreate)
        NewContact(
          first: name.first,
          last: name.last,
          phone: entry.phone!,
          email: entry.email!,
        ),
    ];
    log("createFakeContacts: about to call createAll for ${newContacts.length} contact(s)");
    final ids = await contacts.createAll(newContacts);
    final after = addressBookOf(await contacts.getAll(ids: ids));
    final created = newlyCreatedRawIds(
        created: [for (final (_, entry) in toCreate) entry],
        createdContactIds: ids,
        before: plan.before,
        after: after);
    ledger.entries.addAll(created);
    nCreated = ids.length;
    nUntracked = nCreated - created.length;
  }
  await ledgerStore.save(ledger);
  log("createFakeContacts: nCreated $nCreated");
  return CreateResult(
    created: nCreated,
    alreadyExisted: plan.alreadyExisted,
    untracked: nUntracked,
  );
}

/// What Delete would do, and the ledger with details filled in for old
/// name-only entries.
class _DeleteCheck {
  final DeletePlan plan;

  /// The stored ledger (not pruned), with old name-only entries given the
  /// details they were checked against, and how many of them got any.
  final Ledger withDetails;
  final int detailsFilledIn;

  _DeleteCheck(this.plan, this.withDetails, this.detailsFilledIn);
}

int _nameOnlyEntries(Ledger ledger) =>
    ledger.entries.values.where((e) => !e.hasDetails).length;

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
  final withDetails = stored.withDetailsForNameOnly((name) => current[name]);
  final plan = planDelete(
      withDetails.prunedTo(allRawIds(book)), book, fingerprintsByContact);
  return _DeleteCheck(plan, withDetails,
      _nameOnlyEntries(stored) - _nameOnlyEntries(withDetails));
}

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
  final check = await _planDelete(contacts, ledgerStore, settings);
  if (check.detailsFilledIn > 0) await ledgerStore.save(check.withDetails);
  final plan = check.plan;
  return DeletePreview(
    toDelete: plan.rawContactsDeleted,
    skippedMerged: plan.skippedMerged,
    skippedChanged: plan.skippedChanged,
  );
}

/// How many of the fakes this app created are still in the address book, as
/// far as it can tell: the ones Delete would delete, plus those Android
/// merged into another contact. Entries that no longer match what was
/// created aren't counted, since their raw contact may not be a fake at all
/// (see [planDelete]). Changes nothing, not even the ledger.
Future<int> countFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final plan = (await _planDelete(contacts, ledgerStore, settings)).plan;
  return plan.rawContactsDeleted + plan.skippedMerged;
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
Future<DeleteResult?> deleteFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings,
    {int? atMost}) async {
  final plan = (await _planDelete(contacts, ledgerStore, settings)).plan;
  if (atMost != null && plan.rawContactsDeleted > atMost) {
    log("deleteFakeContacts: ${plan.rawContactsDeleted} to delete, more than $atMost");
    return null;
  }
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
