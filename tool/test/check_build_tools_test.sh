#!/usr/bin/env bash
# Tests tool/check_build_tools.sh on made-up projects and templates, with
# stand-ins for `flutter` and `curl`: needs neither the Flutter SDK nor the
# internet.
#
#   tool/test/check_build_tools_test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly SCRIPT="$PWD/tool/check_build_tools.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stand-ins. `flutter create` copies $TEMPLATE (fails with
# CREATE_FAILS=1); `curl` prints $PUBLISHED_SUM (fails if it is empty).
mkdir "$tmp/bin" "$tmp/bin_no_flutter"
cat >"$tmp/bin/flutter" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) printf '{\n  "frameworkVersion": "9.99.0",\n  "channel": "stable"\n}\n' ;;
  create)
    [[ "${CREATE_FAILS:-}" != 1 ]] || { echo "create went wrong" >&2; exit 1; }
    mkdir -p "${*: -1}" && cp -R "$TEMPLATE/." "${*: -1}/" ;;
  *) exit 64 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
[[ -n "${PUBLISHED_SUM:-}" ]] || exit 22
echo "$PUBLISHED_SUM"
EOF
cp "$tmp/bin/curl" "$tmp/bin_no_flutter/curl"
chmod +x "$tmp/bin/"* "$tmp/bin_no_flutter/"*

readonly GOOD_PROPERTIES='org.gradle.jvmargs=-Xmx1536M
android.useAndroidX=true
android.newDsl=false
android.builtInKotlin=false'

readonly TEMPLATE_PROPERTIES='org.gradle.jvmargs=-Xmx8G -XX:MaxMetaspaceSize=4G
android.useAndroidX=true
# This newDsl flag was added by the Flutter template
android.newDsl=false
android.builtInKotlin=false'

# Writes an Android project's build files under $1/android: Gradle $2, the
# Android Gradle plugin $3, Kotlin $4 (none if empty), gradle.properties $5,
# the wrapper's checksum $6 (none if empty). A version may also be a whole
# plugin line, to test lines the check can't read.
write_project() {
  local dir=$1/android
  mkdir -p "$dir/gradle/wrapper"
  {
    echo 'distributionBase=GRADLE_USER_HOME'
    echo "distributionUrl=https\\://services.gradle.org/distributions/gradle-$2-all.zip"
    if [[ -n "$6" ]]; then echo "distributionSha256Sum=$6"; fi
  } >"$dir/gradle/wrapper/gradle-wrapper.properties"
  {
    echo 'plugins {'
    echo '    id("dev.flutter.flutter-plugin-loader") version "1.0.0"'
    if [[ "$3" == *'('* ]]; then echo "    $3"
    else echo "    id(\"com.android.application\") version \"$3\" apply false"; fi
    if [[ -n "$4" ]]; then
      echo "    id(\"org.jetbrains.kotlin.android\") version \"$4\" apply false"
    fi
    echo '}'
  } >"$dir/settings.gradle.kts"
  printf '%s\n' "$5" >"$dir/gradle.properties"
}

failures=0
case_number=0

# expect NAME STATUS TEXT [GRADLE AGP KOTLIN PROPERTIES SUM] : runs the
# check on an app made with those (by default the good ones) and the
# template in $tmp/template, and wants exit STATUS and TEXT in the output.
# The environment can set PATH_TO_USE, PUBLISHED_SUM and CREATE_FAILS.
expect() {
  local name=$1 want_status=$2 want_text=$3
  local proj="$tmp/case$((++case_number))"
  mkdir -p "$proj/tool"
  cp "$SCRIPT" "$proj/tool/"
  write_project "$proj" "${4-9.5.1}" "${5-9.3.3}" "${6-2.4.21}" \
    "${7-$GOOD_PROPERTIES}" "${8-abc123}"
  local out status=0
  out="$(PATH="${PATH_TO_USE:-$tmp/bin:/usr/bin:/bin}" TEMPLATE="$tmp/template" \
    PUBLISHED_SUM="${PUBLISHED_SUM-abc123}" CREATE_FAILS="${CREATE_FAILS:-}" \
    "$proj/tool/check_build_tools.sh" 2>&1)" || status=$?
  if [[ "$status" == "$want_status" && "$out" == *"$want_text"* ]]; then
    echo "ok: $name"
  else
    echo "FAIL: $name: exit $status (want $want_status), output (want '$want_text'):"
    while IFS= read -r line; do echo "    $line"; done <<<"$out"
    failures=$((failures + 1))
  fi
}

write_project "$tmp/template" 9.5.0 9.3.1 2.4.20 "$TEMPLATE_PROPERTIES" ""

expect "matching tools pass" 0 "The build tools match Flutter 9.99.0"
expect "the same versions as the template pass" 0 "Kotlin 2.4.20: OK" \
  9.5.0 9.3.1 2.4.20
expect "a newer patch release passes" 0 "Kotlin 2.4.99: OK" 9.5.1 9.3.3 2.4.99
expect "a version without its patch counts as .0" 0 "Gradle 9.5: OK" 9.5
expect "an older minor line fails" 1 \
  "Kotlin 2.3.21 is on the 2.3 line, Flutter 9.99.0's template on 2.4 (2.4.20). In android/settings.gradle.kts, use the newest 2.4.x release (at least 2.4.20)." \
  9.5.1 9.3.3 2.3.21
expect "a newer minor line fails" 1 \
  "Android Gradle plugin 9.4.1 is on the 9.4 line, Flutter 9.99.0's template on 9.3" \
  9.5.1 9.4.1
expect "an older minor line of Gradle fails" 1 \
  "Gradle 9.4.9 is on the 9.4 line, Flutter 9.99.0's template on 9.5 (9.5.0)" 9.4.9
expect "an older patch on the same line fails" 1 \
  "Android Gradle plugin 9.3.0 is older than Flutter 9.99.0's template (9.3.1)" \
  9.5.1 9.3.0
expect "a pre-release fails" 1 "Kotlin 2.4.20-RC isn't a release" \
  9.5.1 9.3.3 2.4.20-RC
expect "a Gradle pre-release fails" 1 "Gradle 9.5.1-rc-1 isn't a release" \
  9.5.1-rc-1
expect "a plugin line the check can't read fails" 1 \
  "Android Gradle plugin: couldn't read the app's version" \
  9.5.1 'id("com.android.application").version("9.3.3")'

expect "a missing property fails" 1 \
  "android/gradle.properties: add android.builtInKotlin=false, as in Flutter 9.99.0's template." \
  9.5.1 9.3.3 2.4.21 $'org.gradle.jvmargs=-Xmx1536M\nandroid.useAndroidX=true\nandroid.newDsl=false'
expect "a different value fails" 1 \
  "android/gradle.properties: android.newDsl is true; Flutter 9.99.0's template has android.newDsl=false." \
  9.5.1 9.3.3 2.4.21 "${GOOD_PROPERTIES/newDsl=false/newDsl=true}"
expect "an extra property with digits fails" 1 \
  "remove android.enableR8.fullMode=false" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nandroid.enableR8.fullMode=false'
expect "an extra property outside android.* fails" 1 \
  "remove org.gradle.caching=true" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\norg.gradle.caching=true'
expect "spaces around = and comments are fine" 0 "gradle.properties: OK" \
  9.5.1 9.3.3 2.4.21 $'# a comment\norg.gradle.jvmargs = -Xmx2G\nandroid.useAndroidX = true\nandroid.newDsl=  false\n\n! another comment\nandroid.builtInKotlin=false  '

PUBLISHED_SUM=def456 expect "a wrong checksum fails" 1 \
  "distributionSha256Sum is abc123, but Gradle publishes def456 for https://services.gradle.org/distributions/gradle-9.5.1-all.zip"
expect "no checksum fails" 1 "has no distributionSha256Sum" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES" ""
PUBLISHED_SUM="" expect "a checksum that can't be downloaded fails" 1 \
  "couldn't download Gradle's checksum (https://services.gradle.org/distributions/gradle-9.5.1-all.zip.sha256)"

PATH_TO_USE="$tmp/bin_no_flutter:/usr/bin:/bin" \
  expect "no flutter on the PATH fails" 1 "error: no flutter on the PATH"
CREATE_FAILS=1 expect "a failed flutter create fails" 1 "create went wrong"

# A template that no longer applies the Kotlin plugin (built-in Kotlin).
rm -rf "$tmp/template"
write_project "$tmp/template" 9.5.0 9.3.1 "" \
  "${TEMPLATE_PROPERTIES/builtInKotlin=false/builtInKotlin=true}" ""
expect "a plugin the template no longer uses fails" 1 \
  "Kotlin: Flutter 9.99.0's template no longer uses the plugin org.jetbrains.kotlin.android" \
  9.5.1 9.3.3 2.4.21 "${GOOD_PROPERTIES/builtInKotlin=false/builtInKotlin=true}"
expect "without it in the app too, it passes" 0 "The build tools match" \
  9.5.1 9.3.3 "" "${GOOD_PROPERTIES/builtInKotlin=false/builtInKotlin=true}"

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"
