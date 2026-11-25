// Pure logic for generating, tracking and safely deleting fake contacts.
// Kept free of Flutter and plugin imports so it can be unit tested directly.

import 'dart:convert';

/// UK Ofcom range reserved for TV/film drama use: +44 7700 900000..900999.
/// These numbers are never assigned to real subscribers.
const String kDefaultPhoneTemplate = '+447700900nnn';

const String kDefaultEmailTemplate = 'FIRST.LAST@example.com';

/// SharedPreferences key holding the ledger of raw contacts this app created.
const String kLedgerPrefsKey = 'fakeRawContactLedgerV1';

/// Where in the ledger's JSON a [PendingCreate] is kept. Not a number, so
/// never a raw contact ID.
const String kPendingCreateKey = 'pendingCreate';

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

final RegExp _emailPlaceholder = RegExp('FIRST|LAST');

/// Replaces each FIRST in [template] with [firstName] and each LAST with
/// [lastName], in one pass, so a name that itself contains FIRST or LAST
/// (say "BLAST") is left as it is.
String generateEmailAddress(String template, String firstName, String lastName) {
  return template.replaceAllMapped(
      _emailPlaceholder, (m) => m[0] == 'FIRST' ? firstName : lastName);
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

/// The first of [allCombinations], without building them all: the first
/// first name with the first last name. Null if either list is empty.
FakeName? firstCombination(List<String> firstNames, List<String> lastNames) =>
    firstNames.isEmpty || lastNames.isEmpty
        ? null
        : FakeName(firstNames.first, lastNames.first);

/// Every first-name/last-name combination, grouped by last name. Starts
/// with [firstCombination].
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
  /// none).
  final String phone;
  final String email;

  const LedgerEntry(this.name, this.phone, this.email);

  /// Fingerprint the contact must still have to be deleted.
  String get fingerprint => contactFingerprint(name, phone, email);

  Object toJson() => {'name': name, 'phone': phone, 'email': email};

  /// Null unless [json] has the name, phone and email, all as strings.
  /// Anything else (say, an entry with only a name, as early test builds
  /// stored them) can't be checked, so it is dropped (see [Ledger.decode]).
  static LedgerEntry? fromJson(Object? json) {
    if (json case {
          'name': final String name,
          'phone': final String phone,
          'email': final String email,
        }) {
      return LedgerEntry(name, phone, email);
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
/// (see AndroidManifest.xml), and Delete also checks that each raw contact
/// still matches its entry.
class Ledger {
  final Map<String, LedgerEntry> entries;

  Ledger([Map<String, LedgerEntry>? entries]) : entries = {...?entries};

  bool get isEmpty => entries.isEmpty;
  int get length => entries.length;

  /// The ledger as JSON, with [pending] (see [PendingCreate]) if given.
  String encode({PendingCreate? pending}) => jsonEncode({
        for (final e in entries.entries) e.key: e.value.toJson(),
        if (pending != null) kPendingCreateKey: pending.toJson(),
      });

  /// Reads a ledger written by [encode]. An entry it can't read (see
  /// [LedgerEntry.fromJson]) is dropped, as unreadable JSON is, so Delete
  /// never acts on it: its raw contact then isn't this app's, and a contact
  /// that holds it is left alone (see [planDelete]). The next save leaves it
  /// out.
  static Ledger decode(String? json) => decodeWithPending(json).ledger;

  /// [decode], and the [PendingCreate] saved with it, if any.
  static ({Ledger ledger, PendingCreate? pending}) decodeWithPending(
      String? json) {
    if (json == null || json.isEmpty) return (ledger: Ledger(), pending: null);
    try {
      final map = jsonDecode(json);
      if (map is! Map) return (ledger: Ledger(), pending: null);
      final entries = <String, LedgerEntry>{};
      for (final e in map.entries) {
        if (e.key == kPendingCreateKey) continue;
        final entry = LedgerEntry.fromJson(e.value);
        if (e.key is String && entry != null) entries[e.key as String] = entry;
      }
      return (
        ledger: Ledger(entries),
        pending: PendingCreate.fromJson(map[kPendingCreateKey]),
      );
    } on FormatException {
      return (ledger: Ledger(), pending: null);
    }
  }

  /// A copy without entries whose raw contact no longer exists (deleted by
  /// the user, or IDs reassigned after a backup/restore).
  Ledger prunedTo(Set<String> presentRawIds) => Ledger({
        for (final e in entries.entries)
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
/// A name is skipped if it's a tracked fake that's still present (in [book],
/// or among [alsoPresent]: raw contacts known to exist that a read of the
/// address book missed), or if some raw contact already has exactly the
/// name, phone and email this name would be created with (listed in [existingFingerprints], matched via
/// [fingerprintOf]). The second check stops a duplicate set appearing even
/// if the ledger is lost, e.g. after the app's data is cleared. It only
/// prevents creation; deletion never relies on it.
List<FakeName> namesToCreate(
  List<FakeName> wanted,
  Ledger ledger,
  AddressBook book, {
  Set<String> alsoPresent = const {},
  Set<String> existingFingerprints = const {},
  String Function(FakeName)? fingerprintOf,
}) {
  final present = {...allRawIds(book), ...alsoPresent};
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

/// Works out which raw contacts were just created, and which fake each is.
///
/// [created] are the entries for the contacts passed to the create call, and
/// [createdContactIds] the contact IDs it returned, in the same order. Only
/// raw contacts that aren't in [oldRawIds] (those that existed before) are
/// new: Android may have merged a fake into an existing contact.
///
/// A contact the call gave for one fake that holds one new raw contact holds
/// that fake. The other fakes are found among the new raw contacts in
/// [after] by their own name, phone and email ([fingerprintsByRaw] gives each
/// raw contact's fingerprints), by the rule of [createdBeforeFailure]: when
/// Android merged fakes with each other, or a fake with a raw contact added
/// meanwhile, or moved a fake into the contact of another one of the call.
/// Those it can't tell apart are left out.
Map<String, LedgerEntry> newlyCreatedRawIds({
  required List<LedgerEntry> created,
  required List<String> createdContactIds,
  required Set<String> oldRawIds,
  required AddressBook after,
  required Map<String, Set<String>> fingerprintsByRaw,
}) {
  // The fakes the call put in each contact.
  final createdIn = <String, List<LedgerEntry>>{};
  for (var i = 0; i < created.length && i < createdContactIds.length; i++) {
    (createdIn[createdContactIds[i]] ??= []).add(created[i]);
  }
  final result = <String, LedgerEntry>{};
  createdIn.forEach((contactId, entries) {
    final added = [
      for (final r in after[contactId] ?? const <String>[])
        if (!oldRawIds.contains(r)) r,
    ];
    if (entries.length == 1 && added.length == 1) {
      result[added.single] = entries.single;
    }
  });
  final unmatched = entriesNotFound(
      created.take(createdContactIds.length).toList(), result.values);
  if (unmatched.isNotEmpty) {
    // The call gave a contact ID for each, so it made them all.
    result.addAll(createdBeforeFailure(
        planned: unmatched,
        oldRawIds: {...oldRawIds, ...result.keys},
        after: after,
        fingerprintsByRaw: fingerprintsByRaw,
        allCreated: true));
  }
  return result;
}

/// Works out which raw contacts a create call made before it failed, as it
/// then doesn't say (the IDs of what it did create are lost).
///
/// [planned] are the entries for the contacts passed to the create call. A
/// raw contact in [after] that isn't in [oldRawIds] (those that existed
/// before) is taken for the fake of a planned entry if it has exactly that
/// entry's name, phone and email: [fingerprintsByRaw] gives each raw
/// contact's own fingerprints (see [fingerprintsOf]). Which contact holds it
/// doesn't matter: Android may have merged it with another.
///
/// It is left out if it matches several planned entries, or if another new
/// raw contact matches the same entry (say, a copy synced from another phone
/// meanwhile): which one this app created can't be told then. Left out, it
/// is only skipped by Create and never deleted.
///
/// Two planned fakes can have the same name, phone and email, as names can
/// hold spaces: "A B" "C" and "A" "B C". If the call is known to have made
/// [allCreated] of them, an entry can be taken by as many new raw contacts
/// as there are planned fakes with it (which of them is which doesn't
/// matter). Otherwise, after a failure, such fakes are left out, as a copy
/// synced meanwhile could be taken for one the call didn't make.
Map<String, LedgerEntry> createdBeforeFailure({
  required List<LedgerEntry> planned,
  required Set<String> oldRawIds,
  required AddressBook after,
  required Map<String, Set<String>> fingerprintsByRaw,
  bool allCreated = false,
}) {
  // Planned fingerprint -> its entry, and how many planned fakes have it.
  final byFingerprint = <String, LedgerEntry>{};
  final plannedCount = <String, int>{};
  for (final e in planned) {
    byFingerprint[e.fingerprint] = e;
    plannedCount[e.fingerprint] = (plannedCount[e.fingerprint] ?? 0) + 1;
  }
  // Planned fingerprint -> the new raw contacts that have it, and new raw
  // contact -> the planned fingerprints it has.
  final matches = <String, List<String>>{};
  final found = <String, List<String>>{};
  for (final raw in allRawIds(after)) {
    if (oldRawIds.contains(raw)) continue;
    final fingerprints = [
      for (final f in fingerprintsByRaw[raw] ?? const <String>{})
        if (byFingerprint.containsKey(f)) f,
    ];
    found[raw] = fingerprints;
    for (final f in fingerprints) {
      (matches[f] ??= []).add(raw);
    }
  }
  return {
    for (final MapEntry(key: raw, value: fingerprints) in found.entries)
      if (fingerprints.length == 1 &&
          matches[fingerprints.single]!.length <=
              (allCreated ? plannedCount[fingerprints.single]! : 1))
        raw: byFingerprint[fingerprints.single]!,
  };
}

/// The entries of [entries] that none of [found] stands for. Equal entries
/// count one by one: two fakes with the same name, phone and email need two
/// raw contacts (see [createdBeforeFailure]).
List<LedgerEntry> entriesNotFound(
    List<LedgerEntry> entries, Iterable<LedgerEntry> found) {
  final left = <LedgerEntry, int>{};
  for (final e in found) {
    left[e] = (left[e] ?? 0) + 1;
  }
  final notFound = <LedgerEntry>[];
  for (final e in entries) {
    final n = left[e] ?? 0;
    if (n > 0) {
      left[e] = n - 1;
    } else {
      notFound.add(e);
    }
  }
  return notFound;
}

/// The highest of [rawIds] as a number, or null if there are none (or none
/// is a number).
int? maxRawIdOf(Iterable<String> rawIds) {
  int? max;
  for (final r in rawIds) {
    final n = int.tryParse(r);
    if (n != null && (max == null || n > max)) max = n;
  }
  return max;
}

/// The fakes a Create is about to make in one create call, saved with the
/// ledger before the call (see LedgerStore.save). If the app is killed
/// meanwhile, Android still finishes the call, but the app never learns
/// which raw contacts it made; the next Create, Delete or count finds them
/// with [createdByPending].
class PendingCreate {
  /// The highest raw contact ID in the address book before the call, as far
  /// as the app knows; null if there were none.
  final int? maxRawId;

  final List<LedgerEntry> entries;

  const PendingCreate({required this.maxRawId, required this.entries});

  Object toJson() => {
        'maxRawId': maxRawId,
        'entries': [for (final e in entries) e.toJson()],
      };

  /// Null if [json] isn't one (entries it can't read are dropped: see
  /// [LedgerEntry.fromJson]).
  static PendingCreate? fromJson(Object? json) {
    if (json is! Map || json['entries'] is! List) return null;
    final max = json['maxRawId'];
    return PendingCreate(
      maxRawId: max is int ? max : null,
      entries: [
        for (final e in json['entries'] as List) ?LedgerEntry.fromJson(e),
      ],
    );
  }
}

/// The raw contacts in [after] that [pending]'s create call made, by the
/// rule of [createdBeforeFailure]. Raw contacts in [recorded] (the ledger)
/// and those not newer than [PendingCreate.maxRawId] existed before it, so
/// they are never taken for its fakes. (A raw contact ID that isn't a number
/// counts as old.)
///
/// Raw contact IDs only grow (SQLite's AUTOINCREMENT); if they didn't, a
/// fake could look old and only be left unrecorded, never the other way
/// round: every raw contact that existed before the call has an ID up to
/// [PendingCreate.maxRawId].
Map<String, LedgerEntry> createdByPending(
  PendingCreate pending, {
  required Set<String> recorded,
  required AddressBook after,
  required Map<String, Set<String>> fingerprintsByRaw,
}) {
  final max = pending.maxRawId;
  bool isNew(String raw) {
    final n = int.tryParse(raw);
    return n != null && (max == null || n > max);
  }

  return createdBeforeFailure(
    planned: pending.entries,
    oldRawIds: {
      ...recorded,
      for (final r in allRawIds(after))
        if (!isNew(r)) r,
    },
    after: after,
    fingerprintsByRaw: fingerprintsByRaw,
  );
}

class DeletePlan {
  /// The raw contacts of the contacts made up entirely of raw contacts this
  /// app created, each of which still has exactly the name, phone number
  /// and email it was created with. Delete deletes these raw contacts, not
  /// their contacts: by then, Android may have merged another raw contact
  /// into one of them.
  final List<String> rawContactIdsToDelete;

  /// How many fakes it deletes: one per raw contact.
  int get rawContactsDeleted => rawContactIdsToDelete.length;

  /// Tracked raw contacts left alone because Android merged them into a
  /// contact that also holds data the app didn't create: a raw contact that
  /// isn't the app's, or another fake that no longer matches.
  final int skippedMerged;

  /// Tracked raw contacts left alone because they no longer match what was
  /// recorded: edited since, or the raw contact ID now belongs to a
  /// different contact (for example if the ledger came from another phone).
  final int skippedChanged;

  /// Ledger after the deletion: only the skipped entries remain.
  final Ledger remaining;

  const DeletePlan({
    required this.rawContactIdsToDelete,
    required this.skippedMerged,
    required this.skippedChanged,
    required this.remaining,
  });
}

/// Plans a deletion that can only remove what this app created.
///
/// A contact's fakes are deleted only if every one of its raw contacts is in
/// the ledger and has exactly the name, phone and email recorded for it: its
/// own fingerprints (see [fingerprintsOf]), given per raw contact ID in
/// [fingerprintsByRaw], must be just the recorded one. So the fakes of a
/// contact that holds a raw contact the app didn't create, or a name, phone
/// number or email address that differs in any way from what the app
/// created, are never deleted. (Other details, such as a note added to a
/// fake, aren't checked.) Each raw contact is checked on its own, so the
/// fakes of a contact into which Android merged several of them are deleted
/// too.
///
/// A fake left alone counts as merged if its contact holds a raw contact
/// that isn't the app's (whether or not the fake itself changed), or a fake
/// that changed while it didn't; and as changed if it no longer matches in
/// a contact made only of the app's fakes.
DeletePlan planDelete(Ledger ledger, AddressBook book,
    Map<String, Set<String>> fingerprintsByRaw) {
  final toDelete = <String>[];
  final remaining = <String, LedgerEntry>{};
  var skippedMerged = 0;
  var skippedChanged = 0;
  book.forEach((_, raws) {
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
    bool unchanged(String raw) {
      final actual = fingerprintsByRaw[raw] ?? const <String>{};
      return actual.length == 1 &&
          actual.single == ledger.entries[raw]!.fingerprint;
    }

    final changed = tracked.where((r) => !unchanged(r)).length;
    if (changed > 0) {
      // The fakes that are unchanged were merged with one that isn't.
      skippedChanged += changed;
      skippedMerged += tracked.length - changed;
      keep();
      return;
    }
    toDelete.addAll(tracked);
  });
  return DeletePlan(
    rawContactIdsToDelete: toDelete,
    skippedMerged: skippedMerged,
    skippedChanged: skippedChanged,
    remaining: Ledger(remaining),
  );
}
