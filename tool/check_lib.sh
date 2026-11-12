# shellcheck shell=bash
# Shared by tool/check_build_tools.sh and tool/check_flutter_release.sh;
# source it from the repository's root.

# Both need bash 4.4 or newer (empty arrays under set -u, associative
# arrays).
if ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 404)); then
  echo "error: this needs bash 4.4 or newer (this is $BASH_VERSION)" >&2
  exit 1
fi

# Stops with a clear message unless all the commands "$@" are on the PATH.
need() {
  local missing=() command
  for command in "$@"; do
    command -v "$command" >/dev/null || missing+=("$command")
  done
  if ((${#missing[@]})); then
    echo "error: this needs ${missing[*]} on the PATH" >&2
    exit 1
  fi
}

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

# Whether release version $1 is older than $2 (numbers only; 9.5 counts as
# 9.5.0).
version_older() {
  local a b
  a="$(awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) "." ($3 == "" ? 0 : $3) }' <<<"$1")"
  b="$(awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) "." ($3 == "" ? 0 : $3) }' <<<"$2")"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}
