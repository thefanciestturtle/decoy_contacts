import 'package:decoy_contacts/contacts_gateway.dart';
import 'package:decoy_contacts/flutter_contacts_gateway.dart';
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
}
