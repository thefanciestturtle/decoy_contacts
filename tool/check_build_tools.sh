#!/usr/bin/env bash
# Checks that the app's Android build tools are lined up with the Flutter
# version in use (the `flutter` on the PATH).
#
#   tool/check_build_tools.sh
#
# Flutter is tested with the versions of Gradle, the Android Gradle plugin
# (AGP), Kotlin and its own plugin loader in its project template. The app
# uses the same minor version of each (e.g. AGP 9.3), and the newest patch
# release of it (e.g. 9.3.3) when it moves to a new Flutter. This script
# checks the minor version, and that the patch release is a release and
# not older than the template's; whether a newer one is out is left to the
# upgrade. The app also uses the same plugins. Its gradle.properties sets what the
# template's sets, except org.gradle.jvmargs (the template's larger heap
# didn't make this app's build any faster, and CI's runner also has to fit
# the emulator). This script makes a new project from the template in a
# temporary folder, compares, and fails with what to change. Run it after
# a Flutter upgrade; CI runs it on every build, before building (a build
# can add missing flags to gradle.properties by itself).
#
# Also checked: that the Gradle wrapper downloads Gradle from Gradle's own
# site, and that its distributionSha256Sum is the checksum Gradle publishes
# there (this needs the internet; if the site can't be reached, it only
# warns).
#
# Needs bash 4.4 or newer.
#
# Not compared: the app's own Java level, and the SDK versions, which come
# from Flutter itself (flutter.compileSdkVersion etc.).
set -euo pipefail

if ((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 404)); then
  echo "error: this needs bash 4.4 or newer (this is $BASH_VERSION)" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
source tool/flutter_version_lib.sh

readonly WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
readonly SETTINGS=android/settings.gradle.kts
readonly PROPERTIES=android/gradle.properties
readonly GRADLE_DISTRIBUTIONS=https://services.gradle.org/distributions/
# Set in gradle.properties on purpose, whatever the template has.
readonly OWN_PROPERTIES=(org.gradle.jvmargs)
# Plugins in settings.gradle.kts that the app uses and the template doesn't
# (none yet).
readonly OWN_PLUGINS=()
# Separates a key from its value in what properties() prints.
readonly SEP=$'\x1f'

command -v flutter >/dev/null ||
  { echo "error: no flutter on the PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

problems=()
problem() { problems+=("$*"); }

warning() {
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then echo "::warning::$*"; else echo "warning: $*"; fi
}

# The properties of a .properties file, one "key<SEP>value" line each, read
# as java.util.Properties (and so Gradle) reads them: # and ! comments, "=",
# ":" or spaces between key and value, lines continued with \, escapes, any
# line ends. Values keep their trailing spaces, as in Java. (A newline or
# carriage return in a key or value is printed as \n or \r.)
properties() {
  python3 - "$1" <<'EOF'
import re, sys

def unescape(s):
    def one(m):
        c = m.group(1)
        if c[0] == "u":
            if not re.fullmatch(r"u[0-9a-fA-F]{4}", c):
                # (Java can't read the file then either.)
                sys.exit(f"error: {sys.argv[1]}: a \\u escape without four hex digits")
            return chr(int(c[1:], 16))
        return {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}.get(c, c)
    return re.sub(r"\\(u.{0,4}|.)", one, s)

text = open(sys.argv[1], encoding="latin-1").read()
lines, pending = [], None
for raw in re.split(r"\r\n|\r|\n", text):
    line = raw.lstrip(" \t\f")
    if pending is None and (not line or line[0] in "#!"):
        continue
    line = (pending or "") + line
    # An odd number of backslashes at the end continues the line.
    if (len(line) - len(line.rstrip("\\"))) % 2 == 1:
        pending = line[:-1]
        continue
    pending = None
    lines.append(line)
if pending is not None:
    lines.append(pending)
for line in lines:
    i = 0
    while i < len(line) and line[i] not in "=: \t\f":
        i += 2 if line[i] == "\\" else 1
    key, rest = line[:i], line[i:].lstrip(" \t\f")
    if rest[:1] in ("=", ":"):
        rest = rest[1:].lstrip(" \t\f")
    def one_line(s):
        return s.replace("\n", "\\n").replace("\r", "\\r")
    print(f"{one_line(unescape(key))}\x1f{one_line(unescape(rest))}")
EOF
}

# The plugins a settings.gradle.kts gives a version, one "id version" line
# each, e.g. "com.android.application 9.3.3".
plugins() {
  sed -n 's/^[[:space:]]*id[[:space:]]*([[:space:]]*"\([^"]*\)"[[:space:]]*)[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$1"
}

# What a plugin is called in messages.
plugin_name() {
  case "$1" in
    com.android.application) echo "Android Gradle plugin ($1)" ;;
    org.jetbrains.kotlin.android) echo "Kotlin ($1)" ;;
    dev.flutter.flutter-plugin-loader) echo "Flutter's plugin loader ($1)" ;;
    *) echo "$1" ;;
  esac
}

# Whether $1 is a release version: numbers only (9.5, 9.5.1), no "-rc1".
is_release() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; }

# A version with three parts (9.5 -> 9.5.0).
three_parts() { awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) "." ($3 == "" ? 0 : $3) }' <<<"$1"; }

# MAJOR.MINOR of a version.
minor_line() { awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) }' <<<"$1"; }

# Whether release version $1 is older than $2.
older() {
  local a b
  a="$(three_parts "$1")"
  b="$(three_parts "$2")"
  [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n 1)" == "$a" ]]
}

# Compares the app's version $2 of tool $1 with the template's, $3; $4 says
# where to change it.
compare() {
  local tool=$1 ours=$2 theirs=$3 where=$4
  if ! is_release "$theirs"; then
    problem "Flutter $flutter_version's template has $tool '$theirs', which isn't a release version this script can compare. Line it up by hand, and update this script."
    return
  fi
  local line
  line="$(minor_line "$theirs")"
  local change="In $where, use the newest $line.x release (at least $theirs)."
  if [[ -z "$ours" ]]; then
    problem "$tool: couldn't read the app's version. $change"
  elif ! is_release "$ours"; then
    problem "$tool $ours isn't a release. $change"
  elif [[ "$(minor_line "$ours")" != "$line" ]]; then
    problem "$tool $ours is on the $(minor_line "$ours") line, Flutter $flutter_version's template on $line ($theirs). $change"
  elif older "$ours" "$theirs"; then
    problem "$tool $ours is older than Flutter $flutter_version's template ($theirs). $change"
  else
    echo "$tool $ours: OK (template: $theirs)"
  fi
}

# Reads the properties of file $1 into the associative array named $2.
read_properties() {
  local -n into=$2
  local text key value
  text="$(properties "$1")"
  while IFS="$SEP" read -r key value; do
    [[ -n "$key$value" ]] || continue
    # shellcheck disable=SC2034 # (into is the caller's array)
    into["${key:-(an empty key)}"]=$value
  done <<<"$text"
}

flutter_version="$(flutter --version --machine 2>/dev/null |
  sed -n 's/^ *"frameworkVersion": *"\([^"]*\)".*/\1/p' || true)"
[[ -n "$flutter_version" ]] ||
  { echo "error: couldn't get the version of flutter" >&2; exit 1; }
ci_version="$(ci_flutter_version || true)"
if [[ -n "$ci_version" && "$ci_version" != "$flutter_version" ]]; then
  warning "this is Flutter $flutter_version, CI builds with $ci_version (FLUTTER_VERSION in .github/workflows/dart.yml): comparing with $flutter_version's template."
fi

echo "== Making a new project from Flutter $flutter_version's template"
if ! flutter create --platforms=android --no-pub --project-name template_check \
     "$tmp/template_check" >"$tmp/create.log" 2>&1; then
  cat "$tmp/create.log" >&2
  echo "error: flutter create failed" >&2
  exit 1
fi
template="$tmp/template_check/android"
for file in "${WRAPPER#android/}" "${SETTINGS#android/}" "${PROPERTIES#android/}"; do
  if [[ ! -f "$template/$file" ]]; then
    echo "error: Flutter $flutter_version's template has no android/$file; this script needs updating." >&2
    exit 1
  fi
done

echo "== Comparing"

# Gradle (the wrapper's distribution, gradle-VERSION-TYPE.zip).
declare -A ours_wrapper=() theirs_wrapper=()
read_properties "$WRAPPER" ours_wrapper
read_properties "$template/${WRAPPER#android/}" theirs_wrapper
ours_url="${ours_wrapper[distributionUrl]:-}"
gradle_of() { sed -n 's|.*/gradle-\(.*\)-[a-z]*\.zip$|\1|p' <<<"$1"; }
compare Gradle "$(gradle_of "$ours_url")" \
  "$(gradle_of "${theirs_wrapper[distributionUrl]:-}")" \
  "$WRAPPER (distributionUrl, and distributionSha256Sum to match)"

# The plugins with versions in settings.gradle.kts. The template must have
# AGP among them, or nothing would be compared.
declare -A ours_plugins=() theirs_plugins=()
ours_list="$(plugins "$SETTINGS")"
theirs_list="$(plugins "$template/${SETTINGS#android/}")"
while read -r id version; do
  if [[ -n "$id" ]]; then ours_plugins["$id"]=$version; fi
done <<<"$ours_list"
while read -r id version; do
  if [[ -n "$id" ]]; then theirs_plugins["$id"]=$version; fi
done <<<"$theirs_list"
if [[ ! -v "theirs_plugins[com.android.application]" ]]; then
  problem "couldn't read the Android Gradle plugin's version in Flutter $flutter_version's template (settings.gradle.kts); this script needs updating."
fi
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  for own in "${OWN_PLUGINS[@]}"; do [[ "$id" != "$own" ]] || continue 2; done
  name="$(plugin_name "$id")"
  if [[ ! -v "theirs_plugins[$id]" ]]; then
    problem "$name: Flutter $flutter_version's template doesn't use it. Remove it from $SETTINGS (and android/app/build.gradle.kts), or, if the template set it up another way, do as a new project (flutter create) does."
  elif [[ -v "ours_plugins[$id]" ]]; then
    compare "$name" "${ours_plugins[$id]}" "${theirs_plugins[$id]}" "$SETTINGS"
  elif grep -v '^[[:space:]]*//' "$SETTINGS" | grep -qF "\"$id\""; then
    problem "$name: couldn't read the app's version in $SETTINGS (write it as the template does: id(\"$id\") version \"...\")."
  else
    problem "$name: Flutter $flutter_version's template uses it (version ${theirs_plugins[$id]}); add it to $SETTINGS as the template does, and see whether android/app/build.gradle.kts needs it too."
  fi
done < <(printf '%s\n' "${!ours_plugins[@]}" "${!theirs_plugins[@]}" | sort -u)

# gradle.properties.
declare -A ours_props=() theirs_props=()
read_properties "$PROPERTIES" ours_props
read_properties "$template/${PROPERTIES#android/}" theirs_props
for key in "${OWN_PROPERTIES[@]}"; do
  unset "ours_props[$key]" "theirs_props[$key]"
done
props_ok=true
while IFS= read -r key; do
  [[ -n "$key" ]] || continue
  if [[ ! -v "theirs_props[$key]" ]]; then
    problem "$PROPERTIES: remove $key=${ours_props[$key]} (Flutter $flutter_version's template doesn't set $key)."
  elif [[ ! -v "ours_props[$key]" ]]; then
    problem "$PROPERTIES: add $key=${theirs_props[$key]}, as in Flutter $flutter_version's template."
  elif [[ "${ours_props[$key]}" != "${theirs_props[$key]}" ]]; then
    problem "$PROPERTIES: $key is '${ours_props[$key]}'; Flutter $flutter_version's template has '${theirs_props[$key]}'."
  else
    continue
  fi
  props_ok=false
done < <(printf '%s\n' "${!ours_props[@]}" "${!theirs_props[@]}" | sort -u)
if $props_ok; then
  echo "gradle.properties: OK (as the template's, apart from ${OWN_PROPERTIES[*]})"
fi

# The Gradle distribution: from Gradle's site, with its published checksum.
distribution="${ours_url##*/}"
sum_url="$GRADLE_DISTRIBUTIONS$distribution.sha256"
ours_sum="${ours_wrapper[distributionSha256Sum]:-}"
if [[ "$ours_url" != "$GRADLE_DISTRIBUTIONS"gradle-*.zip ]]; then
  problem "$WRAPPER: distributionUrl is '$ours_url', not a Gradle distribution on Gradle's own site ($GRADLE_DISTRIBUTIONS)."
elif [[ -z "$ours_sum" ]]; then
  problem "$WRAPPER has no distributionSha256Sum: add Gradle's checksum of the distribution ($sum_url)."
elif ! response="$(curl -sSL --retry 3 --connect-timeout 20 --max-time 60 \
                     -w '\n%{http_code}' "$sum_url")"; then
  warning "couldn't reach Gradle's site for the checksum ($sum_url), so distributionSha256Sum wasn't compared with it."
else
  # The checksum, then the HTTP status on a line of its own.
  status="${response##*$'\n'}"
  published="${response%$'\n'*}"
  if [[ "$status" == 404 || "$status" == 410 ]]; then
    problem "Gradle's site has no checksum for $distribution ($sum_url): is distributionUrl right?"
  elif [[ "$status" != 200 ]]; then
    warning "Gradle's site answered HTTP $status for the checksum ($sum_url), so distributionSha256Sum wasn't compared with it."
  elif [[ "$ours_sum" != "$published" ]]; then
    problem "$WRAPPER: distributionSha256Sum is $ours_sum, but Gradle publishes $published for $distribution."
  else
    echo "Gradle distribution checksum: OK"
  fi
fi

if ((${#problems[@]})); then
  echo
  echo "The build tools don't match Flutter $flutter_version:" >&2
  printf -- '- %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "== The build tools match Flutter $flutter_version"
