// Checks of the settings as typed, shown under the fields they concern.
// Warnings only: Create still works (only empty name lists stop it, and the
// preview says why). No Flutter imports, so they can be unit tested directly.

/// More fake contacts than this gets a warning in the preview.
const int kManyFakeContacts = 10000;

/// Characters a phone number template may have: digits, the `n`
/// placeholder, and the usual separators.
final RegExp _phoneTemplateCharacter = RegExp(r'[0-9n+ \-().]');

/// A warning about the phone number template (already trimmed), or null.
/// An empty template is fine: the fakes get no phone number.
String? phoneTemplateWarning(String template) {
  if (template.isEmpty) return null;
  final bad = <String>{
    for (final c in template.split(''))
      if (!_phoneTemplateCharacter.hasMatch(c)) c,
  };
  return _lines([
    if (bad.isNotEmpty) "A phone number can't contain ${_orList(bad.toList())}.",
    if (!template.contains('n'))
      "There is no n, so every contact gets the same number.",
  ]);
}

/// A warning about the email address template (already trimmed), or null.
/// An empty template is fine: the fakes get no email address. Names are only
/// checked if the template uses them (FIRST for [firstNames], LAST for
/// [lastNames]).
String? emailTemplateWarning(String template,
    {required List<String> firstNames, required List<String> lastNames}) {
  if (template.isEmpty) return null;
  final withSpaces = {
    if (template.contains('FIRST')) ...firstNames.where(_hasSpace),
    if (template.contains('LAST')) ...lastNames.where(_hasSpace),
  }.toList();
  return _lines([
    if (!_looksLikeAnAddress(
        template.replaceAll('FIRST', 'a').replaceAll('LAST', 'a')))
      "This doesn't look like an email address (FIRST.LAST@example.com).",
    if (withSpaces.length == 1)
      '"${withSpaces.first}" has a space, so those email addresses won\'t work.'
    else if (withSpaces.length > 1)
      '"${withSpaces.first}" and ${withSpaces.length - 1}'
          ' ${withSpaces.length == 2 ? "other name" : "other names"} have'
          " spaces, so those email addresses won't work.",
  ]);
}

/// name@example.com: something before one @, a domain with a dot after it,
/// no spaces, and no empty parts between dots.
bool _looksLikeAnAddress(String address) {
  final parts = address.split('@');
  if (parts.length != 2 || address.contains(RegExp(r'\s'))) return false;
  final local = parts[0].split('.');
  final domain = parts[1].split('.');
  return domain.length >= 2 &&
      local.every((p) => p.isNotEmpty) &&
      domain.every((p) => p.isNotEmpty);
}

bool _hasSpace(String name) => name.contains(RegExp(r'\s'));

/// '"a"', '"a" or "b"', '"a", "b" or "c"'.
String _orList(List<String> items) {
  final quoted = [for (final i in items) '"$i"'];
  if (quoted.length == 1) return quoted.single;
  return '${quoted.sublist(0, quoted.length - 1).join(', ')} or ${quoted.last}';
}

String? _lines(List<String> lines) => lines.isEmpty ? null : lines.join('\n');
