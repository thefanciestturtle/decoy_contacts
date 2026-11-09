import 'package:fake_contacts/contact_actions.dart';
import 'package:fake_contacts/result_messages.dart';
import 'package:flutter_test/flutter_test.dart';

CreateResult created(int n, {int alreadyExisted = 0, int untracked = 0}) =>
    CreateResult(created: n, alreadyExisted: alreadyExisted, untracked: untracked);

DeleteResult deleted(int n, {int merged = 0, int changed = 0}) =>
    DeleteResult(deleted: n, skippedMerged: merged, skippedChanged: changed);

CreatePreview toCreate(int n, {int alreadyExisted = 0}) =>
    CreatePreview(toCreate: n, alreadyExisted: alreadyExisted);

DeletePreview toDelete(int n, {int merged = 0, int changed = 0}) =>
    DeletePreview(toDelete: n, skippedMerged: merged, skippedChanged: changed);

const String kChanged = "no longer match what this app created (edited, or "
    "the app's records came from another phone)";
const String kOneChanged = "no longer matches what this app created (edited, "
    "or the app's records came from another phone)";

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
          'Deleted 3 fake contact(s). 1 was merged with another contact and '
          'was left alone.');
      expect(deletedMessage(deleted(3, merged: 2)),
          'Deleted 3 fake contact(s). 2 were merged with other contacts and '
          'were left alone.');
    });

    test('mentions contacts that no longer match', () {
      expect(deletedMessage(deleted(0, changed: 4)),
          'Deleted 0 fake contact(s). 4 $kChanged and were left alone.');
      expect(deletedMessage(deleted(0, changed: 1)),
          'Deleted 0 fake contact(s). 1 $kOneChanged and was left alone.');
    });

    test('both skips, in order', () {
      expect(deletedMessage(deleted(1, merged: 1, changed: 2)),
          'Deleted 1 fake contact(s). 1 was merged with another contact and '
          'was left alone. 2 $kChanged and were left alone.');
    });
  });

  group('createConfirmation', () {
    test('the count, and that they can be removed', () {
      expect(createConfirmation(toCreate(756)), (
        title: 'Create 756 fake contacts?',
        body: 'You can remove them later with Delete Fake Contacts.',
        action: 'Create',
      ));
    });

    test('one contact', () {
      expect(createConfirmation(toCreate(1)), (
        title: 'Create 1 fake contact?',
        body: 'You can remove it later with Delete Fake Contacts.',
        action: 'Create',
      ));
    });

    test('mentions the ones that already exist', () {
      expect(createConfirmation(toCreate(2, alreadyExisted: 754)).body,
          '754 already exist and will be skipped. You can remove them later '
          'with Delete Fake Contacts.');
      expect(createConfirmation(toCreate(755, alreadyExisted: 1)).body,
          '1 already exists and will be skipped. You can remove them later '
          'with Delete Fake Contacts.');
    });
  });

  group('deleteConfirmation', () {
    test('the count, and that only the app\'s contacts go', () {
      expect(deleteConfirmation(toDelete(756)), (
        title: 'Delete 756 fake contacts?',
        body: 'Only contacts this app created are deleted.',
        action: 'Delete',
      ));
      expect(deleteConfirmation(toDelete(1)).title, 'Delete 1 fake contact?');
    });

    test('mentions the ones it will leave alone, in the future tense', () {
      expect(deleteConfirmation(toDelete(3, merged: 1, changed: 2)).body,
          'Only contacts this app created are deleted. 1 was merged with '
          'another contact and will be left alone. 2 $kChanged and will be '
          'left alone.');
      expect(deleteConfirmation(toDelete(3, merged: 2, changed: 1)).body,
          'Only contacts this app created are deleted. 2 were merged with '
          'other contacts and will be left alone. 1 $kOneChanged and will be '
          'left alone.');
    });
  });

  group('nothingToCreateMessage', () {
    test('all of them already exist', () {
      expect(nothingToCreateMessage(toCreate(0, alreadyExisted: 756)),
          'Nothing to create. 756 fake contacts already exist.');
      expect(nothingToCreateMessage(toCreate(0, alreadyExisted: 1)),
          'Nothing to create. 1 fake contact already exists.');
    });

    test('no names', () {
      expect(nothingToCreateMessage(toCreate(0)),
          'Nothing to create. Enter at least one first name and one last name.');
    });
  });

  group('nothingToDeleteMessage', () {
    test('nothing tracked', () {
      expect(nothingToDeleteMessage(toDelete(0)), 'No fake contacts to delete.');
    });

    test('mentions the ones it left alone', () {
      expect(nothingToDeleteMessage(toDelete(0, merged: 1, changed: 3)),
          'No fake contacts to delete. 1 was merged with another contact and '
          'was left alone. 3 $kChanged and were left alone.');
    });
  });
}
