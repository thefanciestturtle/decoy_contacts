import 'package:decoy_contacts/contact_actions.dart';
import 'package:decoy_contacts/settings_store.dart' show LedgerNotSaved;
import 'package:decoy_contacts/result_messages.dart' as messages;
import 'package:decoy_contacts/result_messages.dart'
    hide
        createdMessage,
        deletedMessage,
        createFailedMessage,
        deleteFailedMessage,
        nothingToCreateMessage,
        nothingToDeleteMessage,
        kPermissionDeniedMessage,
        kOpenSettingsFailedMessage,
        kPermissionRequestFailedMessage,
        kReadFailedMessage,
        kChangedMeanwhileMessage;
import 'package:flutter_test/flutter_test.dart';

// The texts of the result messages; which are failures is tested in the
// group 'which results are failures (U7)'.
String createdMessage(CreateResult r) => messages.createdMessage(r).text;
String deletedMessage(DeleteResult r) => messages.deletedMessage(r).text;
String createFailedMessage(Object e) => messages.createFailedMessage(e).text;
String deleteFailedMessage(Object e) => messages.deleteFailedMessage(e).text;
String nothingToCreateMessage(CreatePreview p, SettingsPreview s) =>
    messages.nothingToCreateMessage(p, s).text;
String nothingToDeleteMessage(DeletePreview p) =>
    messages.nothingToDeleteMessage(p).text;
final String kPermissionDeniedMessage =
    messages.kPermissionDeniedMessage.text;
final String kOpenSettingsFailedMessage =
    messages.kOpenSettingsFailedMessage.text;
final String kPermissionRequestFailedMessage =
    messages.kPermissionRequestFailedMessage.text;
final String kReadFailedMessage = messages.kReadFailedMessage.text;
final String kChangedMeanwhileMessage = messages.kChangedMeanwhileMessage.text;

CreateResult created(int n,
        {int alreadyExisted = 0, int untracked = 0, int? stoppedOf}) =>
    CreateResult(
        created: n,
        alreadyExisted: alreadyExisted,
        untracked: untracked,
        planned: stoppedOf,
        stopped: stoppedOf != null);

DeleteResult deleted(int n, {int merged = 0, int changed = 0, int? stoppedOf}) =>
    DeleteResult(
        deleted: n,
        skippedMerged: merged,
        skippedChanged: changed,
        planned: stoppedOf,
        stopped: stoppedOf != null);

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
      lastNameCount: lastNames,
      firstNameCount: firstNames,
      sample: lastNames * firstNames == 0 ? null : sample,
    );

String _text(SettingsPreview preview) => settingsPreviewText(preview).text;

void main() {
  group('settingsPreviewText', () {
    test('the count, how it comes about, and an example', () {
      expect(_text(settingsMake(27, 28)),
          '27 last names × 28 first names = 756 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');
    });

    test('singular forms; with only one contact it is not an example', () {
      expect(_text(settingsMake(1, 1)),
          '1 last name × 1 first name = 1 fake contact:\n'
          'Zoe Zen · +447700900010 · Zoe.Zen@example.com');
      expect(_text(settingsMake(1, 2)),
          '1 last name × 2 first names = 2 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');
      expect(_text(settingsMake(3, 1)).split('\n').first,
          '3 last names × 1 first name = 3 fake contacts.');
    });

    test('leaves out a phone number or email the contacts won\'t get', () {
      String sampleLine(String phone, String email) => _text(
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
          () => SettingsPreview(
              lastNameCount: 0, firstNameCount: 2, sample: kZoeZen),
          throwsAssertionError);
      expect(() => SettingsPreview(
              lastNameCount: 3, firstNameCount: 2, sample: null),
          throwsAssertionError);
    });

    test('where the phone number is in the spoken text', () {
      String? spokenPhone(SettingsPreview preview) {
        final text = settingsPreviewText(preview);
        final range = text.spokenPhoneNumber;
        if (range == null) return null;
        return text.spoken.substring(range.$1, range.$2);
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
      expect(_text(settingsMake(0, 28)),
          '0 last names × 28 first names = no fake contacts.\n'
          'Enter at least one last name.');
      expect(_text(settingsMake(1, 0)),
          '1 last name × 0 first names = no fake contacts.\n'
          'Enter at least one first name.');
      expect(_text(settingsMake(0, 0)),
          '0 last names × 0 first names = no fake contacts.\n'
          'Enter at least one last name and one first name.');
    });

    test('more than 10000 contacts get a warning (U4)', () {
      const kWarning = 'That many take a long time to create and can slow '
          'down your contacts app.';
      expect(_text(settingsMake(100, 100)), isNot(contains(kWarning)));
      expect(_text(settingsMake(10001, 1)),
          '10001 last names × 1 first name = 10001 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com\n'
          '$kWarning');
      final spoken = settingsPreviewText(settingsMake(2000, 2000));
      expect(spoken.spoken, endsWith('\n$kWarning'));
      // The phone number is still where it says.
      final (start, end) = spoken.spokenPhoneNumber!;
      expect(spoken.spoken.substring(start, end), '+447700900010');
    });

    test('for a screen reader: words instead of signs and dots', () {
      expect(settingsPreviewText(settingsMake(27, 28)).spoken,
          '27 last names times 28 first names makes 756 fake contacts.\n'
          'For example: Zoe Zen, +447700900010, Zoe.Zen@example.com');
      expect(settingsPreviewText(settingsMake(1, 1)).spoken,
          '1 last name times 1 first name makes 1 fake contact:\n'
          'Zoe Zen, +447700900010, Zoe.Zen@example.com');
      expect(settingsPreviewText(settingsMake(0, 1)).spoken,
          '0 last names times 1 first name makes no fake contacts.\n'
          'Enter at least one last name.');
    });
  });

  test('permission denied', () {
    expect(kPermissionDeniedMessage, 'Permission to access contacts was denied.');
  });

  test('permission permanently denied: the dialog that offers the settings '
      '(U5)', () {
    expect(permissionSettingsConfirmation('create'), (
      title: 'Contacts access is off',
      body: 'To create fake contacts, this app needs access to your contacts.'
          ' In Settings, tap Permissions and allow Contacts.',
      action: 'Open settings',
    ));
    expect(permissionSettingsConfirmation('delete').body,
        startsWith('To delete fake contacts, '));
    expect(kOpenSettingsFailedMessage, "Couldn't open Settings.");
    expect(kPermissionRequestFailedMessage,
        "Couldn't ask for permission to access contacts. Try again.");
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

  group('errors', () {
    /// Stopped after [done] of [planned], because of [cause].
    StoppedPartway stopped(int? done, int planned,
            {Object cause = 'provider gone'}) =>
        StoppedPartway(
            done: done,
            planned: planned,
            cause: cause,
            stackTrace: StackTrace.empty);

    /// What the plugin reports when the contacts provider can't write.
    const sFull = 'PlatformException(flutter_contacts_error, Failed to handle'
        ' createAll: database or disk is full (code 13 SQLITE_FULL), null,'
        ' null)';

    test('reading', () {
      expect(kReadFailedMessage, "Couldn't read your contacts. Try again.");
    });

    test('nothing created or deleted', () {
      for (final error in [
        Exception('disk full'),
        StateError('gone'),
        stopped(0, 4),
      ]) {
        expect(createFailedMessage(error),
            "Couldn't create fake contacts. Try again.");
        expect(deleteFailedMessage(error),
            "Couldn't delete fake contacts. Try again.");
      }
    });

    test('some created or deleted, with the total in the plural', () {
      expect(createFailedMessage(stopped(150, 756)),
          'Created 150 of 756 fake contacts, then something went wrong.'
          ' Try again to create the rest.');
      expect(createFailedMessage(stopped(1, 2)),
          'Created 1 of 2 fake contacts, then something went wrong.'
          ' Try again to create the rest.');
      expect(deleteFailedMessage(stopped(900, 2000)),
          'Deleted 900 of 2000 fake contacts, then something went wrong.'
          ' Try again to delete the rest.');
      expect(deleteFailedMessage(stopped(1, 2)),
          'Deleted 1 of 2 fake contacts, then something went wrong.'
          ' Try again to delete the rest.');
    });

    test("the ledger couldn't be saved (U8): what was made is still "
        'recorded, so it says the storage is full', () {
      const notSaved = LedgerNotSaved();
      expect(createFailedMessage(stopped(200, 755, cause: notSaved)),
          'Created 200 of 755 fake contacts before your phone ran out of'
          ' storage.');
      expect(createFailedMessage(stopped(1, 1, cause: notSaved)),
          'Created 1 fake contact before your phone ran out of storage.');
      expect(createFailedMessage(notSaved),
          "Couldn't create fake contacts: your phone's storage is full.");
    });

    test('storage full: no "Try again"', () {
      expect(createFailedMessage(Exception(sFull)),
          "Couldn't create fake contacts: your phone's storage is full.");
      expect(createFailedMessage(stopped(0, 755, cause: Exception(sFull))),
          "Couldn't create fake contacts: your phone's storage is full.");
      expect(createFailedMessage(stopped(200, 755, cause: Exception(sFull))),
          'Created 200 of 755 fake contacts before your phone ran out of'
          ' storage.');
      expect(deleteFailedMessage(Exception(sFull)),
          "Couldn't delete fake contacts: your phone's storage is full.");
      expect(deleteFailedMessage(stopped(null, 4, cause: Exception(sFull))),
          "Couldn't finish deleting fake contacts: your phone's storage is"
          " full.");
      expect(deleteFailedMessage(stopped(900, 2000, cause: Exception(sFull))),
          'Deleted 900 of 2000 fake contacts before your phone ran out of'
          ' storage.');
    });

    test('storage full is told by SQLite\'s message, old or new', () {
      expect(storageFull(Exception(sFull)), isTrue);
      // Older Android versions leave out the name of the code.
      expect(storageFull(Exception('database or disk is full (code 13)')),
          isTrue);
      expect(storageFull(stopped(1, 2, cause: Exception(sFull))), isTrue);
      expect(storageFull(Exception('disk I/O error (code 10)')), isFalse);
      // Only what stopped it counts, not how far it got.
      expect(storageFull(stopped(1, 2)), isFalse);
    });

    test("how far it got isn't known", () {
      // The next Create or Delete records what it made (see
      // PendingCreate).
      expect(createFailedMessage(stopped(null, 4)),
          "Couldn't finish creating fake contacts. Try again.");
      expect(createFailedMessage(stopped(null, 4, cause: Exception(sFull))),
          "Couldn't finish creating fake contacts: your phone's storage is"
          " full.");
      expect(deleteFailedMessage(stopped(null, 4)),
          "Couldn't finish deleting fake contacts. Try again.");
    });

    test('never show the error itself', () {
      const sDetail = 'PlatformException(flutter_contacts_error)';
      for (final error in [
        Exception(sDetail),
        stopped(null, 4, cause: Exception(sDetail)),
        stopped(2, 4, cause: Exception(sDetail)),
        Exception(sFull),
        stopped(2, 4, cause: Exception(sFull)),
      ]) {
        for (final message in [
          createFailedMessage(error),
          deleteFailedMessage(error),
        ]) {
          expect(message, isNot(contains('flutter_contacts')));
          expect(message, isNot(contains('Exception')));
          expect(message, isNot(contains('SQLITE')));
        }
      }
    });
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
      expect(nothingToCreateMessage(toCreate(0, alreadyExisted: 756),
              settingsMake(27, 28)),
          'Nothing to create. 756 fake contacts already exist.');
      expect(nothingToCreateMessage(toCreate(0, alreadyExisted: 1),
              settingsMake(1, 1)),
          'Nothing to create. 1 fake contact already exists.');
    });

    test('no names: says which list is empty, as the preview does', () {
      expect(nothingToCreateMessage(toCreate(0), settingsMake(0, 0)),
          'Nothing to create. Enter at least one last name and one first name.');
      expect(nothingToCreateMessage(toCreate(0), settingsMake(0, 28)),
          'Nothing to create. Enter at least one last name.');
      expect(nothingToCreateMessage(toCreate(0), settingsMake(27, 0)),
          'Nothing to create. Enter at least one first name.');
      // Never a hint to fill in a list that has names.
      expect(() => nothingToCreateMessage(toCreate(0), settingsMake(2, 2)),
          throwsAssertionError);
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

  group('stopped by the user (U8)', () {
    test('says how far it got, and anything else as usual', () {
      expect(createdMessage(created(312, stoppedOf: 756)),
          'Stopped after creating 312 of 756 fake contacts.');
      expect(createdMessage(created(100, alreadyExisted: 4, stoppedOf: 200)),
          'Stopped after creating 100 of 200 fake contacts. 4 already existed.');
      expect(createdMessage(created(1, stoppedOf: 2)),
          'Stopped after creating 1 of 2 fake contacts.');
      expect(deletedMessage(deleted(300, stoppedOf: 756)),
          'Stopped after deleting 300 of 756 fake contacts.');
      expect(deletedMessage(deleted(200, merged: 1, stoppedOf: 400)),
          'Stopped after deleting 200 of 400 fake contacts. 1 was merged with'
          ' another contact and was left alone.');
    });
  });

  test('progress (U8)', () {
    expect(progressText(creating: true, done: 312, total: 756),
        'Created 312 of 756');
    expect(progressText(creating: false, done: 0, total: 1000),
        'Deleted 0 of 1000');
  });

  group('which results are failures (U7)', () {
    StoppedPartway stopped(int? done) => StoppedPartway(
        done: done,
        planned: 4,
        cause: 'provider gone',
        stackTrace: StackTrace.empty);

    test('results, also stopped ones, notes about fakes left alone, '
        'nothing to do, and answers the user gave: no', () {
      for (final message in [
        messages.createdMessage(created(4)),
        messages.createdMessage(created(2, alreadyExisted: 2)),
        messages.createdMessage(created(2, stoppedOf: 4)),
        messages.deletedMessage(deleted(4)),
        messages.deletedMessage(deleted(2, stoppedOf: 4)),
        messages.deletedMessage(deleted(3, merged: 1)),
        messages.deletedMessage(deleted(3, changed: 1)),
        messages.nothingToCreateMessage(
            toCreate(0, alreadyExisted: 4), settingsMake(2, 2)),
        messages.nothingToCreateMessage(toCreate(0), settingsMake(0, 2)),
        messages.nothingToDeleteMessage(toDelete(0)),
        messages.nothingToDeleteMessage(toDelete(0, merged: 1)),
        // The app refused on purpose.
        messages.kChangedMeanwhileMessage,
        messages.kPermissionDeniedMessage,
      ]) {
        expect(message.isError, isFalse, reason: message.text);
      }
    });

    test('anything that went wrong, also partway, and fakes created but not '
        'recorded: yes', () {
      for (final message in [
        messages.createdMessage(created(4, untracked: 1)),
        messages.createFailedMessage(Exception('x')),
        messages.createFailedMessage(stopped(2)),
        messages.createFailedMessage(stopped(null)),
        messages.deleteFailedMessage(Exception('x')),
        messages.deleteFailedMessage(stopped(2)),
        messages.deleteFailedMessage(stopped(null)),
        messages.kReadFailedMessage,
        messages.kPermissionRequestFailedMessage,
        messages.kOpenSettingsFailedMessage,
      ]) {
        expect(message.isError, isTrue, reason: message.text);
      }
    });

    test('equality includes the kind', () {
      expect(const messages.ResultMessage('x'),
          const messages.ResultMessage('x'));
      expect(const messages.ResultMessage('x'),
          isNot(const messages.ResultMessage.error('x')));
      expect(const messages.ResultMessage.error('x').toString(),
          'ResultMessage(error: x)');
    });
  });
}
