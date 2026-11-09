import 'package:fake_contacts/contacts_gateway.dart';
import 'package:fake_contacts/flutter_contacts_gateway.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
