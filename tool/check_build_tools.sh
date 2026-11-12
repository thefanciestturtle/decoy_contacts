#!/usr/bin/env bash
# Checks that the app's Android build tools are lined up with the Flutter
# version in use (the `flutter` on the PATH).
#
#   tool/check_build_tools.sh
#
# Flutter is tested with the versions of Gradle, the Android Gradle plugin
# (AGP) and Kotlin in its project template. The app uses the same minor
# version of each (e.g. AGP 9.3), and the newest patch release of it (e.g.
# 9.3.3), never an older one than the template's. Its Android flags in
# gradle.properties are the template's. This script makes a new project
# from the template in a temporary folder, compares, and fails with what to
# change. Run it after a Flutter upgrade; CI runs it on every build.
#
# Also checked: that the Gradle wrapper's distributionSha256Sum is Gradle's
# published checksum of the distribution it downloads (this needs the
# internet).
#
# Not compared: org.gradle.jvmargs (the template's larger heap didn't make
# this app's build any faster, and CI's runner also has to fit the
# emulator), the app's own Java level, and the SDK versions, which come
# from Flutter itself (flutter.compileSdkVersion etc.).
set -euo pipefail

cd "$(dirname "$0")/.."

readonly WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
readonly SETTINGS=android/settings.gradle.kts
readonly PROPERTIES=android/gradle.properties

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

problems=()
problem() { problems+=("$*"); }

# The Gradle version in a wrapper properties file.
gradle_version() {
  sed -n 's|^distributionUrl=.*/gradle-\([0-9.]*\)-[a-z]*\.zip$|\1|p' "$1"
}

# The version of the Gradle plugin with ID $2 in a settings.gradle.kts.
plugin_version() {
  sed -n "s|^ *id(\"$2\") version \"\([^\"]*\)\".*|\1|p" "$1"
}

# The android.* flags of a gradle.properties into the associative array
# named $2 (flag -> value).
read_android_flags() {
  local -n flags=$2
  local key value
  while IFS='=' read -r key value; do
    # shellcheck disable=SC2034 # (flags is the caller's array)
    flags["$key"]="${value%"${value##*[![:space:]]}"}"
  done < <(grep -E '^android\.[A-Za-z.]+=' "$1" || true)
}

# A version with three parts (9.5 -> 9.5.0).
three_parts() { awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) "." ($3 == "" ? 0 : $3) }' <<<"$1"; }

# MAJOR.MINOR of a version.
minor_line() { awk -F. '{ print $1 "." ($2 == "" ? 0 : $2) }' <<<"$1"; }

# Whether version $1 is older than $2.
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
  if [[ -z "$ours" || -z "$theirs" ]]; then
    problem "$tool: couldn't read the version (app: '${ours}', template: '${theirs}')."
    return
  fi
  local line_ours line_theirs
  line_ours="$(minor_line "$ours")"
  line_theirs="$(minor_line "$theirs")"
  if [[ "$line_ours" != "$line_theirs" ]]; then
    problem "$tool $ours is on the $line_ours line, Flutter $flutter_version's template on $line_theirs ($theirs). In $where, use the newest $line_theirs.x release (at least $theirs)."
  elif older "$ours" "$theirs"; then
    problem "$tool $ours is older than Flutter $flutter_version's template ($theirs). In $where, use the newest $line_theirs.x release (at least $theirs)."
  else
    echo "$tool $ours: OK (template: $theirs)"
  fi
}

flutter_version="$(flutter --version --machine 2>/dev/null |
  sed -n 's/^ *"frameworkVersion": "\([^"]*\)".*/\1/p')"
[[ -n "$flutter_version" ]] || { echo "error: couldn't run flutter" >&2; exit 1; }

echo "== Making a new project from Flutter $flutter_version's template"
if ! flutter create --platforms=android --no-pub --project-name template_check \
     "$tmp/template_check" >"$tmp/create.log" 2>&1; then
  cat "$tmp/create.log" >&2
  echo "error: flutter create failed" >&2
  exit 1
fi
template="$tmp/template_check/android"

echo "== Comparing"
ours_gradle="$(gradle_version "$WRAPPER")"
compare Gradle "$ours_gradle" "$(gradle_version "$template/gradle/wrapper/gradle-wrapper.properties")" \
  "$WRAPPER (distributionUrl, and distributionSha256Sum to match)"
compare "Android Gradle plugin" "$(plugin_version "$SETTINGS" com.android.application)" \
  "$(plugin_version "$template/settings.gradle.kts" com.android.application)" "$SETTINGS"
compare Kotlin "$(plugin_version "$SETTINGS" org.jetbrains.kotlin.android)" \
  "$(plugin_version "$template/settings.gradle.kts" org.jetbrains.kotlin.android)" "$SETTINGS"

declare -A ours_flags=() theirs_flags=()
read_android_flags "$PROPERTIES" ours_flags
read_android_flags "$template/gradle.properties" theirs_flags
flags_ok=true
for flag in $(printf '%s\n' "${!ours_flags[@]}" "${!theirs_flags[@]}" | sort -u); do
  if [[ ! -v "theirs_flags[$flag]" ]]; then
    problem "$PROPERTIES: remove $flag=${ours_flags[$flag]} (Flutter $flutter_version's template doesn't set $flag)."
  elif [[ ! -v "ours_flags[$flag]" ]]; then
    problem "$PROPERTIES: add $flag=${theirs_flags[$flag]}, as in Flutter $flutter_version's template."
  elif [[ "${ours_flags[$flag]}" != "${theirs_flags[$flag]}" ]]; then
    problem "$PROPERTIES: $flag is ${ours_flags[$flag]}; Flutter $flutter_version's template has $flag=${theirs_flags[$flag]}."
  else
    continue
  fi
  flags_ok=false
done
if $flags_ok; then
  echo "Android flags in gradle.properties: OK"
fi

if [[ -n "$ours_gradle" ]]; then
  ours_sum="$(sed -n 's/^distributionSha256Sum=//p' "$WRAPPER")"
  url="$(sed -n 's/^distributionUrl=//p' "$WRAPPER" | sed 's/\\:/:/g')"
  if [[ -z "$ours_sum" ]]; then
    problem "$WRAPPER has no distributionSha256Sum: add Gradle's checksum of the distribution ($url.sha256)."
  elif ! published="$(curl -fsSL --retry 3 "$url.sha256")"; then
    problem "couldn't download Gradle's checksum ($url.sha256) to compare."
  elif [[ "$ours_sum" != "$published" ]]; then
    problem "$WRAPPER: distributionSha256Sum is $ours_sum, but Gradle publishes $published for $url."
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
