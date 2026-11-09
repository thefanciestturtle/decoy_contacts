import 'package:fake_contacts/contacts_gateway.dart';

/// One raw contact: a single source's data for a contact.
class _Raw {
  final String id;
  String displayName;
  List<String> phones;
  List<String> emails;

  _Raw(this.id, this.displayName, this.phones, this.emails);
}

/// An address book in memory, shaped like Android's: each contact is made of
/// one or more raw contacts, and raw contacts can be merged into another
/// contact.
class InMemoryContactsGateway implements ContactsGateway {
  /// Contact ID -> its raw contacts. The first raw contact gives the name.
  final Map<String, List<_Raw>> _contacts = {};
  int _nextContactId = 100;
  int _nextRawId = 1;

  /// What [requestPermission] answers.
  bool permissionGranted = true;

  /// Whether the permission is already granted, for [hasPermission]. Null
  /// means "as [permissionGranted] says"; [requestPermission] sets it.
  bool? alreadyGranted;

  /// When set, the matching call throws it.
  Object? getAllError;
  Object? createAllError;
  Object? deleteAllError;

  /// Called for each contact [createAll] adds. Returning an existing contact
  /// ID merges the new raw contact into that contact, as Android's
  /// aggregation can do.
  String? Function(NewContact contact)? mergeInto;

  int permissionRequests = 0;
  int permissionChecks = 0;
  int getAllCalls = 0;
  final List<List<NewContact>> createAllCalls = [];
  final List<List<String>> deleteAllCalls = [];

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

  /// Changes the phone numbers of a contact (its first raw contact).
  void setPhones(String contactId, List<String> phones) {
    _contacts[contactId]!.first.phones = [...phones];
  }

  /// A raw contact ID that was never assigned.
  String unusedRawId() => '${_nextRawId++}';

  /// All contacts, read without going through the gateway's counters.
  List<StoredContact> get all => [for (final id in _contacts.keys) _toStored(id)];

  List<String> get displayNames => [for (final c in all) c.displayName];

  StoredContact _toStored(String id) {
    final raws = _contacts[id]!;
    return StoredContact(
      id: id,
      rawContactIds: [for (final r in raws) r.id],
      displayName: raws.first.displayName,
      phones: [for (final r in raws) ...r.phones],
      emails: [for (final r in raws) ...r.emails],
    );
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    alreadyGranted = permissionGranted;
    return permissionGranted;
  }

  @override
  Future<bool> hasPermission() async {
    permissionChecks++;
    return alreadyGranted ?? permissionGranted;
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
    createAllCalls.add(contacts);
    if (createAllError != null) throw createAllError!;
    final ids = <String>[];
    for (final c in contacts) {
      final raw = _Raw('${_nextRawId++}', '${c.first} ${c.last}',
          [if (c.phone.isNotEmpty) c.phone], [if (c.email.isNotEmpty) c.email]);
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
    return ids;
  }

  @override
  Future<void> deleteAll(List<String> contactIds) async {
    deleteAllCalls.add(contactIds);
    if (deleteAllError != null) throw deleteAllError!;
    contactIds.forEach(_contacts.remove);
  }
}
