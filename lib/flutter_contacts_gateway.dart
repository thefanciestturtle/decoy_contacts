import 'dart:developer';

import 'package:flutter_contacts/flutter_contacts.dart';

import 'contacts_gateway.dart';

/// [ContactsGateway] for the device's address book, via `flutter_contacts`.
class FlutterContactsGateway implements ContactsGateway {
  const FlutterContactsGateway();

  @override
  Future<PermissionAnswer> requestPermission() async {
    final before =
        await FlutterContacts.permissions.check(PermissionType.readWrite);
    final after =
        await FlutterContacts.permissions.request(PermissionType.readWrite);
    if (after != PermissionStatus.granted) {
      log("FlutterContactsGateway: no permission, status $before -> $after");
    }
    return permissionAnswer(before: before, after: after);
  }

  // If Android has no screen for the app's settings, the plugin's native
  // code throws on the main thread and the app crashes, rather than
  // returning an error; every phone has that screen, though.
  @override
  Future<void> openSettings() => FlutterContacts.permissions.openSettings();

  @override
  Future<bool> hasPermission() async =>
      await FlutterContacts.permissions.check(PermissionType.readWrite) ==
      PermissionStatus.granted;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final contacts = await FlutterContacts.getAll(
      properties: {
        ContactProperty.identifiers,
        ContactProperty.name,
        ContactProperty.phone,
        ContactProperty.email,
      },
      filter: ids == null ? null : ContactFilter.ids(ids),
    );
    return [
      for (final c in contacts)
        if (c.id != null)
          StoredContact(
            id: c.id!,
            rawContactIds: [
              for (final r
                  in c.android?.identifiers?.rawContacts ?? const <RawContact>[])
                if (r.rawContactId != null) r.rawContactId!,
            ],
            displayName: c.displayName ?? "",
            phones: [for (final p in c.phones) p.number],
            emails: [for (final e in c.emails) e.address],
          ),
    ];
  }

  @override
  Future<List<String>> createAll(List<NewContact> contacts) {
    return FlutterContacts.createAll([
      for (final c in contacts)
        Contact(
          name: Name(first: c.first, last: c.last),
          phones: [if (c.phone.isNotEmpty) Phone(number: c.phone)],
          emails: [if (c.email.isNotEmpty) Email(address: c.email)],
        ),
    ]);
  }

  @override
  Future<void> deleteAll(List<String> contactIds) =>
      FlutterContacts.deleteAll(contactIds);
}

/// The answer to a permission request, from the plugin's status [before]
/// it (from `check`) and its answer [after].
///
/// The plugin says "permanently denied" whenever, after a refusal, Android
/// says there's no need to explain why the app asks. That is so:
/// - when Android didn't ask at all because it won't any more: the case
///   to offer the settings for;
/// - right after the user said "Don't allow" a second time in Android's
///   dialog. They just said no, so the app only says it was denied; the
///   next tap gets no dialog and offers the settings. Before such a
///   dialog `check` says [PermissionStatus.denied] (an explanation was
///   called for), which tells this case apart.
/// - when the user left the very first dialog with Back or a tap outside
///   it, though Android would still ask the next time. This can't be told
///   apart from the first case (`check` says notDetermined before both,
///   and the app's activity is paused either way), so the app then offers
///   the settings once when it needn't have, which does no harm.
///
/// The plugin only reports "permanently denied" on Android; restricted and
/// limited are iOS only.
PermissionAnswer permissionAnswer(
        {required PermissionStatus before, required PermissionStatus after}) =>
    switch (after) {
      PermissionStatus.granted => PermissionAnswer.granted,
      PermissionStatus.permanentlyDenied when before != PermissionStatus.denied =>
        PermissionAnswer.permanentlyDenied,
      _ => PermissionAnswer.denied,
    };
