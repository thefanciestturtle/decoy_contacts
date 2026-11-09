import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const store = SettingsStore();

  Future<Map<String, Object?>> stored() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final k in prefs.getKeys()) k: prefs.get(k)};
  }

  test('first run gives the defaults and saves them', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await store.load(), Settings.defaults);
    expect(await stored(), {
      'sListOfLastNames': kDefaultLastNames,
      'sListOfFirstNames': kDefaultFirstNames,
      'sPhoneNumberTemplate': kDefaultPhoneTemplate,
      'sEmailAddressTemplate': kDefaultEmailTemplate,
    });
  });

  test('defaults: 27 last names x 28 first names', () {
    expect(Settings.defaults.lastNames, hasLength(27));
    expect(Settings.defaults.firstNames, hasLength(28));
    expect(Settings.defaults.phoneTemplate, kDefaultPhoneTemplate);
  });

  test('stored settings are read as they are', () async {
    final values = {
      'sListOfLastNames': ' Zen , Zima',
      'sListOfFirstNames': 'Zoe',
      'sPhoneNumberTemplate': ' +15555550nnn ',
      'sEmailAddressTemplate': 'FIRST@example.org',
    };
    SharedPreferences.setMockInitialValues(values);
    final s = await store.load();
    expect(s.lastNamesText, ' Zen , Zima');
    expect(s.lastNames, ['Zen', 'Zima']);
    expect(s.firstNames, ['Zoe']);
    expect(s.phoneTemplateText, ' +15555550nnn ');
    expect(s.phoneTemplate, '+15555550nnn');
    expect(s.emailTemplate, 'FIRST@example.org');
    expect(await stored(), values);
  });

  test('missing values after the last names read as empty', () async {
    SharedPreferences.setMockInitialValues({'sListOfLastNames': 'Zen'});
    final s = await store.load();
    expect(s.firstNamesText, '');
    expect(s.phoneTemplateText, '');
    expect(s.emailTemplateText, '');
    // Nothing to migrate, so nothing is written.
    expect(await stored(), {'sListOfLastNames': 'Zen'});
  });

  test('the old +213 default phone template is migrated and saved', () async {
    SharedPreferences.setMockInitialValues({
      'sListOfLastNames': 'Zen',
      'sListOfFirstNames': 'Zoe',
      'sPhoneNumberTemplate': kLegacyDefaultPhoneTemplate,
      'sEmailAddressTemplate': kDefaultEmailTemplate,
    });
    final s = await store.load();
    expect(s.phoneTemplateText, kDefaultPhoneTemplate);
    expect(s.lastNamesText, 'Zen');
    expect((await stored())['sPhoneNumberTemplate'], kDefaultPhoneTemplate);
  });

  test('save then load round-trips', () async {
    SharedPreferences.setMockInitialValues({});
    const s = Settings(
      lastNamesText: 'A,B',
      firstNamesText: 'C',
      phoneTemplateText: '+447700900nnn',
      emailTemplateText: '',
    );
    await store.save(s);
    expect(await store.load(), s);
  });

  test('LedgerStore round-trips and reads a missing ledger as empty', () async {
    SharedPreferences.setMockInitialValues({});
    const ledgers = LedgerStore();
    expect((await ledgers.load()).isEmpty, isTrue);
    final ledger = Ledger({'7': const LedgerEntry('Zoe Zen', '+1', 'z@x')});
    await ledgers.save(ledger);
    expect((await ledgers.load()).entries, ledger.entries);
  });
}
