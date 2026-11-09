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

const FakeSample kZoeZen =
    (name: 'Zoe Zen', phone: '+447700900010', email: 'Zoe.Zen@example.com');

SettingsPreview settingsMake(int lastNames, int firstNames,
        {FakeSample? sample = kZoeZen}) =>
    SettingsPreview(
      lastNames: lastNames,
      firstNames: firstNames,
      sample: lastNames * firstNames == 0 ? null : sample,
    );

void main() {
  group('settingsPreviewMessage', () {
    test('the count, how it comes about, and an example', () {
      expect(settingsPreviewMessage(settingsMake(27, 28)),
          '27 last names × 28 first names = 756 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');
    });

    test('singular forms; with only one contact it is not an example', () {
      expect(settingsPreviewMessage(settingsMake(1, 1)),
          '1 last name × 1 first name = 1 fake contact:\n'
          'Zoe Zen · +447700900010 · Zoe.Zen@example.com');
      expect(settingsPreviewMessage(settingsMake(1, 2)),
          '1 last name × 2 first names = 2 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');
      expect(settingsPreviewMessage(settingsMake(3, 1)).split('\n').first,
          '3 last names × 1 first name = 3 fake contacts.');
    });

    test('leaves out a phone number or email the contacts won\'t get', () {
      String sampleLine(String phone, String email) => settingsPreviewMessage(
              settingsMake(2, 2,
                  sample: (name: 'Zoe Zen', phone: phone, email: email)))
          .split('\n')
          .last;
      expect(sampleLine('', 'Zoe.Zen@example.com'),
          'For example: Zoe Zen · Zoe.Zen@example.com');
      expect(sampleLine('+447700900010', ''),
          'For example: Zoe Zen · +447700900010');
      expect(sampleLine('', ''), 'For example: Zoe Zen');
    });

    test('an example without combinations is a mistake', () {
      expect(
          () => SettingsPreview(lastNames: 0, firstNames: 2, sample: kZoeZen),
          throwsAssertionError);
      expect(() => SettingsPreview(lastNames: 3, firstNames: 2, sample: null),
          throwsAssertionError);
    });

    test('where the phone number is in the spoken text', () {
      String? spokenPhone(SettingsPreview preview) {
        final spoken = spokenSettingsPreview(preview);
        final range = spoken.phoneNumber;
        if (range == null) return null;
        return spoken.text.substring(range.$1, range.$2);
      }

      expect(spokenPhone(settingsMake(27, 28)), '+447700900010');
      expect(spokenPhone(settingsMake(1, 1)), '+447700900010');
      expect(
          spokenPhone(settingsMake(2, 3,
              sample: (name: 'Zoe Zen', phone: '+1 555 0105', email: ''))),
          '+1 555 0105');
      expect(
          spokenPhone(settingsMake(2, 3,
              sample: (name: 'Zoe Zen', phone: '', email: 'z@example.org'))),
          isNull);
      expect(spokenPhone(settingsMake(0, 3)), isNull);
    });

    test('says what is missing when the settings make none', () {
      expect(settingsPreviewMessage(settingsMake(0, 28)),
          '0 last names × 28 first names = no fake contacts.\n'
          'Enter at least one last name.');
      expect(settingsPreviewMessage(settingsMake(1, 0)),
          '1 last name × 0 first names = no fake contacts.\n'
          'Enter at least one first name.');
      expect(settingsPreviewMessage(settingsMake(0, 0)),
          '0 last names × 0 first names = no fake contacts.\n'
          'Enter at least one last name and one first name.');
    });

    test('for a screen reader: words instead of signs and dots', () {
      expect(spokenSettingsPreview(settingsMake(27, 28)).text,
          '27 last names times 28 first names makes 756 fake contacts.\n'
          'For example: Zoe Zen, +447700900010, Zoe.Zen@example.com');
      expect(spokenSettingsPreview(settingsMake(1, 1)).text,
          '1 last name times 1 first name makes 1 fake contact:\n'
          'Zoe Zen, +447700900010, Zoe.Zen@example.com');
      expect(spokenSettingsPreview(settingsMake(0, 1)).text,
          '0 last names times 1 first name makes no fake contacts.\n'
          'Enter at least one last name.');
    });
  });

  test('permission denied', () {
    expect(kPermissionDeniedMessage, 'Permission to access contacts was denied.');
  });

  test('status line', () {
    expect(statusMessage(toDelete(0)), 'No fake contacts on this phone.');
    expect(statusMessage(toDelete(1)), '1 fake contact on this phone.');
    expect(statusMessage(toDelete(756, merged: 1, changed: 2)),
        '756 fake contacts on this phone.');
    // Doesn't claim there are none while it tracks some it can't check.
    expect(statusMessage(toDelete(0, merged: 1)),
        'No fake contacts this app can delete.');
    expect(statusMessage(toDelete(0, changed: 3)),
        'No fake contacts this app can delete.');
  });

  test('the address book changed while the dialog was open', () {
    expect(kChangedMeanwhileMessage,
        'Your contacts changed meanwhile, so nothing was done. Try again.');
  });

  test('errors', () {
    expect(errorMessage('creating', Exception('disk full')),
        'Error while creating contacts: Exception: disk full');
    expect(errorMessage('reading', Exception('no provider')),
        'Error while reading contacts: Exception: no provider');
    expect(errorMessage('deleting', StateError('gone')),
        'Error while deleting contacts: Bad state: gone');
  });

  group('createdMessage', () {
    test('only the count when nothing else happened', () {
      expect(createdMessage(created(756)), 'Created 756 fake contacts.');
      expect(createdMessage(created(0)), 'Created 0 fake contacts.');
      expect(createdMessage(created(1)), 'Created 1 fake contact.');
    });

    test('mentions contacts that already existed', () {
      expect(createdMessage(created(0, alreadyExisted: 756)),
          'Created 0 fake contacts. 756 already existed.');
    });

    test('warns about untracked contacts', () {
      expect(createdMessage(created(4, untracked: 1)),
          'Created 4 fake contacts. Warning: 1 could not be recorded and '
          'must be deleted by hand.');
    });

    test('both extras, in order', () {
      expect(createdMessage(created(2, alreadyExisted: 2, untracked: 1)),
          'Created 2 fake contacts. 2 already existed. Warning: 1 could not '
          'be recorded and must be deleted by hand.');
    });
  });

  group('deletedMessage', () {
    test('only the count when nothing was skipped', () {
      expect(deletedMessage(deleted(756)), 'Deleted 756 fake contacts.');
    });

    test('mentions merged contacts', () {
      expect(deletedMessage(deleted(3, merged: 1)),
          'Deleted 3 fake contacts. 1 was merged with another contact and '
          'was left alone.');
      expect(deletedMessage(deleted(3, merged: 2)),
          'Deleted 3 fake contacts. 2 were merged with other contacts and '
          'were left alone.');
    });

    test('mentions contacts that no longer match', () {
      expect(deletedMessage(deleted(0, changed: 4)),
          'Deleted 0 fake contacts. 4 $kChanged and were left alone.');
      expect(deletedMessage(deleted(0, changed: 1)),
          'Deleted 0 fake contacts. 1 $kOneChanged and was left alone.');
    });

    test('both skips, in order', () {
      expect(deletedMessage(deleted(1, merged: 1, changed: 2)),
          'Deleted 1 fake contact. 1 was merged with another contact and '
          'was left alone. 2 $kChanged and were left alone.');
    });
  });

  group('createConfirmation', () {
    test('the count, and that they can be removed', () {
      expect(createConfirmation(toCreate(756)), (
        title: 'Create 756 fake contacts?',
        body: 'They are added to the contacts on this phone.',
        action: 'Create',
      ));
    });

    test('one contact', () {
      expect(createConfirmation(toCreate(1)), (
        title: 'Create 1 fake contact?',
        body: 'It is added to the contacts on this phone.',
        action: 'Create',
      ));
    });

    test('mentions the ones that already exist', () {
      expect(createConfirmation(toCreate(2, alreadyExisted: 754)).body,
          '754 already exist and will be skipped. They are added to the '
          'contacts on this phone.');
      expect(createConfirmation(toCreate(755, alreadyExisted: 1)).body,
          '1 already exists and will be skipped. They are added to the '
          'contacts on this phone.');
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
          'Nothing to create. Enter at least one last name and one first name.');
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
