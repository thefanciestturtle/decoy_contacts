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

/// Creates every first/last name combination from [settings] that doesn't
/// already exist, and records the new raw contacts in the ledger.
Future<CreateResult> createFakeContacts(
    ContactsGateway contacts, LedgerStore ledgerStore, Settings settings) async {
  final everyone = await contacts.getAll();
  final before = addressBookOf(everyone);
  final existingFingerprints = {
    for (final c in everyone) ...fingerprintsOfContact(c),
  };
  final ledger = (await ledgerStore.load()).prunedTo(allRawIds(before));
  final wanted = allCombinations(settings.firstNames, settings.lastNames);
  LedgerEntry entry(FakeName n) =>
      entryFor(n, settings.phoneTemplate, settings.emailTemplate);
  final toCreate = namesToCreate(wanted, ledger, before,
      existingFingerprints: existingFingerprints,
      fingerprintOf: (n) => entry(n).fingerprint!);

  var nCreated = 0;
  var nUntracked = 0;
  if (toCreate.isNotEmpty) {
    final entries = [for (final n in toCreate) entry(n)];
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
        created: entries, createdContactIds: ids, before: before, after: after);
    ledger.entries.addAll(created);
    nCreated = ids.length;
    nUntracked = nCreated - created.length;
  }
  await ledgerStore.save(ledger);
  log("createFakeContacts: nCreated $nCreated");
  return CreateResult(
    created: nCreated,
    alreadyExisted: wanted.length - toCreate.length,
    untracked: nUntracked,
  );
}

/// Deletes the fake contacts this app created and recorded in the ledger.
///
/// Only contacts recorded in the ledger at creation time are deleted, never
/// anything matched by name, so real contacts with the same name are safe.
/// Each must also still have exactly the recorded name, phone and email, in
/// case its raw contact ID now belongs to someone else (see [planDelete]).
Future<DeleteResult> deleteFakeContacts(
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
  final ledger = (await ledgerStore.load())
      .prunedTo(allRawIds(book))
      .withDetailsForNameOnly((name) => current[name]);
  final plan = planDelete(ledger, book, fingerprintsByContact);
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
