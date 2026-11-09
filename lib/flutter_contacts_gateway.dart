import 'dart:developer';

import 'package:flutter_contacts/flutter_contacts.dart';

import 'contacts_gateway.dart';

/// [ContactsGateway] for the device's address book, via `flutter_contacts`.
class FlutterContactsGateway implements ContactsGateway {
  const FlutterContactsGateway();

  @override
  Future<PermissionAnswer> requestPermission() async {
    final status =
        await FlutterContacts.permissions.request(PermissionType.readWrite);
    if (status != PermissionStatus.granted) {
      log("FlutterContactsGateway: no permission, status $status");
    }
    return switch (status) {
      PermissionStatus.granted => PermissionAnswer.granted,
      // The plugin only reports this one on Android. (restricted and
      // limited are iOS only.) It also reports it when the user leaves
      // the very first dialog with Back or a tap outside it, though
      // Android would still ask the next time: in both cases Android only
      // says there's no need to explain why the app asks. Then the app
      // offers the settings once when it needn't have, which does no harm;
      // telling the two apart would mean guessing from how long the
      // request took. (The app's activity is paused either way.)
      PermissionStatus.permanentlyDenied => PermissionAnswer.permanentlyDenied,
      _ => PermissionAnswer.denied,
    };
  }

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
