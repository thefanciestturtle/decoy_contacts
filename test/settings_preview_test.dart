// previewSettings: what the settings make, for the preview under the fields.

import 'package:decoy_contacts/contact_actions.dart';
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'in_memory_contacts_gateway.dart';

Settings settings({
  String last = 'Zen, Zima',
  String first = 'Zoe, Zach',
  String phone = kDefaultPhoneTemplate,
  String email = kDefaultEmailTemplate,
}) =>
    Settings(
      lastNamesText: last,
      firstNamesText: first,
      phoneTemplateText: phone,
      emailTemplateText: email,
    );

void main() {
  test('the defaults: 27 last names x 28 first names, starting with Zoe Zen',
      () {
    final preview = previewSettings(Settings.defaults);
    expect(preview.lastNameCount, 27);
    expect(preview.firstNameCount, 28);
    expect(preview.combinations, 756);
    expect(preview.sample,
        (name: 'Zoe Zen', phone: '+447700900010', email: 'Zoe.Zen@example.com'));
  });

  test('counts each name once, as Create does', () {
    final preview = previewSettings(
        settings(last: ' Zen, Zima,, Zen ,', first: 'Zoe,Zoe, ,Zach'));
    expect((preview.lastNameCount, preview.firstNameCount, preview.combinations),
        (2, 2, 4));
  });

  test('the example is the first last name with the first first name', () {
    expect(previewSettings(settings(last: 'Zima, Zen', first: 'Zach, Zoe'))
            .sample,
        (name: 'Zach Zima', phone: '+447700900059', email: 'Zach.Zima@example.com'));
  });

  test('templates are trimmed; an empty one means no phone or email', () {
    expect(
        previewSettings(settings(phone: '  +447700900nnn ', email: ' ')).sample,
        (name: 'Zoe Zen', phone: '+447700900010', email: ''));
    expect(previewSettings(settings(phone: '', email: 'LAST@example.org')).sample,
        (name: 'Zoe Zen', phone: '', email: 'Zen@example.org'));
  });

  test('no example when either name list is empty', () {
    for (final (last, first) in [('', 'Zoe'), ('Zen', ' , '), ('', '')]) {
      final preview = previewSettings(settings(last: last, first: first));
      expect(preview.sample, isNull, reason: '"$last" / "$first"');
      expect(preview.combinations, 0);
    }
    expect(previewSettings(settings(last: '')).firstNameCount, 2);
    expect(previewSettings(settings(first: '')).lastNameCount, 2);
  });

  test('long lists', () {
    final names = [for (var i = 0; i < 2000; i++) 'Z$i'].join(',');
    final preview = previewSettings(settings(last: names, first: names));
    expect(preview.combinations, 4000000);
    expect(preview.sample!.name, 'Z0 Z0');
  });

  group('the example is exactly the first contact Create makes', () {
    for (final (what, s) in [
      ('defaults', Settings.defaults),
      ('untidy lists, custom templates', settings(
          last: ' Zima ,Zen,Zima', first: ',Zach , Zoe',
          phone: ' +1 555 01nn ', email: 'first-LAST.FIRST@example.net')),
      ('no phone, no email', settings(phone: ' ', email: '')),
      ('a template without placeholders', settings(phone: '+447700900123')),
    ]) {
      test(what, () async {
        SharedPreferences.setMockInitialValues({});
        final book = InMemoryContactsGateway();
        final result =
            await createFakeContacts(book, const LedgerStore(), s);
        expect(result!.created, previewSettings(s).combinations);

        final sample = previewSettings(s).sample!;
        // The first contact of the first call (chunk).
        final first = book.createAllCalls.first.first;
        expect(
            (
              name: '${first.first} ${first.last}',
              phone: first.phone,
              email: first.email
            ),
            sample);
      });
    }
  });
}
