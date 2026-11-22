import 'package:decoy_contacts/contacts_gateway.dart';

/// One raw contact: a single source's data for a contact.
class _Raw {
  final String id;
  String displayName;
  NameParts? nameParts;
  List<String> phones;
  List<String> emails;

  _Raw(this.id, this.displayName, this.phones, this.emails, [this.nameParts]);
}

/// A contact as a contacts app shows it, by the rule of
/// [InMemoryContactsGateway]: the first raw contact's name, and the phone
/// numbers and email addresses of all of them.
extension ShownContact on StoredContact {
  String get displayName => rawContacts.first.displayName;
  List<String> get phones => [for (final r in rawContacts) ...r.phones];
  List<String> get emails => [for (final r in rawContacts) ...r.emails];
}

/// An address book in memory, shaped like Android's: each contact is made of
/// one or more raw contacts, and raw contacts can be merged into another
/// contact.
class InMemoryContactsGateway implements ContactsGateway {
  /// Contact ID -> its raw contacts. The first raw contact gives the name.
  final Map<String, List<_Raw>> _contacts = {};
  int _nextContactId = 100;
  int _nextRawId = 1;

  /// The display name Android gives a contact created with these names.
  /// Android's order depends on the script and the phone's language: for
  /// Chinese, Japanese and Korean names it puts the family name first, with
  /// no space.
  String Function(String first, String last) androidDisplayName =
      (first, last) => '$first $last';

  /// What [requestPermission] answers.
  PermissionAnswer permission = PermissionAnswer.granted;

  /// Whether the permission is already granted, for [hasPermission]. Null
  /// means "as [permission] says"; [requestPermission] sets it.
  bool? alreadyGranted;

  /// When set, the matching call throws it.
  Object? openSettingsError;
  Object? getAllError;
  Object? createAllError;
  Object? deleteRawContactsError;

  /// With [createAllError] or [deleteRawContactsError] set, how many
  /// contacts the call creates, or raw contacts it deletes, before it
  /// throws, as when a later batch fails. Null means none; as many as there
  /// are or more, all, and it still throws.
  int? createAllStopsAfter;
  int? deleteRawContactsStopsAfter;

  /// Awaited at the start of each [createAll] or [deleteRawContacts] call,
  /// with how many calls there were before it; e.g. to hold a chunk back
  /// while a test looks at the progress, or to change the address book
  /// between Delete's check and its delete.
  Future<void> Function(int call)? beforeCreateAll;
  Future<void> Function(int call)? beforeDeleteRawContacts;

  /// Awaited once [createAll] has created its contacts, before it returns
  /// their IDs. A future that never completes acts like the app being
  /// killed: the contacts are there, but the app never learns which.
  Future<void> Function(int call)? afterCreateAll;

  /// Called for each contact [createAll] adds. Returning an existing contact
  /// ID merges the new raw contact into that contact, as Android's
  /// aggregation can do.
  String? Function(NewContact contact)? mergeInto;

  int permissionRequests = 0;
  int permissionChecks = 0;
  int openSettingsCalls = 0;
  int getAllCalls = 0;
  final List<List<NewContact>> createAllCalls = [];
  final List<List<String>> deleteRawContactsCalls = [];

  /// Adds a contact (e.g. a "real" one) and returns its contact ID.
  String add(String displayName,
      {List<String> phones = const [], List<String> emails = const []}) {
    final id = '${_nextContactId++}';
    _contacts[id] = [_Raw('${_nextRawId++}', displayName, [...phones], [...emails])];
    return id;
  }

  /// Raw contact IDs of the contact [contactId].
  List<String> rawIdsOf(String contactId) =>
      [for (final r in _contacts[contactId]!) r.id];

  /// The contact ID holding the raw contact [rawId], or null.
  String? contactOfRaw(String rawId) {
    for (final e in _contacts.entries) {
      if (e.value.any((r) => r.id == rawId)) return e.key;
    }
    return null;
  }

  /// The contact ID with this display name. Fails unless exactly one exists.
  String idOf(String displayName) {
    final ids = [
      for (final e in _contacts.entries)
        if (e.value.first.displayName == displayName) e.key,
    ];
    if (ids.length != 1) {
      throw StateError('${ids.length} contacts named $displayName');
    }
    return ids.single;
  }

  /// Moves all raw contacts of [from] into [into], as Android does when it
  /// links two contacts.
  void merge({required String into, required String from}) {
    _contacts[into]!.addAll(_contacts.remove(from)!);
  }

  /// Deletes the contact [contactId] with all its raw contacts, as the user
  /// can in the Contacts app. Not one of this gateway's calls (see
  /// [deleteRawContacts]).
  void removeContact(String contactId) {
    if (_contacts.remove(contactId) == null) {
      throw StateError('no contact $contactId');
    }
  }

  /// Changes the phone numbers of a contact (its first raw contact).
  void setPhones(String contactId, List<String> phones) {
    _contacts[contactId]!.first.phones = [...phones];
  }

  /// A raw contact ID that was never assigned.
  String unusedRawId() => '${_nextRawId++}';

  /// All contacts, read without going through the gateway's counters.
  List<StoredContact> get all => [for (final id in _contacts.keys) _toStored(id)];

  List<String> get displayNames => [for (final c in all) c.displayName];

  /// Changes the name of a raw contact, as in the Contacts app: its parts
  /// go with it.
  void rename(String rawId, String displayName) {
    _rawContact(rawId)
      ..displayName = displayName
      ..nameParts = null;
  }

  /// Changes the parts of a raw contact's name, and its display name, which
  /// Android works out from them ([androidDisplayName] for the given and
  /// family name; the prefix, middle name and suffix in the order of
  /// Western names).
  void setNameParts(String rawId, NameParts parts) {
    _rawContact(rawId)
      ..nameParts = parts
      ..displayName = parts.prefix.isEmpty &&
              parts.middle.isEmpty &&
              parts.suffix.isEmpty
          ? androidDisplayName(parts.given, parts.family)
          : parts.joined;
  }

  _Raw _rawContact(String rawId) =>
      _contacts[contactOfRaw(rawId)!]!.firstWhere((r) => r.id == rawId);

  StoredContact _toStored(String id) => StoredContact(id: id, rawContacts: [
        for (final r in _contacts[id]!)
          StoredRawContact(
            id: r.id,
            displayName: r.displayName,
            nameParts: r.nameParts,
            phones: [...r.phones],
            emails: [...r.emails],
          ),
      ]);

  @override
  Future<PermissionAnswer> requestPermission() async {
    permissionRequests++;
    alreadyGranted = permission == PermissionAnswer.granted;
    return permission;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCalls++;
    if (openSettingsError != null) throw openSettingsError!;
  }

  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    return alreadyGranted ?? permission == PermissionAnswer.granted;
  }

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    getAllCalls++;
    if (getAllError != null) throw getAllError!;
    return [
      for (final id in _contacts.keys)
        if (ids == null || ids.contains(id)) _toStored(id),
    ];
  }

  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    final call = createAllCalls.length;
    createAllCalls.add(contacts);
    await beforeCreateAll?.call(call);
    final error = createAllError;
    if (error != null && createAllStopsAfter == null) throw error;
    final ids = <String>[];
    for (final (i, c) in contacts.indexed) {
      // The plugin doesn't return the IDs of what it created before failing.
      if (error != null && i == createAllStopsAfter) throw error;
      final raw = _Raw(
          '${_nextRawId++}',
          androidDisplayName(c.first, c.last),
          [if (c.phone.isNotEmpty) c.phone],
          [if (c.email.isNotEmpty) c.email],
          NameParts(given: c.first, family: c.last));
      final target = mergeInto?.call(c);
      if (target != null) {
        _contacts[target]!.add(raw);
        ids.add(target);
      } else {
        final id = '${_nextContactId++}';
        _contacts[id] = [raw];
        ids.add(id);
      }
    }
    if (error != null) throw error;
    await afterCreateAll?.call(call);
    return ids;
  }

  /// As on Android: a contact left with no raw contacts goes too, and IDs
  /// of raw contacts that are gone are passed over.
  @override
  Future<void> deleteRawContacts(List<String> rawContactIds) async {
    final call = deleteRawContactsCalls.length;
    deleteRawContactsCalls.add(rawContactIds);
    await beforeDeleteRawContacts?.call(call);
    final error = deleteRawContactsError;
    if (error != null && deleteRawContactsStopsAfter == null) throw error;
    for (final (i, rawId) in rawContactIds.indexed) {
      if (error != null && i == deleteRawContactsStopsAfter) throw error;
      final contactId = contactOfRaw(rawId);
      if (contactId == null) continue;
      final raws = _contacts[contactId]!..removeWhere((r) => r.id == rawId);
      if (raws.isEmpty) _contacts.remove(contactId);
    }
    if (error != null) throw error;
  }
}
