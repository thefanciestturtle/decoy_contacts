#!/usr/bin/env bash
# Checks that the app's Android build tools are lined up with the Flutter
# version in use (the `flutter` on the PATH).
#
#   tool/check_build_tools.sh
#
# Flutter is tested with the versions of Gradle, the Android Gradle plugin
# (AGP) and Kotlin in its project template. The app uses the same minor
# version of each (e.g. AGP 9.3), and the newest patch release of it (e.g.
# 9.3.3), never an older one than the template's, nor a pre-release. Its
# gradle.properties sets what the template's sets, except
# org.gradle.jvmargs (the template's larger heap didn't make this app's
# build any faster, and CI's runner also has to fit the emulator). This
# script makes a new project from the template in a temporary folder,
# compares, and fails with what to change. Run it after a Flutter upgrade;
# CI runs it on every build.
#
# Also checked: that the Gradle wrapper's distributionSha256Sum is Gradle's
# published checksum of the distribution it downloads (this needs the
# internet).
#
# Not compared: the app's own Java level, and the SDK versions, which come
# from Flutter itself (flutter.compileSdkVersion etc.).
set -euo pipefail

cd "$(dirname "$0")/.."

readonly WRAPPER=android/gradle/wrapper/gradle-wrapper.properties
readonly SETTINGS=android/settings.gradle.kts
readonly PROPERTIES=android/gradle.properties
# Set in gradle.properties on purpose, whatever the template has.
readonly OWN_PROPERTIES=(org.gradle.jvmargs)

command -v flutter >/dev/null ||
  { echo "error: no flutter on the PATH" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

problems=()
problem() { problems+=("$*"); }

# The Gradle version in a wrapper properties file.
gradle_version() {
  sed -n 's|^distributionUrl=.*/gradle-\([^/]*\)-[a-z]*\.zip$|\1|p' "$1"
}

# The version of the Gradle plugin with ID $2 in a settings.gradle.kts.
plugin_version() {
  sed -n "s|^ *id(\"$2\") version \"\([^\"]*\)\".*|\1|p" "$1"
}

# Whether a settings.gradle.kts mentions the plugin with ID $2 at all.
mentions_plugin() { grep -qF "\"$2\"" "$1"; }

# The properties of a gradle.properties into the associative array named
# $2 (key -> value), with the spaces around keys and values left out.
read_properties() {
  local -n props=$2
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*([#!]|$) ]] && continue
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$key")"
    value="$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$value")"
    # shellcheck disable=SC2034 # (props is the caller's array)
    props["$key"]="$value"
  done <"$1"
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
    problem "$tool: couldn't read the version in Flutter $flutter_version's template ('$theirs')."
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

# Compares the version of the Gradle plugin $2 (called $1) in the app's
# settings with the template's.
compare_plugin() {
  local tool=$1 id=$2
  if ! mentions_plugin "$template/settings.gradle.kts" "$id"; then
    if mentions_plugin "$SETTINGS" "$id"; then
      problem "$tool: Flutter $flutter_version's template no longer uses the plugin $id. See how a new project (flutter create) is set up instead, and change $SETTINGS and android/app/build.gradle.kts to match."
    fi
    return
  fi
  compare "$tool" "$(plugin_version "$SETTINGS" "$id")" \
    "$(plugin_version "$template/settings.gradle.kts" "$id")" "$SETTINGS"
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
ours_gradle="$(gradle_version "$WRAPPER")"
compare Gradle "$ours_gradle" \
  "$(gradle_version "$template/gradle/wrapper/gradle-wrapper.properties")" \
  "$WRAPPER (distributionUrl, and distributionSha256Sum to match)"
compare_plugin "Android Gradle plugin" com.android.application
compare_plugin Kotlin org.jetbrains.kotlin.android

declare -A ours_props=() theirs_props=()
read_properties "$PROPERTIES" ours_props
read_properties "$template/gradle.properties" theirs_props
for key in "${OWN_PROPERTIES[@]}"; do
  unset "ours_props[$key]" "theirs_props[$key]"
done
props_ok=true
for key in $(printf '%s\n' "${!ours_props[@]}" "${!theirs_props[@]}" | sort -u); do
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
done
if $props_ok; then
  echo "gradle.properties: OK (as the template's, apart from ${OWN_PROPERTIES[*]})"
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
