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
    test('none for the defaults, an empty template or usual separators and '
        'dial characters', () {
      for (final t in [
        kDefaultPhoneTemplate,
        '',
        '+44 7700 900nnn',
        '(555) 01nn-nnnn',
        '555.01nn',
        '089/1234nn',
        '*67 555 01nn',
        '+1 555 01nn#',
        '555 01nn,123',
        '555 01nn;123',
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
      expect(phoneTemplateWarning('+44@7700_900nnn@'),
          'A phone number can\'t contain "@" or "_".');
      expect(phoneTemplateWarning('abc nnn'),
          'A phone number can\'t contain "a", "b" or "c".');
    });

    test('an emoji is named whole', () {
      expect(phoneTemplateWarning('+44 7700 \u{1F4DE} nnn'),
          'A phone number can\'t contain "\u{1F4DE}".');
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
        "fake-FIRST_LAST+1@example.com",
        "o'FIRST@example.com",
        'someone@example.com',
        'FIRST@LAST.example.com',
        'FIRST@my-domain.example',
        'José@example.com',
        'FIRST@bücher.example',
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
        'FIRST,LAST@example.com',
        'FIRST<LAST>@example.com',
        'FIRST"x@example.com',
        'FIRST@exa_mple.com',
        'FIRST@-example.com',
        'FIRST@example-.com',
      ]) {
        expect(email(t), kNotAnAddress, reason: t);
      }
    });

    test('names that can\'t be part of an address, only for the placeholders '
        'the template uses', () {
      String one(String name) => '"$name" can\'t be part of an email address,'
          ' so those addresses won\'t work.';
      expect(email(kDefaultEmailTemplate, first: ['Zoe', 'Mary Ann']),
          one('Mary Ann'));
      expect(email(kDefaultEmailTemplate, last: ['Zen', 'Van Dyke']),
          one('Van Dyke'));
      // Next to the dot in FIRST.LAST, "J." gives "J..Zen".
      expect(email(kDefaultEmailTemplate, first: ['J.']), one('J.'));
      expect(email(kDefaultEmailTemplate, first: ['Zoe@home']), one('Zoe@home'));
      // An apostrophe is fine before the @, not in a domain.
      expect(email(kDefaultEmailTemplate, last: ["O'Brien"]), isNull);
      expect(email('info@LAST.com', last: ["O'Brien"]), one("O'Brien"));
      // Accented names are fine.
      expect(email(kDefaultEmailTemplate, first: ['Zoë', 'José']), isNull);
      expect(email('LAST@example.com', first: ['Mary Ann']), isNull);
      expect(email('FIRST@example.com', last: ['Van Dyke']), isNull);
      expect(email('someone@example.com', first: ['Mary Ann']), isNull);
    });

    test('several such names', () {
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Zoe'], last: ['Van Dyke']),
          '"Mary Ann" and 1 other name can\'t be part of an email address, so '
          'those addresses won\'t work.');
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Ann\tMarie'], last: ['Van Dyke']),
          '"Mary Ann" and 2 other names can\'t be part of an email address, '
          'so those addresses won\'t work.');
      // A name in both lists counts once.
      expect(
          email(kDefaultEmailTemplate, first: ['Lee Ann'], last: ['Lee Ann']),
          '"Lee Ann" can\'t be part of an email address, so those addresses '
          'won\'t work.');
    });

    test('a template that isn\'t an address says only that', () {
      expect(email('FIRST.LAST', first: ['Mary Ann']), kNotAnAddress);
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
