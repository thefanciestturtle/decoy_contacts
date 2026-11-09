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

    test('a long list of characters is cut short', () {
      expect(phoneTemplateWarning('abcdefgh nnn'),
          'A phone number can\'t contain "a", "b", "c", "d", "e" or 3 more.');
    });

    test('an emoji with a skin tone, and a letter with an accent, are named '
        'whole', () {
      expect(phoneTemplateWarning('+44 \u{1F44D}\u{1F3FD} nnn'),
          'A phone number can\'t contain "\u{1F44D}\u{1F3FD}".');
      expect(phoneTemplateWarning('+44 7700 900nn\u0301'),
          'A phone number can\'t contain "n\u0301".');
      // A lone accent can't be seen on its own.
      expect(phoneTemplateWarning('\u0301+44 7700 900nnn'),
          'A phone number can\'t contain U+0301.');
    });

    test('characters that can\'t be seen are named by their code', () {
      expect(phoneTemplateWarning('+44\u200B7700\u00A0900nnn'),
          'A phone number can\'t contain U+200B or U+00A0.');
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
        'FIRST@LAST.example.com',
        'FIRST@my-domain.example',
        'José.FIRST@example.com',
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
    });

    test('no FIRST or LAST: every contact gets the same address', () {
      const kSame =
          'There is no FIRST or LAST, so every contact gets the same address.';
      for (final t in ['someone@example.com', 'first.last@example.com']) {
        expect(email(t, first: ['Mary Ann']), kSame, reason: t);
      }
    });

    test('only accented letters pass, not other non-ASCII characters', () {
      String one(String name) => '"$name" can\'t be part of an email address,'
          ' so those addresses won\'t work.';
      // A curly apostrophe (as autocorrect types it) in a domain.
      expect(email('FIRST@LAST.com', last: ['O\u2019Brien']),
          one('O\u2019Brien'));
      // A zero-width space, which isn't white space, and is named so it
      // can be seen.
      expect(email(kDefaultEmailTemplate, first: ['Zo\u200Be']),
          one('Zo<U+200B>e'));
      expect(email(kDefaultEmailTemplate, first: ['Zoe\u{1F600}']),
          one('Zoe\u{1F600}'));
      expect(email('FIRST@LAST.com', last: ['Müller', 'Жуков']), isNull);
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

    test('length limits: 64 before the @, 63 per domain label, 254 in all',
        () {
      expect(email('${'x' * 63}FIRST@example.com', first: ['']), isNull);
      expect(email('${'x' * 64}FIRST@example.com'), kNotAnAddress);
      expect(email('FIRST@${'x' * 63}.example'), isNull);
      expect(email('FIRST@${'x' * 64}.example'), kNotAnAddress);
      final long = List.filled(5, 'x' * 60).join('.');
      expect(email('FIRST@$long.com'), kNotAnAddress);
      expect(email(kDefaultEmailTemplate, first: ['Z' * 70]),
          '"${'Z' * 70}" can\'t be part of an email address, so those '
          'addresses won\'t work.');
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
