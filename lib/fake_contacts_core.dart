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

/// What the app recorded about one raw contact it created.
class LedgerEntry {
  final String name;

  /// The phone number and email address the contact was created with ('' if
  /// none). Both are null for entries recorded before these were stored.
  final String? phone;
  final String? email;

  const LedgerEntry(this.name, this.phone, this.email);

  /// An entry recorded by an older version, which stored only the name.
  const LedgerEntry.nameOnly(this.name)
      : phone = null,
        email = null;

  bool get hasDetails => phone != null && email != null;

  /// Fingerprint the contact must still have to be deleted, or null if the
  /// details weren't recorded.
  String? get fingerprint =>
      hasDetails ? contactFingerprint(name, phone!, email!) : null;

  Object toJson() => {'name': name, 'phone': phone, 'email': email};

  static LedgerEntry? fromJson(Object? json) {
    if (json is String) return LedgerEntry.nameOnly(json);
    if (json is Map && json['name'] is String) {
      final phone = json['phone'], email = json['email'];
      return LedgerEntry(json['name'] as String, phone is String ? phone : null,
          email is String ? email : null);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LedgerEntry &&
      other.name == name &&
      other.phone == phone &&
      other.email == email;

  @override
  int get hashCode => Object.hash(name, phone, email);

  @override
  String toString() => 'LedgerEntry($name, $phone, $email)';
}

/// The entry for a fake contact made from [name] with the given templates.
/// An empty template means the contact gets no phone number or email.
LedgerEntry entryFor(FakeName name, String phoneTemplate, String emailTemplate) =>
    LedgerEntry(
      name.displayName,
      phoneTemplate.isEmpty ? '' : generatePhoneNumber(phoneTemplate, name.last),
      emailTemplate.isEmpty
          ? ''
          : generateEmailAddress(emailTemplate, name.first, name.last),
    );

/// Raw contacts this app created, keyed by Android raw contact ID, with the
/// name, phone number and email address each was created with.
///
/// Stored only in the app's private preferences, never in the contacts
/// themselves, so other apps reading the address book can't use it to filter
/// out the fakes. Raw contact IDs are only meaningful on the phone that
/// assigned them, so the app opts out of Android backup and device transfer
/// (see AndroidManifest.xml), and Delete also checks that each contact still
/// matches its entry.
class Ledger {
  final Map<String, LedgerEntry> entries;

  Ledger([Map<String, LedgerEntry>? entries]) : entries = {...?entries};

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  String encode() =>
      jsonEncode({for (final e in entries.entries) e.key: e.value.toJson()});

  /// Reads both the current format and the old one, which mapped each raw
  /// contact ID straight to a name.
  static Ledger decode(String? json) {
    if (json == null || json.isEmpty) return Ledger();
    try {
      final map = jsonDecode(json);
      if (map is! Map) return Ledger();
      final entries = <String, LedgerEntry>{};
      for (final e in map.entries) {
        final entry = LedgerEntry.fromJson(e.value);
        if (e.key is String && entry != null) entries[e.key as String] = entry;
      }
      return Ledger(entries);
    } on FormatException {
      return Ledger();
    }
  }

  /// A copy without entries whose raw contact no longer exists (deleted by
  /// the user, or IDs reassigned after a backup/restore).
  Ledger prunedTo(Set<String> presentRawIds) => Ledger({
        for (final e in entries.entries)
          if (presentRawIds.contains(e.key)) e.key: e.value,
      });

  /// A copy in which name-only entries from older versions get the phone and
  /// email that [expected] says a fake with that name would have (from the
  /// current settings), so Delete can check them. Entries it returns null for
  /// stay name-only, and Delete leaves their contacts alone. A wrong guess
  /// only means the contact is left alone too.
  Ledger withDetailsForNameOnly(LedgerEntry? Function(String name) expected) =>
      Ledger({
        for (final e in entries.entries)
          e.key: e.value.hasDetails ? e.value : (expected(e.value.name) ?? e.value),
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
    for (final e in ledger.entries.entries)
      if (present.contains(e.key)) e.value.name,
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
/// [created] are the entries for the contacts passed to the create call, and
/// [createdContactIds] the contact IDs it returned, in the same order. Android
/// may have merged a new raw contact into an existing contact, so only raw IDs
/// that weren't in [before] are recorded.
Map<String, LedgerEntry> newlyCreatedRawIds({
  required List<LedgerEntry> created,
  required List<String> createdContactIds,
  required AddressBook before,
  required AddressBook after,
}) {
  final old = allRawIds(before);
  final result = <String, LedgerEntry>{};
  for (var i = 0; i < created.length && i < createdContactIds.length; i++) {
    for (final raw in after[createdContactIds[i]] ?? const <String>[]) {
      if (!old.contains(raw) && !result.containsKey(raw)) {
        result[raw] = created[i];
      }
    }
  }
  return result;
}

class DeletePlan {
  /// Contacts made up entirely of raw contacts this app created, which still
  /// have exactly the name, phone number and email they were created with.
  final List<String> contactIdsToDelete;

  /// Number of tracked raw contacts deleted along with [contactIdsToDelete].
  final int rawContactsDeleted;

  /// Tracked raw contacts left alone because Android merged them into a
  /// contact that also holds data the app didn't create.
  final int skippedMerged;

  /// Tracked raw contacts left alone because their contact no longer matches
  /// what was recorded: edited since, recorded by an older version that
  /// stored only the name, or the raw contact ID now belongs to a different
  /// contact (for example if the ledger came from another phone).
  final int skippedChanged;

  /// Ledger after the deletion: only the skipped entries remain.
  final Ledger remaining;

  const DeletePlan({
    required this.contactIdsToDelete,
    required this.rawContactsDeleted,
    required this.skippedMerged,
    required this.skippedChanged,
    required this.remaining,
  });
}

/// Plans a deletion that can only remove what this app created.
///
/// A contact is deleted only if every one of its raw contacts is in the
/// ledger, and its fingerprints (see [fingerprintsOf]), given per contact ID
/// in [fingerprintsByContact], are exactly the ones recorded for those raw
/// contacts. So a contact whose name, phone numbers or email addresses differ
/// in any way from what the app created is never deleted.
DeletePlan planDelete(Ledger ledger, AddressBook book,
    Map<String, Set<String>> fingerprintsByContact) {
  final toDelete = <String>[];
  final remaining = <String, LedgerEntry>{};
  var deleted = 0;
  var skippedMerged = 0;
  var skippedChanged = 0;
  book.forEach((contactId, raws) {
    final tracked = raws.where(ledger.entries.containsKey).toList();
    if (tracked.isEmpty) return;
    void keep() {
      for (final r in tracked) {
        remaining[r] = ledger.entries[r]!;
      }
    }

    if (tracked.length != raws.length) {
      skippedMerged += tracked.length;
      keep();
      return;
    }
    final recorded = {for (final r in tracked) ledger.entries[r]!.fingerprint};
    final actual = fingerprintsByContact[contactId] ?? const <String>{};
    if (recorded.contains(null) ||
        recorded.length != actual.length ||
        !actual.containsAll(recorded)) {
      skippedChanged += tracked.length;
      keep();
      return;
    }
    toDelete.add(contactId);
    deleted += tracked.length;
  });
  return DeletePlan(
    contactIdsToDelete: toDelete,
    rawContactsDeleted: deleted,
    skippedMerged: skippedMerged,
    skippedChanged: skippedChanged,
    remaining: Ledger(remaining),
  );
}
