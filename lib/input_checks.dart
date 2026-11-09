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

/// Code points that can't be seen: spaces other than " ", controls and
/// formatting characters such as a zero-width space or joiner.
final RegExp _hidden = RegExp(r'^[\p{C}\p{Z}]$', unicode: true);

/// A lone accent or variation selector, which can't be seen on its own.
final RegExp _mark = RegExp(r'^\p{M}$', unicode: true);

/// Bad phone characters named in a warning before "or N more".
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
    _isInvisible(c) ? c.runes.map(_code).join(' ') : _quoted(c);

/// [text] in quotes, with each code point that can't be seen given by its
/// code (`"Zoe<U+200B>"`, also when it is joined to the letter before it,
/// as a zero-width joiner is). Plain spaces stay spaces, accents stay on
/// their letters, and a lone accent is given by its code too.
String _quoted(String text) => '"${[
      for (final c in text.characters)
        if (_isInvisible(c))
          '<${c.runes.map(_code).join(' ')}>'
        else
          [
            for (final r in c.runes)
              _hidden.hasMatch(String.fromCharCode(r)) && r != 0x20
                  ? '<${_code(r)}>'
                  : String.fromCharCode(r),
          ].join(),
    ].join()}"';

/// A character the user sees nothing of: only hidden code points and lone
/// accents (but not a plain space).
bool _isInvisible(String c) =>
    c != ' ' &&
    c.runes.every((r) {
      final s = String.fromCharCode(r);
      return _hidden.hasMatch(s) || _mark.hasMatch(s);
    });

String _code(int rune) =>
    'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}';

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
  if (unusable.isEmpty) {
    // Each name works with a short one for the other placeholder; the
    // longest of both together may still be too long.
    if (!template.contains('FIRST') || !template.contains('LAST') ||
        firstNames.isEmpty || lastNames.isEmpty) {
      return null;
    }
    String longest(List<String> names) =>
        names.reduce((a, b) => b.length > a.length ? b : a);
    final first = longest(firstNames), last = longest(lastNames);
    if (_withinLimits(fill(first: first, last: last))) return null;
    return "${_quoted(first)} with ${_quoted(last)} makes an email address"
        " that's too long to work.";
  }
  final others = unusable.length - 1;
  final sFirst = _quoted(unusable.first);
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
  if (!_withinLimits(address)) return false;
  bool allowed(String part, RegExp ascii) =>
      ascii.hasMatch(part.replaceAll(_nonAsciiLetter, 'a'));
  final local = parts[0].split('.');
  final domain = parts[1].split('.');
  return local.every((p) => p.isNotEmpty && allowed(p, _localCharacters)) &&
      domain.length >= 2 &&
      domain.every((p) => allowed(p, _domainLabel));
}

/// Within the length limits: 254 characters in all, 64 before the last @,
/// 63 per label after it.
bool _withinLimits(String address) {
  final at = address.lastIndexOf('@');
  return address.length <= 254 &&
      at <= 64 &&
      address.substring(at + 1).split('.').every((l) => l.length <= 63);
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
