import 'dart:convert';
import 'dart:io';

import 'package:decoy_contacts/contact_actions.dart' show DeletePreview;
import 'package:decoy_contacts/contacts_gateway.dart';
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/flutter_contacts_gateway.dart';
import 'package:decoy_contacts/result_messages.dart' show statusMessage;
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterContactsGateway.requestPermission (U5)', () {
    const channel = MethodChannel('flutter_contacts');
    late List<String> calls;

    /// The plugin answers `check` with [checks] in turn, and `request` with
    /// [request] (or throws [requestError]).
    void plugin(List<String> checks, {String? request, Object? requestError}) {
      calls = [];
      var nextCheck = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'permissions.check':
            return checks[nextCheck++];
          case 'permissions.request':
            if (requestError != null) throw requestError;
            return request;
        }
        throw UnimplementedError(call.method);
      });
    }

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));

    const gateway = FlutterContactsGateway();
    const check = 'permissions.check', request = 'permissions.request';

    test('already granted: no request', () async {
      plugin(['granted']);
      expect(await gateway.requestPermission(), PermissionAnswer.granted);
      expect(calls, [check]);
    });

    test('granted in Android\'s dialog', () async {
      plugin(['notDetermined', 'granted'], request: 'granted');
      expect(await gateway.requestPermission(), PermissionAnswer.granted);
      expect(calls, [check, request, check]);
    });

    test('a request Android cut short, which the plugin calls granted, '
        'failed: the user didn\'t refuse', () async {
      plugin(['notDetermined', 'notDetermined'], request: 'granted');
      await expectLater(gateway.requestPermission(), throwsStateError);
    });

    test('a second "Don\'t allow" is a denial; once Android no longer '
        'asks, it is permanent', () async {
      plugin(['denied'], request: 'permanentlyDenied');
      expect(await gateway.requestPermission(), PermissionAnswer.denied);
      plugin(['notDetermined'], request: 'permanentlyDenied');
      expect(await gateway.requestPermission(),
          PermissionAnswer.permanentlyDenied);
    });

    test('an error from the plugin is passed on', () async {
      plugin(['notDetermined'],
          requestError: PlatformException(code: 'ERROR', message: 'No activity'));
      await expectLater(
          gateway.requestPermission(), throwsA(isA<PlatformException>()));
    });
  });

  group('permissionAnswer (U5)', () {
    // What `check` says before the request on Android: notDetermined if
    // never asked or Android won't ask any more, denied after one refusal.
    const never = PermissionStatus.notDetermined;
    const refusedOnce = PermissionStatus.denied;

    test('granted', () {
      for (final before in [never, refusedOnce, PermissionStatus.granted]) {
        expect(permissionAnswer(before: before, after: PermissionStatus.granted),
            PermissionAnswer.granted);
      }
    });

    test('a first "Don\'t allow": denied, Android asks again', () {
      expect(permissionAnswer(before: never, after: PermissionStatus.denied),
          PermissionAnswer.denied);
    });

    test('a second "Don\'t allow" in the dialog just shown: only denied, '
        'the user just said no', () {
      expect(
          permissionAnswer(
              before: refusedOnce, after: PermissionStatus.permanentlyDenied),
          PermissionAnswer.denied);
    });

    test('Android no longer asks: permanently denied', () {
      expect(
          permissionAnswer(
              before: never, after: PermissionStatus.permanentlyDenied),
          PermissionAnswer.permanentlyDenied);
    });

    test('anything else the plugin may say is a plain denial', () {
      for (final after in [
        PermissionStatus.notDetermined,
        PermissionStatus.restricted,
        PermissionStatus.limited,
      ]) {
        expect(permissionAnswer(before: never, after: after),
            PermissionAnswer.denied, reason: '$after');
      }
    });
  });

  group("FlutterContactsGateway's own Android code (C15, C17)", () {
    late List<MethodCall> calls;

    /// The app's Android code answers with [answer], or throws [error].
    void android(List<Map<String, Object?>>? answer, {Object? error}) {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kRawContactsChannel, (call) async {
        calls.add(call);
        if (error != null) throw error;
        return answer;
      });
    }

    tearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kRawContactsChannel, null));

    const gateway = FlutterContactsGateway();

    Map<String, Object?> raw(String id, String contactId, String name,
            {Map<String, String>? nameParts,
            List<String> phones = const [],
            List<String> emails = const []}) =>
        {
          'id': id,
          'contactId': contactId,
          'displayName': name,
          'nameParts': nameParts,
          'phones': phones,
          'emails': emails,
        };

    test('groups the raw contacts into their contacts, each with its own '
        'details', () async {
      android([
        raw('1', 'c1', 'Alice Example', phones: ['+15555550103']),
        raw('22', 'c23', 'Zena Zen',
            phones: ['+447700900010'], emails: ['Zena.Zen@example.com']),
        raw('23', 'c23', 'Zen Zena',
            phones: ['+447700900010'], emails: ['Zen.Zena@example.com']),
        raw('24', 'c24', 'Zena Zena', phones: ['+447700900010', '+1']),
      ]);
      final contacts = await gateway.getAll();
      expect([for (final c in contacts) c.id], ['c1', 'c23', 'c24']);
      expect([for (final c in contacts) c.rawContactIds], [
        ['1'],
        ['22', '23'],
        ['24'],
      ]);
      final zenZena = contacts[1].rawContacts[1];
      expect(zenZena.displayName, 'Zen Zena');
      expect(zenZena.phones, ['+447700900010']);
      expect(zenZena.emails, ['Zen.Zena@example.com']);
      expect(contacts[2].rawContacts.single.phones, ['+447700900010', '+1']);
      expect(contacts[0].rawContacts.single.emails, isEmpty);
    });

    test('reads the parts of a name as they are, whatever display name '
        'Android made of them (C16)', () async {
      android([
        raw('1', 'c1', '王伟', nameParts: {
          'prefix': '',
          'given': '伟',
          'middle': '',
          'family': '王',
          'suffix': '',
        }),
        raw('2', 'c2', 'Dr Zoe Q Zen', nameParts: {
          'prefix': 'Dr',
          'given': 'Zoe',
          'middle': 'Q',
          'family': 'Zen',
          'suffix': '',
        }),
        raw('3', 'c3', 'ACME', phones: ['+1']),
      ]);
      final [wang, zoe, acme] = [
        for (final c in await gateway.getAll()) c.rawContacts.single,
      ];
      expect(wang.displayName, '王伟');
      expect(wang.name, '伟 王');
      expect(zoe.name, 'Dr Zoe Q Zen');
      // No name: the display name Android made of its other details.
      expect(acme.nameParts, isNull);
      expect(acme.name, 'ACME');
    });

    test('asks for every contact, or only those with the given IDs',
        () async {
      android([]);
      expect(await gateway.getAll(), isEmpty);
      expect(await gateway.getAll(ids: ['c23', 'c24']), isEmpty);
      expect([for (final c in calls) c.method],
          [kReadRawContacts, kReadRawContacts]);
      expect([for (final c in calls) c.arguments], [
        <String, Object?>{},
        {'contactIds': ['c23', 'c24']},
      ]);
    });

    test('no answer reads as no contacts; an error is passed on', () async {
      android(null);
      expect(await gateway.getAll(), isEmpty);
      android(null, error: PlatformException(code: 'read_failed'));
      await expectLater(
          gateway.getAll(), throwsA(isA<PlatformException>()));
    });

    test('deleteRawContacts asks to delete exactly those raw contacts; an '
        'error is passed on (C17)', () async {
      android(null);
      await gateway.deleteRawContacts(['22', '23']);
      expect([for (final c in calls) c.method], [kDeleteRawContacts]);
      expect([for (final c in calls) c.arguments], [
        {'ids': ['22', '23']},
      ]);
      android(null, error: PlatformException(code: 'delete_failed'));
      await expectLater(gateway.deleteRawContacts(['22']),
          throwsA(isA<PlatformException>()));
    });

    test("the Android side answers on the channel and methods the Dart side "
        "calls, with the details it reads", () {
      final kotlin = File('android/app/src/main/kotlin/io/github/'
              'thefanciestturtle/decoy_contacts/RawContactsChannel.kt')
          .readAsStringSync();
      expect(kotlin, contains('CHANNEL = "${kRawContactsChannel.name}"'));
      expect(kotlin, contains('METHOD_READ = "$kReadRawContacts"'));
      expect(kotlin, contains('METHOD_DELETE = "$kDeleteRawContacts"'));
      expect(kotlin, contains('call.argument<List<String>>("contactIds")'));
      expect(kotlin, contains('call.argument<List<String>>("ids")'));
      for (final key in [
        'id',
        'contactId',
        'displayName',
        'nameParts',
        'phones',
        'emails',
      ]) {
        expect(kotlin, contains('"$key" to '), reason: key);
      }
      final main = File('android/app/src/main/kotlin/io/github/'
              'thefanciestturtle/decoy_contacts/MainActivity.kt')
          .readAsStringSync();
      expect(main, contains('RawContactsChannel('));
    });

    test('a query that gets no cursor fails the read, the first one too: a '
        'provider that can\'t be reached must not read as no contacts (C14)',
        () {
      // The on-device test integration_test/provider_gone_test.dart runs the
      // behaviour; this keeps the fast checks from passing without it.
      final kotlin = File('android/app/src/main/kotlin/io/github/'
              'thefanciestturtle/decoy_contacts/RawContactsChannel.kt')
          .readAsStringSync();
      for (final what in [
        'the contacts',
        'the raw contacts',
        'the names, phone numbers and emails',
      ]) {
        expect(kotlin,
            contains('?: throw IllegalStateException("no cursor for $what")'),
            reason: what);
      }
      expect(kotlin, isNot(contains('firstBatch')));
    });

    test('the release smoke test stores a record of its contact that the '
        'app reads, and waits for the status line that a read of it gives',
        () {
      // So it can't pass without the app reading the contact's own details:
      // had the record not been read, nothing would be read; had the read
      // failed, the status line would stay empty.
      final script = File('tool/release_smoke_test.sh').readAsStringSync();
      String value(String name) =>
          RegExp("$name='([^']*)'").firstMatch(script)!.group(1)!;
      final entry = LedgerEntry('${value('SMOKE_GIVEN')} '
          '${value('SMOKE_FAMILY')}', value('SMOKE_PHONE'), value('SMOKE_EMAIL'));
      expect(Ledger.decode(jsonEncode({'17': entry.toJson()})).length, 1);
      // In the script, the values are shell variables, and the settings
      // file's quotes are &quot;, written as \\&quot; in sed's replacement.
      final template = jsonEncode({
        r'$smoke_raw': const LedgerEntry(r'$SMOKE_GIVEN $SMOKE_FAMILY',
                r'$SMOKE_PHONE', r'$SMOKE_EMAIL')
            .toJson(),
      }).replaceAll('"', r'\\&quot;');
      expect(script, contains('<string name=\\"flutter.$kLedgerPrefsKey\\">'
          '$template</string>'));
      const one = DeletePreview(toDelete: 1, skippedMerged: 0, skippedChanged: 0);
      expect(script, contains("readonly ONE_FAKE='${statusMessage(one)}'"));
      expect(script, contains('wait_for_text "\$ONE_FAKE"'));
    });
  });
}
