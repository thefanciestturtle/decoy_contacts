// Pure logic for generating, tracking and safely deleting fake contacts.
// Kept free of Flutter and plugin imports so it can be unit tested directly.

import 'dart:convert';

/// UK Ofcom range reserved for TV/film drama use: +44 7700 900000..900999.
/// These numbers are never assigned to real subscribers.
const String kDefaultPhoneTemplate = '+447700900nnn';

/// Default used up to v1.8. "+213..." is Algeria's country code, so these
/// numbers could belong to real people. Migrated to [kDefaultPhoneTemplate].
const String kLegacyDefaultPhoneTemplate = '+2134567nnnn';

const String kDefaultEmailTemplate = 'FIRST.LAST@example.com';

/// SharedPreferences key holding the ledger of raw contacts this app created.
const String kLedgerPrefsKey = 'fakeRawContactLedgerV1';

/// Splits a comma-separated list of names, trimming whitespace and dropping
/// empty entries and duplicates (keeping first-seen order).
List<String> parseNames(String csv) {
  final seen = <String>{};
  final names = <String>[];
  for (final part in csv.split(',')) {
    final name = part.trim();
    if (name.isNotEmpty && seen.add(name)) names.add(name);
  }
  return names;
}

/// Replaces each 'n' in [template] with a digit derived from successive
/// characters of [lastName] (character code mod 10), or '0' once the name
/// runs out. Deterministic, so the same names give the same numbers on every
/// phone.
String generatePhoneNumber(String template, String lastName) {
  final out = StringBuffer();
  var next = 0;
  for (var i = 0; i < template.length; i++) {
    final ch = template[i];
    if (ch != 'n') {
      out.write(ch);
    } else if (next >= lastName.length) {
      out.write('0');
    } else {
      out.write(lastName.codeUnitAt(next) % 10);
      next++;
    }
  }
  return out.toString();
}

String generateEmailAddress(String template, String firstName, String lastName) {
  return template.replaceAll('FIRST', firstName).replaceAll('LAST', lastName);
}

class FakeName {
  final String first;
  final String last;

  const FakeName(this.first, this.last);

  String get displayName => '$first $last';

  @override
  bool operator ==(Object other) =>
      other is FakeName && other.first == first && other.last == last;

  @override
  int get hashCode => Object.hash(first, last);

  @override
  String toString() => displayName;
}

/// Every first-name/last-name combination, grouped by last name.
List<FakeName> allCombinations(List<String> firstNames, List<String> lastNames) {
  return [
    for (final last in lastNames)
      for (final first in firstNames) FakeName(first, last),
  ];
}

/// Raw contacts this app created, keyed by Android raw contact ID, with the
/// display name each was created with.
///
/// Stored only in the app's private preferences, never in the contacts
/// themselves, so other apps reading the address book can't use it to filter
/// out the fakes.
class Ledger {
  final Map<String, String> rawIdToName;

  Ledger([Map<String, String>? entries]) : rawIdToName = {...?entries};

  bool get isEmpty => rawIdToName.isEmpty;
  int get length => rawIdToName.length;

  String encode() => jsonEncode(rawIdToName);

  static Ledger decode(String? json) {
    if (json == null || json.isEmpty) return Ledger();
    try {
      final map = jsonDecode(json);
      if (map is! Map) return Ledger();
      return Ledger({
        for (final e in map.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      });
    } on FormatException {
      return Ledger();
    }
  }

  /// A copy without entries whose raw contact no longer exists (deleted by
  /// the user, or IDs reassigned after a backup/restore).
  Ledger prunedTo(Set<String> presentRawIds) => Ledger({
        for (final e in rawIdToName.entries)
          if (presentRawIds.contains(e.key)) e.key: e.value,
      });
}

/// Snapshot of the address book: contact (aggregate) ID -> its raw contact IDs.
typedef AddressBook = Map<String, List<String>>;

Set<String> allRawIds(AddressBook book) => {
      for (final raws in book.values) ...raws,
    };

String _normalizePhone(String phone) => phone.replaceAll(RegExp(r'[^0-9+]'), '');

/// Identifies a contact by its display name, one phone number and one email
/// address (either may be empty).
String contactFingerprint(String displayName, String phone, String email) =>
    '$displayName\u0000${_normalizePhone(phone)}\u0000${email.trim().toLowerCase()}';

/// Every fingerprint an existing contact matches: one per phone/email pair.
Iterable<String> fingerprintsOf(
    String displayName, List<String> phones, List<String> emails) sync* {
  for (final p in phones.isEmpty ? const [''] : phones) {
    for (final e in emails.isEmpty ? const [''] : emails) {
      yield contactFingerprint(displayName, p, e);
    }
  }
}

/// Names from [wanted] that don't already exist. Makes "Create" idempotent.
///
/// A name is skipped if it's a tracked fake that's still present, or if some
/// contact already has exactly the name, phone and email this name would be
/// created with (listed in [existingFingerprints], matched via
/// [fingerprintOf]). The second check stops a duplicate set appearing even
/// if the ledger is lost, e.g. after the app's data is cleared. It only
/// prevents creation; deletion never relies on it.
List<FakeName> namesToCreate(
  List<FakeName> wanted,
  Ledger ledger,
  AddressBook book, {
  Set<String> existingFingerprints = const {},
  String Function(FakeName)? fingerprintOf,
}) {
  final present = allRawIds(book);
  final existing = {
    for (final e in ledger.rawIdToName.entries)
      if (present.contains(e.key)) e.value,
  };
  return [
    for (final n in wanted)
      if (!existing.contains(n.displayName) &&
          !(fingerprintOf != null &&
              existingFingerprints.contains(fingerprintOf(n))))
        n,
  ];
}

/// Works out which raw contacts were just created.
///
/// [created] are the names passed to the create call, and [createdContactIds]
/// the contact IDs it returned, in the same order. Android may have merged a
/// new raw contact into an existing contact, so only raw IDs that weren't in
/// [before] are recorded.
Map<String, String> newlyCreatedRawIds({
  required List<FakeName> created,
  required List<String> createdContactIds,
  required AddressBook before,
  required AddressBook after,
}) {
  final old = allRawIds(before);
  final result = <String, String>{};
  for (var i = 0; i < created.length && i < createdContactIds.length; i++) {
    for (final raw in after[createdContactIds[i]] ?? const <String>[]) {
      if (!old.contains(raw) && !result.containsKey(raw)) {
        result[raw] = created[i].displayName;
      }
    }
  }
  return result;
}

class DeletePlan {
  /// Contacts made up entirely of raw contacts this app created.
  final List<String> contactIdsToDelete;

  /// Number of tracked raw contacts deleted along with [contactIdsToDelete].
  final int rawContactsDeleted;

  /// Tracked raw contacts left alone because Android merged them into a
  /// contact that also holds data the app didn't create.
  final int skippedMerged;

  /// Ledger after the deletion: only the skipped entries remain.
  final Ledger remaining;

  const DeletePlan({
    required this.contactIdsToDelete,
    required this.rawContactsDeleted,
    required this.skippedMerged,
    required this.remaining,
  });
}

/// Plans a deletion that can only remove what this app created. A contact
/// is deleted only if every one of its raw contacts is in the ledger.
DeletePlan planDelete(Ledger ledger, AddressBook book) {
  final toDelete = <String>[];
  final remaining = <String, String>{};
  var deleted = 0;
  var skipped = 0;
  book.forEach((contactId, raws) {
    final tracked = raws.where(ledger.rawIdToName.containsKey).toList();
    if (tracked.isEmpty) return;
    if (tracked.length == raws.length) {
      toDelete.add(contactId);
      deleted += tracked.length;
    } else {
      skipped += tracked.length;
      for (final r in tracked) {
        remaining[r] = ledger.rawIdToName[r]!;
      }
    }
  });
  return DeletePlan(
    contactIdsToDelete: toDelete,
    rawContactsDeleted: deleted,
    skippedMerged: skipped,
    remaining: Ledger(remaining),
  );
}
