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

# Prints the value of setting $1 in .github/workflows/dart.yml, which must
# match the basic regular expression $2: quoted or not, with or without a
# comment after it (after a space, as YAML wants). Fails if there isn't
# exactly one such line.
ci_env_value() {
  local found
  found="$(sed -n "s/^[[:space:]]*$1:[[:space:]]*[\"']\{0,1\}\($2\)[\"']\{0,1\}\([[:space:]]\{1,\}#.*\)\{0,1\}[[:space:]]*\$/\1/p" \
    .github/workflows/dart.yml 2>/dev/null)" || return 1
  [[ -n "$found" && "$found" != *$'\n'* ]] || return 1
  echo "$found"
}

# Prints FLUTTER_VERSION, the Flutter CI builds with: an exact version
# (e.g. 3.50.0).
ci_flutter_version() {
  ci_env_value FLUTTER_VERSION '[0-9]\{1,\}\.[0-9]\{1,\}\.[0-9]\{1,\}'
}

# Prints JAVA_VERSION, the major version of the JDK CI builds with (e.g. 25).
ci_java_version() {
  ci_env_value JAVA_VERSION '[0-9]\{1,\}'
}

# A release version with three parts: 9.5 -> 9.5.0.
three_part_version() {
  awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) "." ($3 == "" ? 0 : $3) }' <<<"$1"
}

# Whether release version $1 is older than $2.
version_older() {
  local a b
  a="$(three_part_version "$1")"
  b="$(three_part_version "$2")"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}
