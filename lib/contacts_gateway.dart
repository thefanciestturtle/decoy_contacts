/// The parts of a name, as stored in a raw contact's name (any may be
/// empty).
class NameParts {
  final String prefix;
  final String given;
  final String middle;
  final String family;
  final String suffix;

  const NameParts({
    this.prefix = '',
    this.given = '',
    this.middle = '',
    this.family = '',
    this.suffix = '',
  });

  /// The parts that aren't empty, in the order of Western names, with a
  /// space between them: "Zoe Zen" for the given name "Zoe" and the family
  /// name "Zen", whatever script they are in and whatever the phone's
  /// language.
  String get joined => [prefix, given, middle, family, suffix]
      .where((part) => part.isNotEmpty)
      .join(' ');

  @override
  bool operator ==(Object other) =>
      other is NameParts &&
      other.prefix == prefix &&
      other.given == given &&
      other.middle == middle &&
      other.family == family &&
      other.suffix == suffix;

  @override
  int get hashCode => Object.hash(prefix, given, middle, family, suffix);

  @override
  String toString() => 'NameParts($joined)';
}

/// One raw contact (Android): what one source, such as an online account or
/// the phone itself, holds about a contact. Each fake is one.
class StoredRawContact {
  final String id;

  /// Its own display name, which Android works out from its name (or, if it
  /// has none, from its other details). A contact shows one of its raw
  /// contacts' names.
  ///
  /// Android's order of the name's parts depends on the script and the
  /// phone's language: for Chinese, Japanese and Korean names it puts the
  /// family name first, with no space ("王伟" for the given name "伟" and the
  /// family name "王"). So the app doesn't compare it with the names it
  /// creates: it compares [name].
  final String displayName;

  /// The parts of its name, as they are stored, which Android keeps as they
  /// were written. Null if it has no name.
  final NameParts? nameParts;

  final List<String> phones;
  final List<String> emails;

  const StoredRawContact({
    required this.id,
    required this.displayName,
    this.nameParts,
    this.phones = const [],
    this.emails = const [],
  });

  /// The name to compare with the one the app created the contact with
  /// ("first last"): its [nameParts] put together, or, if it has none (no
  /// name, or an empty one), the [displayName].
  String get name {
    final joined = nameParts?.joined ?? '';
    return joined.isEmpty ? displayName : joined;
  }

  @override
  String toString() =>
      'StoredRawContact($id, $displayName, $nameParts, $phones, $emails)';
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

  /// Those of the raw contact IDs that exist: not deleted, whichever contact
  /// they are in (also none, or one that [getAll] leaves out). Fails if the
  /// address book can't be reached, rather than saying none exist.
  Future<Set<String>> existingRawContacts(List<String> rawContactIds);

  /// Creates [contacts] and returns their contact IDs, in the same order.
  Future<List<String>> createAll(List<NewContact> contacts);

  /// Deletes the raw contacts with these raw contact IDs, and no others: not
  /// the other raw contacts of their contacts. (Those that are gone already
  /// are passed over.)
  Future<void> deleteRawContacts(List<String> rawContactIds);
}
