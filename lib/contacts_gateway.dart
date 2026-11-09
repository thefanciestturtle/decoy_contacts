/// A contact (Android aggregate contact) as read from the address book.
class StoredContact {
  final String id;

  /// Android raw contact IDs that make up this contact. Android may merge
  /// several raw contacts, from different sources, into one contact.
  final List<String> rawContactIds;

  final String displayName;
  final List<String> phones;
  final List<String> emails;

  const StoredContact({
    required this.id,
    required this.rawContactIds,
    required this.displayName,
    this.phones = const [],
    this.emails = const [],
  });

  @override
  String toString() =>
      'StoredContact($id, $rawContactIds, $displayName, $phones, $emails)';
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

/// The address book operations the app needs.
abstract interface class ContactsGateway {
  /// Asks for read/write access to the contacts. True if it was granted.
  Future<bool> requestPermission();

  /// True if read/write access to the contacts was already granted. Never
  /// asks the user.
  Future<bool> hasPermission();

  /// Every contact, or only those with the given contact IDs.
  Future<List<StoredContact>> getAll({List<String>? ids});

  /// Creates [contacts] and returns their contact IDs, in the same order.
  Future<List<String>> createAll(List<NewContact> contacts);

  /// Deletes the contacts with these contact IDs.
  Future<void> deleteAll(List<String> contactIds);
}
