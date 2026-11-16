/// One raw contact (Android): what one source, such as an online account or
/// the phone itself, holds about a contact. Each fake is one.
class StoredRawContact {
  final String id;

  /// Its own display name, which Android works out from its name (or, if it
  /// has none, from its other details). A contact shows one of its raw
  /// contacts' names.
  final String displayName;

  final List<String> phones;
  final List<String> emails;

  const StoredRawContact({
    required this.id,
    required this.displayName,
    this.phones = const [],
    this.emails = const [],
  });

  @override
  String toString() =>
      'StoredRawContact($id, $displayName, $phones, $emails)';
}

/// A contact (Android aggregate contact) as read from the address book.
class StoredContact {
  final String id;

  /// The raw contacts that make up this contact. Android may merge several
  /// raw contacts into one contact: from different sources if their names
  /// match, and from the same source if they also share a phone number or
  /// email address.
  final List<StoredRawContact> rawContacts;

  const StoredContact({required this.id, required this.rawContacts});

  List<String> get rawContactIds => [for (final r in rawContacts) r.id];

  @override
  String toString() => 'StoredContact($id, $rawContacts)';
}

/// A contact to create. An empty [phone] or [email] means none.
class NewContact {
  final String first;
  final String last;
  final String phone;
  final String email;

  const NewContact({
    required this.first,
    required this.last,
    this.phone = '',
    this.email = '',
  });
}

/// The answer to a request for access to the contacts.
enum PermissionAnswer {
  granted,

  /// Refused, but the app can ask again.
  denied,

  /// Refused, and Android no longer asks the user (since a second "Don't
  /// allow", or "Don't ask again" on older versions): asking returns at
  /// once without a dialog. Only the app's settings can allow it now. Not
  /// for the second "Don't allow" itself: the user just said no, so that
  /// one is [denied].
  permanentlyDenied,
}

/// The address book operations the app needs.
abstract interface class ContactsGateway {
  /// Asks for read/write access to the contacts.
  Future<PermissionAnswer> requestPermission();

  /// Opens this app's page in the system settings, where the user can allow
  /// access to the contacts.
  Future<void> openSettings();

  /// True if read/write access to the contacts was already granted. Never
  /// asks the user.
  Future<bool> hasPermission();

  /// Every contact, or only those with the given contact IDs, each with its
  /// raw contacts.
  Future<List<StoredContact>> getAll({List<String>? ids});

  /// Creates [contacts] and returns their contact IDs, in the same order.
  Future<List<String>> createAll(List<NewContact> contacts);

  /// Deletes the raw contacts with these raw contact IDs, and no others: not
  /// the other raw contacts of their contacts. (Those that are gone already
  /// are passed over.)
  Future<void> deleteRawContacts(List<String> rawContactIds);
}
