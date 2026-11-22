import 'dart:developer';

import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'contacts_gateway.dart';

/// [ContactsGateway] for the device's address book, via `flutter_contacts`,
/// except for reading it and deleting from it: [getAll] and
/// [deleteRawContacts] use the app's own Android code.
class FlutterContactsGateway implements ContactsGateway {
  const FlutterContactsGateway();

  @override
  Future<PermissionAnswer> requestPermission() async {
    final before =
        await FlutterContacts.permissions.check(PermissionType.readWrite);
    if (before == PermissionStatus.granted) return PermissionAnswer.granted;
    final after =
        await FlutterContacts.permissions.request(PermissionType.readWrite);
    // The plugin says "granted" for a request Android cut short (with no
    // answers at all), so make sure. The user didn't refuse, so it isn't a
    // denial: asking failed.
    if (after == PermissionStatus.granted && !await hasPermission()) {
      throw StateError("permission request cut short");
    }
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

  /// Read by the app's own Android code (RawContactsChannel.kt), not the
  /// plugin: the plugin gives one name per contact, and the app needs each
  /// raw contact's own.
  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final raws = await kRawContactsChannel.invokeListMethod<Map<Object?, Object?>>(
        kReadRawContacts, {'contactIds': ?ids});
    return contactsOfRawContacts(raws ?? const []);
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

  /// Deleted by the app's own Android code (RawContactsChannel.kt), not the
  /// plugin: the plugin deletes whole contacts, with every raw contact they
  /// hold by then, also one that Android merged into them after the app
  /// checked them.
  @override
  Future<void> deleteRawContacts(List<String> rawContactIds) =>
      kRawContactsChannel
          .invokeMethod<void>(kDeleteRawContacts, {'ids': rawContactIds});
}

/// The app's own channel to its Android code, which reads and deletes raw
/// contacts (android/app/src/main/kotlin/.../RawContactsChannel.kt).
const MethodChannel kRawContactsChannel =
    MethodChannel('io.github.thefanciestturtle.decoy_contacts/raw_contacts');

/// The method on [kRawContactsChannel] that reads raw contacts: those of the
/// contacts with the IDs in its argument "contactIds", or of every contact.
const String kReadRawContacts = 'read';

/// The method on [kRawContactsChannel] that deletes the raw contacts with
/// the IDs in its argument "ids", and no others.
const String kDeleteRawContacts = 'delete';

/// The contacts that [raws] make up, in the order of their first raw
/// contacts. Each of [raws] is a raw contact as [kReadRawContacts] answers
/// it: a map with "id", "contactId", "displayName", "nameParts" (a map with
/// "prefix", "given", "middle", "family" and "suffix", or null if it has no
/// name), "phones" and "emails".
List<StoredContact> contactsOfRawContacts(List<Map<Object?, Object?>> raws) {
  final byContact = <String, List<StoredRawContact>>{};
  for (final raw in raws) {
    (byContact[raw['contactId'] as String] ??= []).add(StoredRawContact(
      id: raw['id'] as String,
      displayName: raw['displayName'] as String,
      nameParts: _nameParts(raw['nameParts'] as Map<Object?, Object?>?),
      phones: [for (final p in raw['phones'] as List) p as String],
      emails: [for (final e in raw['emails'] as List) e as String],
    ));
  }
  return [
    for (final MapEntry(key: id, value: rawContacts) in byContact.entries)
      StoredContact(id: id, rawContacts: rawContacts),
  ];
}

NameParts? _nameParts(Map<Object?, Object?>? parts) => parts == null
    ? null
    : NameParts(
        prefix: parts['prefix'] as String,
        given: parts['given'] as String,
        middle: parts['middle'] as String,
        family: parts['family'] as String,
        suffix: parts['suffix'] as String,
      );

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
/// This is Android's behaviour (the app runs only on Android).
PermissionAnswer permissionAnswer(
        {required PermissionStatus before, required PermissionStatus after}) =>
    switch (after) {
      PermissionStatus.granted => PermissionAnswer.granted,
      PermissionStatus.permanentlyDenied when before != PermissionStatus.denied =>
        PermissionAnswer.permanentlyDenied,
      _ => PermissionAnswer.denied,
    };
