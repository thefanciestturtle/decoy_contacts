# shellcheck shell=bash
# Shared by tool/check_build_tools.sh and tool/check_flutter_release.sh;
# source it from the repository's root.

# Prints FLUTTER_VERSION, the Flutter CI builds with, from
# .github/workflows/dart.yml: an exact version (e.g. 3.50.0), quoted or
# not, with or without a comment after it. Fails if there isn't exactly
# one such line.
ci_flutter_version() {
  local found
  found="$(sed -n 's/^[[:space:]]*FLUTTER_VERSION:[[:space:]]*["'\'']\{0,1\}\([0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}\)["'\'']\{0,1\}[[:space:]]*\(#.*\)\{0,1\}$/\1/p' \
    .github/workflows/dart.yml 2>/dev/null)" || return 1
  [[ -n "$found" && "$found" != *$'\n'* ]] || return 1
  echo "$found"
}
