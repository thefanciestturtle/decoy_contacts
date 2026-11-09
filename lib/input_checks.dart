// Checks of the template fields as typed, shown under the field they
// concern. Warnings only: they never stop Create (only empty name lists do,
// and the preview says why). No Flutter imports, so they can be unit tested
// directly.

import 'package:characters/characters.dart';

import 'fake_contacts_core.dart';

/// Characters a phone number template may have: digits, the `n`
/// placeholder, the usual separators (space - ( ) . /), and what dial
/// strings use (+ * # and the pauses , ;). A whole character must match,
/// so an "n" with an accent doesn't.
final RegExp _phoneTemplateCharacter = RegExp(r'^[0-9n+ \-().\/*#,;]$');

final RegExp _whitespace = RegExp(r'\s');

/// A name of ASCII letters and digits only.
final RegExp _plainName = RegExp(r'^[A-Za-z0-9]+$');

/// Non-ASCII letters and their accents ("é", "ß", "ж"), which may be part
/// of an address, and a zero-width joiner or non-joiner between two of
/// them, as Persian and Indic names use (not between ASCII letters, where
/// it only hides). Other non-ASCII characters (a curly apostrophe, an
/// emoji, a zero-width space) may not.
final RegExp _nonAsciiLetter = RegExp(
    r'(?![\x00-\x7F])[\p{L}\p{M}]'
    r'|(?<=(?![\x00-\x7F])[\p{L}\p{M}])[\u200C\u200D](?=(?![\x00-\x7F])[\p{L}\p{M}])',
    unicode: true);

/// A code point that can't be seen: a space other than " ", a control, or
/// a formatting character such as a zero-width space or joiner.
final RegExp _hidden = RegExp(r'^[\p{C}\p{Z}]$', unicode: true);

/// An accent or variation selector: seen only on the character before it.
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

/// Gives the warning about an email address template (already trimmed), or
/// null; an empty template is fine (the fakes get no email address). Checks
/// names against that one template, and remembers each name's result: with
/// a long name list, an edit then only checks the names that are new.
///
/// Names are only checked if the template uses them (FIRST for the first
/// names, LAST for the last names): each in turn, with a plain "a" for the
/// other placeholder, so a name that can't be part of an address (a space,
/// "J." next to the dot in FIRST.LAST, an @) is found. The longest first and
/// last names are also checked together against the length limits.
class EmailTemplateCheck {
  EmailTemplateCheck(this.template);

  final String template;

  /// Whether each name checked so far gives a usable address.
  final Map<String, bool> _firstOk = {};
  final Map<String, bool> _lastOk = {};

  /// How many names were checked, not remembered (for tests).
  int namesChecked = 0;

  /// Whether [name] gives a usable address in place of FIRST
  /// ([bFirst]) or LAST. Only called once the template itself, with "a"
  /// for both, looks like an address.
  bool _check(String name, {required bool bFirst}) {
    namesChecked++;
    final address = bFirst ? _fill(first: name) : _fill(last: name);
    // Letters and digits in place of the "a" change none of what makes an
    // address (no dots, @ or hyphens come in, and a label still starts and
    // ends with one), so only the length can break it. Most names are like
    // that, and this is much quicker than the full check.
    if (_plainName.hasMatch(name)) return _withinLimits(address);
    return _looksLikeAnAddress(address);
  }

  /// Names remembered beyond those in the lists before the memory is
  /// cleared: typing a name letter by letter adds every prefix.
  static const int _kRememberExtra = 10000;

  String _fill({String first = 'a', String last = 'a'}) =>
      generateEmailAddress(template, first, last);

  String? warning(
      {required List<String> firstNames, required List<String> lastNames}) {
    if (template.isEmpty) return null;
    if (!_looksLikeAnAddress(_fill())) {
      return "This doesn't look like an email address (FIRST.LAST@example.com).";
    }
    final bFirst = template.contains('FIRST'), bLast = template.contains('LAST');
    if (!bFirst && !bLast) {
      return "There is no FIRST or LAST, so every contact gets the same address.";
    }
    // Bounded by the lists' own size, so a long list doesn't clear it on
    // every call.
    if (_firstOk.length > firstNames.length + _kRememberExtra) _firstOk.clear();
    if (_lastOk.length > lastNames.length + _kRememberExtra) _lastOk.clear();
    final unusable = {
      if (bFirst)
        ...firstNames.where(
            (n) => !_firstOk.putIfAbsent(n, () => _check(n, bFirst: true))),
      if (bLast)
        ...lastNames.where(
            (n) => !_lastOk.putIfAbsent(n, () => _check(n, bFirst: false))),
    }.toList();
    final others = unusable.length - 1;
    return _lines([
      if (others == 0)
        "${_quoted(unusable.first)} can't be part of an email address, so"
            " those addresses won't work."
      else if (others > 0)
        "${_quoted(unusable.first)} and $others other"
            " ${others == 1 ? "name" : "names"} can't be part of an email"
            " address, so those addresses won't work.",
      if (bFirst && bLast)
        ?_tooLong([for (final n in firstNames) if (_firstOk[n]!) n],
            [for (final n in lastNames) if (_lastOk[n]!) n]),
    ]);
  }

  /// Names that each fit with a short one for the other placeholder may not
  /// fit together: the longest of both are checked, by bytes (the limits
  /// before the @ and in all) and by characters (the limit per domain
  /// label). Names that don't work on their own are already named, so they
  /// are left out here.
  String? _tooLong(List<String> firstNames, List<String> lastNames) {
    if (firstNames.isEmpty || lastNames.isEmpty) return null;
    String longest(List<String> names, int Function(String) size) =>
        names.reduce((a, b) => size(b) > size(a) ? b : a);
    for (final int Function(String) size in [_octets, _codePoints]) {
      final first = longest(firstNames, size), last = longest(lastNames, size);
      if (!_withinLimits(_fill(first: first, last: last))) {
        return "${_quoted(first)} with ${_quoted(last)} makes an email"
            " address that's too long to work.";
      }
    }
    return null;
  }
}

/// name@example.com: one @; before it, dot-separated parts of allowed
/// characters; after it, at least two dot-separated labels of letters,
/// digits and inner hyphens. Non-ASCII letters are allowed on both sides.
/// Within the length limits (see [_withinLimits]).
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

/// Within the length limits, which count bytes (UTF-8): 254 in all and 64
/// before the last @; and 63 characters (code points) per label after it.
/// (A non-ASCII label's real limit applies to its punycode form; this only
/// counts its characters.)
bool _withinLimits(String address) {
  final at = address.lastIndexOf('@');
  return _octets(address) <= 254 &&
      _octets(address.substring(0, at < 0 ? 0 : at)) <= 64 &&
      address.substring(at + 1).split('.').every((l) => _codePoints(l) <= 63);
}

int _codePoints(String s) => s.runes.length;

/// The length of [s] in UTF-8 bytes, without encoding it.
int _octets(String s) {
  var n = 0;
  for (final r in s.runes) {
    n += r < 0x80 ? 1 : (r < 0x800 ? 2 : (r < 0x10000 ? 3 : 4));
  }
  return n;
}

/// '“a”', '“a” or “b”', '“a”, “b” or “c”', and after [_kNamedAtMost]
/// characters '“a”, “b”, “c”, “d”, “e” or 3 more'.
String _orList(List<String> items) {
  final named = [for (final i in items.take(_kNamedAtMost)) _quoted(i)];
  final more = items.length - named.length;
  if (more > 0) return '${named.join(', ')} or $more more';
  if (named.length == 1) return named.single;
  return '${named.sublist(0, named.length - 1).join(', ')} or ${named.last}';
}

/// [text] in curly quotes (so a straight " in it can be told apart), with
/// each code point that can't be seen given by its code: `“Zoe<U+200B>”`.
/// Plain spaces stay spaces; accents stay on their letters, but a lone one
/// is given by its code; a joiner between two visible characters (an emoji
/// sequence, a Persian name) stays as it is.
String _quoted(String text) {
  final runes = text.runes.toList();
  final out = StringBuffer('“');
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    final s = String.fromCharCode(r);
    final bool bJoiner = r == 0x200C || r == 0x200D;
    final bool bShowCode = (s != ' ' &&
            _hidden.hasMatch(s) &&
            !(bJoiner && _joinsNonAscii(runes, i))) ||
        (_mark.hasMatch(s) && !_isVisible(runes, _baseBefore(runes, i)));
    out.write(bShowCode
        ? '<U+${r.toRadixString(16).toUpperCase().padLeft(4, '0')}>'
        : s);
  }
  out.write('”');
  return out.toString();
}

/// Whether the code point at [i] is a visible character on its own: not a
/// space, nothing hidden, not an accent.
bool _isVisible(List<int> runes, int i) {
  if (i < 0 || i >= runes.length) return false;
  final s = String.fromCharCode(runes[i]);
  return s != ' ' && !_hidden.hasMatch(s) && !_mark.hasMatch(s);
}

/// The code point before [i], past any accents or variation selectors on
/// it (as in "क्" or "🏳️"); -1 if none.
int _baseBefore(List<int> runes, int i) {
  var j = i - 1;
  while (j >= 0 && _mark.hasMatch(String.fromCharCode(runes[j]))) {
    j--;
  }
  return j;
}

/// Whether the joiner at [i] sits between two visible non-ASCII characters
/// (an emoji sequence, a Persian or Indic name), where it does something;
/// between ASCII letters it only hides.
bool _joinsNonAscii(List<int> runes, int i) {
  final before = _baseBefore(runes, i);
  return _isVisible(runes, before) &&
      _isVisible(runes, i + 1) &&
      runes[before] > 0x7F &&
      runes[i + 1] > 0x7F;
}

String? _lines(List<String> lines) => lines.isEmpty ? null : lines.join('\n');
