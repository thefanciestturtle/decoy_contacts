// Checks of the template fields as typed, shown under the field they
// concern. Warnings only: they never stop Create (only empty name lists do,
// and the preview says why). No Flutter imports, so they can be unit tested
// directly.

import 'package:characters/characters.dart';

import 'fake_contacts_core.dart';

/// Characters a phone number template may have: digits, the `n`
/// placeholder, the usual separators (space - ( ) . /), and what dial
/// strings use (+ * # and the pauses , ;).
/// (A whole character must match, so an "n" with an accent doesn't.)
final RegExp _phoneTemplateCharacter = RegExp(r'^[0-9n+ \-().\/*#,;]$');

final RegExp _whitespace = RegExp(r'\s');

/// Non-ASCII letters and their accents ("é", "ß", "ж"), which may be part
/// of an address; other non-ASCII characters (a curly apostrophe, an
/// emoji, a zero-width space) may not.
final RegExp _nonAsciiLetter = RegExp(r'(?![\x00-\x7F])[\p{L}\p{M}]', unicode: true);

/// Characters that can't be seen when quoted on their own: spaces other
/// than " ", controls, formatting characters such as a zero-width space,
/// and lone accents or variation selectors.
final RegExp _invisible = RegExp(r'^[\p{C}\p{Z}\p{M}]+$', unicode: true);

/// Bad phone characters named in a warning before "and N more".
const int _kNamedAtMost = 5;

/// Characters allowed in the part of an address before the @ (RFC 5322
/// "atext"; dots are checked separately). Non-ASCII letters are allowed too,
/// as in "José", which mail systems increasingly accept.
final RegExp _localCharacters = RegExp(r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~\-]+$");

/// A domain label: letters, digits and hyphens, not at either end.
final RegExp _domainLabel = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?$');

/// A warning about the phone number template (already trimmed), or null.
/// An empty template is fine: the fakes get no phone number.
String? phoneTemplateWarning(String template) {
  if (template.isEmpty) return null;
  final bad = <String>{
    // Whole characters as the user sees them, so an emoji (with its skin
    // tone) or a letter with its accent isn't split up.
    for (final c in template.characters)
      if (!_phoneTemplateCharacter.hasMatch(c)) c,
  };
  return _lines([
    if (bad.isNotEmpty) "A phone number can't contain ${_orList(bad.toList())}.",
    if (!template.contains('n'))
      "There is no n, so every contact gets the same number.",
  ]);
}

/// How a character is named in a warning: in quotes, or by its code
/// (U+200B) if it can't be seen.
String _named(String c) =>
    _invisible.hasMatch(c) ? _codes(c) : '"$c"';

/// A name in quotes, with the characters in it that can't be seen given by
/// their code: `"Zoe<U+200B>"`. Plain spaces stay spaces.
String _quotedName(String name) => '"${[
      for (final c in name.characters)
        c != ' ' && _invisible.hasMatch(c) ? '<${_codes(c)}>' : c,
    ].join()}"';

String _codes(String c) => c.runes
    .map((r) => 'U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}')
    .join(' ');

/// A warning about the email address template (already trimmed), or null.
/// An empty template is fine: the fakes get no email address.
///
/// Names are only checked if the template uses them (FIRST for
/// [firstNames], LAST for [lastNames]): each in turn, with a plain "a" for
/// the other placeholder, so a name that can't be part of an address (a
/// space, "J." next to the dot in FIRST.LAST, an @) is found.
String? emailTemplateWarning(String template,
    {required List<String> firstNames, required List<String> lastNames}) {
  if (template.isEmpty) return null;
  String fill({String first = 'a', String last = 'a'}) =>
      generateEmailAddress(template, first, last);
  if (!_looksLikeAnAddress(fill())) {
    return "This doesn't look like an email address (FIRST.LAST@example.com).";
  }
  if (!template.contains('FIRST') && !template.contains('LAST')) {
    return "There is no FIRST or LAST, so every contact gets the same address.";
  }
  final unusable = {
    if (template.contains('FIRST'))
      ...firstNames.where((n) => !_looksLikeAnAddress(fill(first: n))),
    if (template.contains('LAST'))
      ...lastNames.where((n) => !_looksLikeAnAddress(fill(last: n))),
  }.toList();
  if (unusable.isEmpty) return null;
  final others = unusable.length - 1;
  final sFirst = _quotedName(unusable.first);
  return others == 0
      ? "$sFirst can't be part of an email address, so those addresses won't"
          " work."
      : "$sFirst and $others other ${others == 1 ? "name" : "names"} can't be"
          " part of an email address, so those addresses won't work.";
}

/// name@example.com: one @; before it, dot-separated parts of allowed
/// characters; after it, at least two dot-separated labels of letters,
/// digits and inner hyphens. Non-ASCII letters are allowed on both sides.
/// Within the usual limits: 64 characters before the @, 63 per domain
/// label, 254 in all.
bool _looksLikeAnAddress(String address) {
  final parts = address.split('@');
  if (parts.length != 2 || address.contains(_whitespace)) return false;
  if (address.length > 254 || parts[0].length > 64) return false;
  bool allowed(String part, RegExp ascii) =>
      ascii.hasMatch(part.replaceAll(_nonAsciiLetter, 'a'));
  final local = parts[0].split('.');
  final domain = parts[1].split('.');
  return local.every((p) => p.isNotEmpty && allowed(p, _localCharacters)) &&
      domain.length >= 2 &&
      domain.every((p) => p.length <= 63 && allowed(p, _domainLabel));
}

/// '"a"', '"a" or "b"', '"a", "b" or "c"', and after [_kNamedAtMost]
/// characters '"a", "b", "c", "d", "e" or 3 more'.
String _orList(List<String> items) {
  final named = [for (final i in items.take(_kNamedAtMost)) _named(i)];
  final more = items.length - named.length;
  if (more > 0) return '${named.join(', ')} or $more more';
  if (named.length == 1) return named.single;
  return '${named.sublist(0, named.length - 1).join(', ')} or ${named.last}';
}

String? _lines(List<String> lines) => lines.isEmpty ? null : lines.join('\n');
