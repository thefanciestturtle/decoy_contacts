import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/input_checks.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

const String kNoN = 'There is no n, so every contact gets the same number.';
const String kNotAnAddress =
    "This doesn't look like an email address (FIRST.LAST@example.com).";

String? email(String template,
        {List<String> first = const ['Zoe'], List<String> last = const ['Zen']}) =>
    EmailTemplateCheck(template).warning(firstNames: first, lastNames: last);

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
          'A phone number can\'t contain “x”.');
      expect(phoneTemplateWarning('+44@7700_900nnn@'),
          'A phone number can\'t contain “@” or “_”.');
      expect(phoneTemplateWarning('abc nnn'),
          'A phone number can\'t contain “a”, “b” or “c”.');
    });

    test('an emoji is named whole', () {
      expect(phoneTemplateWarning('+44 7700 \u{1F4DE} nnn'),
          'A phone number can\'t contain “\u{1F4DE}”.');
    });

    test('a long list of characters is cut short', () {
      expect(phoneTemplateWarning('abcdefgh nnn'),
          'A phone number can\'t contain “a”, “b”, “c”, “d”, “e” or 3 more.');
    });

    test('a joiner after a variation selector or a virama is shown as typed',
        () {
      // 🏳️‍🌈: white flag, variation selector, joiner, rainbow.
      expect(phoneTemplateWarning('+44 \u{1F3F3}\uFE0F\u200D\u{1F308} nnn'),
          'A phone number can\'t contain “\u{1F3F3}\uFE0F\u200D\u{1F308}”.');
      // क्‍ष, flagged here for the space before it.
      expect(email(kDefaultEmailTemplate, first: ['A \u0915\u094D\u200D\u0937']),
          '“A \u0915\u094D\u200D\u0937” can\'t be part of an email address, '
          'so those addresses won\'t work.');
    });

    test('a straight quote and an emoji sequence are shown as typed', () {
      expect(phoneTemplateWarning('+44 "7700" nnn'),
          'A phone number can\'t contain “"”.');
      expect(phoneTemplateWarning('+44 \u{1F468}\u200D\u{1F469}\u200D\u{1F467} nnn'),
          'A phone number can\'t contain '
          '“\u{1F468}\u200D\u{1F469}\u200D\u{1F467}”.');
    });

    test('an emoji with a skin tone, and a letter with an accent, are named '
        'whole', () {
      expect(phoneTemplateWarning('+44 \u{1F44D}\u{1F3FD} nnn'),
          'A phone number can\'t contain “\u{1F44D}\u{1F3FD}”.');
      expect(phoneTemplateWarning('+44 7700 900nn\u0301'),
          'A phone number can\'t contain “n\u0301”.');
      // A lone accent can't be seen on its own.
      expect(phoneTemplateWarning('\u0301+44 7700 900nnn'),
          'A phone number can\'t contain “<U+0301>”.');
      // A zero-width joiner joins the digit before it, and is named.
      expect(phoneTemplateWarning('+44 1\u200Dnnn'),
          'A phone number can\'t contain “1<U+200D>”.');
    });

    test('characters that can\'t be seen are named by their code', () {
      expect(phoneTemplateWarning('+44\u200B7700\u00A0900nnn'),
          'A phone number can\'t contain “<U+200B>” or “<U+00A0>”.');
    });

    test('both, e.g. a capital N', () {
      expect(phoneTemplateWarning('+447700900NNN'),
          'A phone number can\'t contain “N”.\n$kNoN');
    });
  });

  group('EmailTemplateCheck.warning', () {
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
      String one(String name) => '“$name” can\'t be part of an email address,'
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
      String one(String name) => '“$name” can\'t be part of an email address,'
          ' so those addresses won\'t work.';
      // A curly apostrophe (as autocorrect types it) in a domain.
      expect(email('FIRST@LAST.com', last: ['O\u2019Brien']),
          one('O\u2019Brien'));
      // A zero-width space, which isn't white space, and is named so it
      // can be seen.
      expect(email(kDefaultEmailTemplate, first: ['Zo\u200Be']),
          one('Zo<U+200B>e'));
      // Also when it joins the letter before it.
      expect(email(kDefaultEmailTemplate, first: ['Zoe\u200D']),
          one('Zoe<U+200D>'));
      expect(email(kDefaultEmailTemplate, first: ['Zoe\u200C']),
          one('Zoe<U+200C>'));
      expect(email(kDefaultEmailTemplate, first: ['Zoe\u{1F600}']),
          one('Zoe\u{1F600}'));
      expect(email('FIRST@LAST.com', last: ['Müller', 'Жуков']), isNull);
    });

    test('several such names', () {
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Zoe'], last: ['Van Dyke']),
          '“Mary Ann” and 1 other name can\'t be part of an email address, so '
          'those addresses won\'t work.');
      expect(
          email(kDefaultEmailTemplate,
              first: ['Mary Ann', 'Ann\tMarie'], last: ['Van Dyke']),
          '“Mary Ann” and 2 other names can\'t be part of an email address, '
          'so those addresses won\'t work.');
      // A name in both lists counts once.
      expect(
          email(kDefaultEmailTemplate, first: ['Lee Ann'], last: ['Lee Ann']),
          '“Lee Ann” can\'t be part of an email address, so those addresses '
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
          '“${'Z' * 70}” can\'t be part of an email address, so those '
          'addresses won\'t work.');
    });

    test('limits count bytes (UTF-8), not characters', () {
      // 40 Cyrillic letters are 80 bytes, more than 64 before the @.
      final name = 'ж' * 40;
      expect(email(kDefaultEmailTemplate, first: [name]),
          '“$name” can\'t be part of an email address, so those addresses '
          'won\'t work.');
      expect(email(kDefaultEmailTemplate, first: ['ж' * 20]), isNull);
    });

    test('joiners between letters are fine (Persian, Indic names)', () {
      expect(email(kDefaultEmailTemplate, first: ['علی\u200Cرضا']), isNull);
      expect(email(kDefaultEmailTemplate, first: ['क्\u200Dष']), isNull);
      // Not between ASCII letters, nor at the end of a name, where it only
      // hides.
      expect(email(kDefaultEmailTemplate, first: ['Zo\u200Ce']),
          '“Zo<U+200C>e” can\'t be part of an email address, so those '
          'addresses won\'t work.');
      expect(email(kDefaultEmailTemplate, first: ['Zoe\u200D']),
          '“Zoe<U+200D>” can\'t be part of an email address, so those '
          'addresses won\'t work.');
    });

    test('a bad name and a too-long pair are both named', () {
      final first = 'F' * 40, last = 'L' * 40;
      expect(
          email('FIRSTLAST@example.com',
              first: ['Mary Ann', first], last: [last]),
          '“Mary Ann” can\'t be part of an email address, so those addresses '
          'won\'t work.\n“$first” with “$last” makes an email address '
          'that\'s too long to work.');
    });

    test('a character outside the BMP counts once in a domain label', () {
      // 40 Gothic letters: 80 UTF-16 code units, but 40 characters.
      final gothic = '\u{10330}' * 40;
      expect(email('FIRST@LAST.example', last: [gothic]), isNull);
    });

    test('a domain label too long by characters, though not the longest '
        'names by bytes', () {
      // "é" is 2 bytes: by bytes the longest last name is the 20 é's, which
      // fit; by characters it is the 30 c's, which don't (35 + 30 > 63).
      final first = 'b' * 35, e = 'é' * 20, c = 'c' * 30;
      expect(email('x@FIRSTLAST.example', first: [first], last: [e, c]),
          '“$first” with “$c” makes an email address that\'s too long to '
          'work.');
    });

    test('the longest names together may be too long', () {
      final first = 'F' * 40, last = 'L' * 40;
      expect(email('FIRSTLAST@example.com', first: [first, 'Zoe'], last: [last]),
          '“$first” with “$last” makes an email address that\'s too long '
          'to work.');
      // Each one alone, or a short partner, is fine.
      expect(email('FIRSTLAST@example.com', first: [first], last: ['Zen']),
          isNull);
      expect(email('FIRST@LAST.example', first: [first], last: [last]), isNull);
    });

    test('a template that isn\'t an address says only that', () {
      expect(email('FIRST.LAST', first: ['Mary Ann']), kNotAnAddress);
    });
  });

  test('EmailTemplateCheck remembers names, and gives the same answers', () {
    final check = EmailTemplateCheck(kDefaultEmailTemplate);
    final names = [for (var i = 0; i < 3000; i++) 'Zname$i'];
    expect(check.warning(firstNames: names, lastNames: ['Zen']), isNull);
    // Adding one name: the same answer as a fresh check.
    final more = [...names, 'Mary Ann'];
    expect(check.warning(firstNames: more, lastNames: ['Zen']),
        email(kDefaultEmailTemplate, first: more, last: ['Zen']));
    // Only the new name was checked.
    expect(check.namesChecked, 3000 + 1 + 1);
  });

  test('with more than 100000 names, the memory isn\'t cleared on every call',
      () {
    final check = EmailTemplateCheck(kDefaultEmailTemplate);
    final names = [for (var i = 0; i < 101000; i++) 'Z$i'];
    check.warning(firstNames: names, lastNames: ['Zen']);
    final checked = check.namesChecked;
    check.warning(firstNames: [...names, 'Zoe'], lastNames: ['Zen']);
    expect(check.namesChecked, checked + 1);
  });

  test('the defaults give no warnings at all', () {
    const s = Settings.defaults;
    expect(phoneTemplateWarning(s.phoneTemplate), isNull);
    expect(
        email(s.emailTemplate, first: s.firstNames, last: s.lastNames),
        isNull);
  });
}
