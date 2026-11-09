import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/input_checks.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

const String kNoN = 'There is no n, so every contact gets the same number.';
const String kNotAnAddress =
    "This doesn't look like an email address (FIRST.LAST@example.com).";

String? email(String template,
        {List<String> first = const ['Zoe'], List<String> last = const ['Zen']}) =>
    emailTemplateWarning(template, firstNames: first, lastNames: last);

void main() {
  group('phoneTemplateWarning', () {
    test('none for the defaults, an empty template or usual separators', () {
      for (final t in [
        kDefaultPhoneTemplate,
        '',
        '+44 7700 900nnn',
        '(555) 01nn-nnnn',
        '555.01nn',
      ]) {
        expect(phoneTemplateWarning(t), isNull, reason: t);
      }
    });

    test('no n: every contact gets the same number', () {
      expect(phoneTemplateWarning('+447700900123'), kNoN);
    });

    test('characters a phone number can\'t have, each named once', () {
      expect(phoneTemplateWarning('+44 7700 900nnx'),
          'A phone number can\'t contain "x".');
      expect(phoneTemplateWarning('+44#7700*900nnn#'),
          'A phone number can\'t contain "#" or "*".');
      expect(phoneTemplateWarning('abc nnn'),
          'A phone number can\'t contain "a", "b" or "c".');
    });

    test('both, e.g. a capital N', () {
      expect(phoneTemplateWarning('+447700900NNN'),
          'A phone number can\'t contain "N".\n$kNoN');
    });
  });

  group('emailTemplateWarning', () {
    test('none for the default, an empty template or other addresses', () {
      for (final t in [
        kDefaultEmailTemplate,
        '',
        'FIRST@example.org',
        'LAST.FIRST@mail.example.net',
        'fake-FIRST_LAST+1@example.com',
        'someone@example.com',
      ]) {
        expect(email(t), isNull, reason: t);
      }
    });

    test('not an address', () {
      for (final t in [
        'FIRST.LAST',
        'FIRST.LAST@',
        '@example.com',
        'FIRST@@example.com',
        'FIRST@LAST@example.com',
        'FIRST@localhost',
        'FIRST LAST@example.com',
        'FIRST..LAST@example.com',
        '.FIRST@example.com',
        'FIRST@example..com',
        'FIRST@.example.com',
        'FIRST@example.com.',
      ]) {
        expect(email(t), kNotAnAddress, reason: t);
      }
    });

    test('names with spaces, only for the placeholders the template uses', () {
      expect(email(kDefaultEmailTemplate, first: ['Zoe', 'Mary Ann']),
          '"Mary Ann" has a space, so those email addresses won\'t work.');
      expect(email(kDefaultEmailTemplate, last: ['Zen', 'Van Dyke']),
          '"Van Dyke" has a space, so those email addresses won\'t work.');
      expect(email('LAST@example.com', first: ['Mary Ann']), isNull);
      expect(email('FIRST@example.com', last: ['Van Dyke']), isNull);
      expect(email('someone@example.com', first: ['Mary Ann']), isNull);
    });

    test('several names with spaces', () {
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Zoe'], last: ['Van Dyke']),
          '"Mary Ann" and 1 other name have spaces, so those email addresses '
          'won\'t work.');
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Ann\tMarie'], last: ['Van Dyke']),
          '"Mary Ann" and 2 other names have spaces, so those email '
          'addresses won\'t work.');
      // A name in both lists counts once.
      expect(
          email(kDefaultEmailTemplate, first: ['Lee Ann'], last: ['Lee Ann']),
          '"Lee Ann" has a space, so those email addresses won\'t work.');
    });

    test('both', () {
      expect(email('FIRST.LAST', first: ['Mary Ann']),
          '$kNotAnAddress\n"Mary Ann" has a space, so those email addresses '
          'won\'t work.');
    });
  });

  test('the defaults give no warnings at all', () {
    const s = Settings.defaults;
    expect(phoneTemplateWarning(s.phoneTemplate), isNull);
    expect(
        emailTemplateWarning(s.emailTemplate,
            firstNames: s.firstNames, lastNames: s.lastNames),
        isNull);
  });
}
