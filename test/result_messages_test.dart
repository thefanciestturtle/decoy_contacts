import 'package:fake_contacts/contact_actions.dart';
import 'package:fake_contacts/result_messages.dart';
import 'package:flutter_test/flutter_test.dart';

CreateResult created(int n, {int alreadyExisted = 0, int untracked = 0}) =>
    CreateResult(created: n, alreadyExisted: alreadyExisted, untracked: untracked);

DeleteResult deleted(int n, {int merged = 0, int changed = 0}) =>
    DeleteResult(deleted: n, skippedMerged: merged, skippedChanged: changed);

void main() {
  test('permission denied', () {
    expect(kPermissionDeniedMessage, 'Permission to access contacts was denied.');
  });

  test('errors', () {
    expect(errorMessage('creating', Exception('disk full')),
        'Error while creating contacts: Exception: disk full');
    expect(errorMessage('deleting', StateError('gone')),
        'Error while deleting contacts: Bad state: gone');
  });

  group('createdMessage', () {
    test('only the count when nothing else happened', () {
      expect(createdMessage(created(756)), 'Created 756 fake contact(s).');
      expect(createdMessage(created(0)), 'Created 0 fake contact(s).');
    });

    test('mentions contacts that already existed', () {
      expect(createdMessage(created(0, alreadyExisted: 756)),
          'Created 0 fake contact(s). 756 already existed.');
    });

    test('warns about untracked contacts', () {
      expect(createdMessage(created(4, untracked: 1)),
          'Created 4 fake contact(s). Warning: 1 could not be recorded and '
          'must be deleted by hand.');
    });

    test('both extras, in order', () {
      expect(createdMessage(created(2, alreadyExisted: 2, untracked: 1)),
          'Created 2 fake contact(s). 2 already existed. Warning: 1 could not '
          'be recorded and must be deleted by hand.');
    });
  });

  group('deletedMessage', () {
    test('only the count when nothing was skipped', () {
      expect(deletedMessage(deleted(756)), 'Deleted 756 fake contact(s).');
    });

    test('mentions merged contacts', () {
      expect(deletedMessage(deleted(3, merged: 1)),
          'Deleted 3 fake contact(s). 1 were merged with other contacts and '
          'were left alone.');
    });

    test('mentions contacts that no longer match', () {
      expect(deletedMessage(deleted(0, changed: 4)),
          "Deleted 0 fake contact(s). 4 no longer match what this app created "
          "(edited, or the app's records came from another phone) and were "
          "left alone.");
    });

    test('both skips, in order', () {
      expect(deletedMessage(deleted(1, merged: 1, changed: 2)),
          "Deleted 1 fake contact(s). 1 were merged with other contacts and "
          "were left alone. 2 no longer match what this app created (edited, "
          "or the app's records came from another phone) and were left alone.");
    });
  });
}
