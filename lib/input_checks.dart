// Checks of the template fields as typed, shown under the field they
// concern. Warnings only: they never stop Create (only empty name lists do,
// and the preview says why). No Flutter imports, so they can be unit tested
// directly.

/// Characters a phone number template may have: digits, the `n`
/// placeholder, the usual separators (space - ( ) . /), and what dial
/// strings use (+ * # and the pauses , ;).
final RegExp _phoneTemplateCharacter = RegExp(r'[0-9n+ \-().\/*#,;]');

final RegExp _whitespace = RegExp(r'\s');
final RegExp _nonAscii = RegExp(r'[^\x00-\x7F]');

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
    // Whole characters, so an emoji isn't split into two halves.
    for (final c in template.runes.map(String.fromCharCode))
      if (!_phoneTemplateCharacter.hasMatch(c)) c,
  };
  return _lines([
    if (bad.isNotEmpty) "A phone number can't contain ${_orList(bad.toList())}.",
    if (!template.contains('n'))
      "There is no n, so every contact gets the same number.",
  ]);
}

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
      template.replaceAll('FIRST', first).replaceAll('LAST', last);
  if (!_looksLikeAnAddress(fill())) {
    return "This doesn't look like an email address (FIRST.LAST@example.com).";
  }
  final unusable = {
    if (template.contains('FIRST'))
      ...firstNames.where((n) => !_looksLikeAnAddress(fill(first: n))),
    if (template.contains('LAST'))
      ...lastNames.where((n) => !_looksLikeAnAddress(fill(last: n))),
  }.toList();
  if (unusable.isEmpty) return null;
  final others = unusable.length - 1;
  return others == 0
      ? '"${unusable.first}" can\'t be part of an email address, so those'
          " addresses won't work."
      : '"${unusable.first}" and $others other ${others == 1 ? "name" : "names"}'
          " can't be part of an email address, so those addresses won't work.";
}

/// name@example.com: one @; before it, dot-separated parts of allowed
/// characters; after it, at least two dot-separated labels of letters,
/// digits and inner hyphens. Non-ASCII letters are allowed on both sides.
bool _looksLikeAnAddress(String address) {
  final parts = address.split('@');
  if (parts.length != 2 || address.contains(_whitespace)) return false;
  bool allowed(String part, RegExp ascii) =>
      ascii.hasMatch(part.replaceAll(_nonAscii, 'a'));
  final local = parts[0].split('.');
  final domain = parts[1].split('.');
  return local.every((p) => p.isNotEmpty && allowed(p, _localCharacters)) &&
      domain.length >= 2 &&
      domain.every((p) => allowed(p, _domainLabel));
}

/// '"a"', '"a" or "b"', '"a", "b" or "c"'.
String _orList(List<String> items) {
  final quoted = [for (final i in items) '"$i"'];
  if (quoted.length == 1) return quoted.single;
  return '${quoted.sublist(0, quoted.length - 1).join(', ')} or ${quoted.last}';
}

String? _lines(List<String> lines) => lines.isEmpty ? null : lines.join('\n');
