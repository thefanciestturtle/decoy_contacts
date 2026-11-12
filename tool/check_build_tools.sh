#!/usr/bin/env bash
# Checks that the app's Android build tools are lined up with the Flutter
# version in use (the `flutter` on the PATH).
#
#   tool/check_build_tools.sh
#
# Flutter is tested with the versions of Gradle, the Android Gradle plugin
# (AGP), Kotlin and its own plugin loader in its project template. The app
# uses the same minor version of each (e.g. AGP 9.3), and the newest patch
# release of it (e.g. 9.3.3), never an older one than the template's, nor a
# pre-release; and the same plugins. Its gradle.properties sets what the
# template's sets, except org.gradle.jvmargs (the template's larger heap
# didn't make this app's build any faster, and CI's runner also has to fit
# the emulator). This script makes a new project from the template in a
# temporary folder, compares, and fails with what to change. Run it after
# a Flutter upgrade; CI runs it on every build.
#
# Also checked: that the Gradle wrapper downloads Gradle from Gradle's own
# site, and that its distributionSha256Sum is the checksum Gradle publishes
# there (this needs the internet).
#
# Not compared: the app's own Java level, and the SDK versions, which come
# from Flutter itself (flutter.compileSdkVersion etc.).
set -euo pipefail

cd "$(dirname "$0")/.."

readonly WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
readonly SETTINGS=android/settings.gradle.kts
readonly PROPERTIES=android/gradle.properties
readonly GRADLE_DISTRIBUTIONS=https://services.gradle.org/distributions/
# Set in gradle.properties on purpose, whatever the template has.
readonly OWN_PROPERTIES=(org.gradle.jvmargs)

command -v flutter >/dev/null ||
  { echo "error: no flutter on the PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

problems=()
problem() { problems+=("$*"); }

# The properties of a .properties file, one "key<TAB>value" line each, read
# as Java (and so Gradle) reads them: # and ! comments, "=", ":" or spaces
# between key and value, lines continued with \, any line ends. Values
# lose their trailing spaces.
properties() {
  python3 - "$1" <<'EOF'
import re, sys

def unescape(s):
    s = re.sub(r"\\u([0-9a-fA-F]{4})", lambda m: chr(int(m.group(1), 16)), s)
    return re.sub(r"\\(.)", lambda m: {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
                  .get(m.group(1), m.group(1)), s)

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
    print(f"{unescape(key)}\t{unescape(rest).rstrip()}")
EOF
}

# The value of property $2 in the .properties file $1 (empty if none).
property() { properties "$1" | awk -F '\t' -v k="$2" '$1 == k { print substr($0, length(k) + 2) }'; }

# The plugins a settings.gradle.kts gives a version, one "id version" line
# each, e.g. "com.android.application 9.3.3".
plugins() {
  sed -n 's/^[[:space:]]*id[[:space:]]*([[:space:]]*"\([^"]*\)"[[:space:]]*)[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1 \2/p' "$1"
}

# What a plugin is called in messages.
plugin_name() {
  case "$1" in
    com.android.application) echo "Android Gradle plugin" ;;
    org.jetbrains.kotlin.android) echo Kotlin ;;
    dev.flutter.flutter-plugin-loader) echo "Flutter's plugin loader" ;;
    *) echo "The plugin $1" ;;
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
    problem "Flutter $flutter_version's template has $tool $theirs, which isn't a release version this script can compare. Line it up by hand, and update this script."
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

flutter_version="$(flutter --version --machine 2>/dev/null |
  sed -n 's/^ *"frameworkVersion": *"\([^"]*\)".*/\1/p' || true)"
[[ -n "$flutter_version" ]] ||
  { echo "error: couldn't get the version of flutter" >&2; exit 1; }

echo "== Making a new project from Flutter $flutter_version's template"
if ! flutter create --platforms=android --no-pub --project-name template_check \
     "$tmp/template_check" >"$tmp/create.log" 2>&1; then
  cat "$tmp/create.log" >&2
  echo "error: flutter create failed" >&2
  exit 1
fi
template="$tmp/template_check/android"

echo "== Comparing"

# Gradle (the wrapper's distribution, gradle-VERSION-TYPE.zip).
gradle_of() { property "$1" distributionUrl | sed -n 's|.*/gradle-\(.*\)-[a-z]*\.zip$|\1|p'; }
ours_url="$(property "$WRAPPER" distributionUrl)"
compare Gradle "$(gradle_of "$WRAPPER")" \
  "$(gradle_of "$template/gradle/wrapper/gradle-wrapper.properties")" \
  "$WRAPPER (distributionUrl, and distributionSha256Sum to match)"

# The plugins with versions in settings.gradle.kts.
declare -A ours_plugins=() theirs_plugins=()
while read -r id version; do ours_plugins["$id"]=$version; done < <(plugins "$SETTINGS")
while read -r id version; do theirs_plugins["$id"]=$version; done < <(plugins "$template/settings.gradle.kts")
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  name="$(plugin_name "$id")"
  if [[ ! -v "theirs_plugins[$id]" ]]; then
    problem "$name ($id): Flutter $flutter_version's template no longer uses it. See how a new project (flutter create) is set up instead, and change $SETTINGS and android/app/build.gradle.kts to match."
  elif [[ -v "ours_plugins[$id]" ]]; then
    compare "$name" "${ours_plugins[$id]}" "${theirs_plugins[$id]}" "$SETTINGS"
  elif grep -qF "\"$id\"" "$SETTINGS"; then
    problem "$name: couldn't read the app's version of $id in $SETTINGS (write it as in the template: id(\"$id\") version \"...\")."
  else
    problem "$name: Flutter $flutter_version's template uses $id (version ${theirs_plugins[$id]}); add it to $SETTINGS as the template does, and see whether android/app/build.gradle.kts needs it too."
  fi
done < <(printf '%s\n' "${!ours_plugins[@]}" "${!theirs_plugins[@]}" | sort -u)

# gradle.properties.
declare -A ours_props=() theirs_props=()
while IFS=$'\t' read -r key value; do ours_props["$key"]=$value; done < <(properties "$PROPERTIES")
while IFS=$'\t' read -r key value; do theirs_props["$key"]=$value; done < <(properties "$template/gradle.properties")
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
    problem "$PROPERTIES: $key is ${ours_props[$key]}; Flutter $flutter_version's template has $key=${theirs_props[$key]}."
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
ours_sum="$(property "$WRAPPER" distributionSha256Sum)"
if [[ "$ours_url" != "$GRADLE_DISTRIBUTIONS"gradle-*.zip ]]; then
  problem "$WRAPPER: distributionUrl is '$ours_url', not a Gradle distribution on Gradle's own site ($GRADLE_DISTRIBUTIONS)."
elif [[ -z "$ours_sum" ]]; then
  problem "$WRAPPER has no distributionSha256Sum: add Gradle's checksum of the distribution ($GRADLE_DISTRIBUTIONS$distribution.sha256)."
elif ! published="$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 60 \
                      "$GRADLE_DISTRIBUTIONS$distribution.sha256")"; then
  problem "couldn't download Gradle's checksum ($GRADLE_DISTRIBUTIONS$distribution.sha256) to compare."
elif [[ "$ours_sum" != "$published" ]]; then
  problem "$WRAPPER: distributionSha256Sum is $ours_sum, but Gradle publishes $published for $distribution."
else
  echo "Gradle distribution checksum: OK"
fi

if ((${#problems[@]})); then
  echo
  echo "The build tools don't match Flutter $flutter_version:" >&2
  printf -- '- %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "== The build tools match Flutter $flutter_version"
