#!/usr/bin/env bash
# Tests tool/check_build_tools.sh on made-up projects and templates, with
# stand-ins for `flutter` and `curl`: needs neither the Flutter SDK nor the
# internet.
#
#   tool/test/check_build_tools_test.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly SCRIPT="$PWD/tool/check_build_tools.sh"
readonly LIB="$PWD/tool/check_lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stand-ins. `flutter create` writes its arguments to $FLUTTER_LOG and
# copies $TEMPLATE (fails with CREATE_FAILS=1). `curl` writes the URL it
# was given to $CURL_LOG, $PUBLISHED_SUM to the file after -o, and the HTTP
# status $HTTP_STATUS (200 by default) as -w asks; or it exits with
# $CURL_EXIT (couldn't connect) if set.
mkdir "$tmp/bin" "$tmp/bin_no_flutter"
cat >"$tmp/bin/flutter" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo '{"frameworkVersion":"9.99.0","channel":"stable"}' ;;
  create)
    echo "$*" >>"$FLUTTER_LOG"
    [[ "${CREATE_FAILS:-}" != 1 ]] || { echo "create went wrong" >&2; exit 1; }
    mkdir -p "${*: -1}" && cp -R "$TEMPLATE/." "${*: -1}/" ;;
  *) exit 64 ;;
esac
EOF
cat >"$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "${*: -1}" >>"$CURL_LOG"
if [[ -n "${CURL_EXIT:-}" ]]; then exit "$CURL_EXIT"; fi
out=""
while (($#)); do [[ "$1" != -o ]] || out=$2; shift; done
[[ -n "$out" ]] || { echo "curl stand-in: no -o" >&2; exit 2; }
printf '%s' "$PUBLISHED_SUM" >"$out"
printf '%s' "${HTTP_STATUS:-200}"
EOF
cp "$tmp/bin/curl" "$tmp/bin_no_flutter/curl"
chmod +x "$tmp/bin/"* "$tmp/bin_no_flutter/"*
# Only what the script needs before it checks for its commands, and the
# stand-ins: no python3.
mkdir "$tmp/bin_no_python"
ln -s "$(command -v bash)" "$(command -v dirname)" "$tmp/bin/flutter" \
  "$tmp/bin/curl" "$tmp/bin_no_python/"

# Two checksums (Gradle's are SHA-256, 64 hex digits).
readonly SUM=c72fb9991f6025cbe337d52ba77e531b3faf62bdd3e348fe1ccee9f51c71adb0
readonly OTHER_SUM=61ba77b3ff7167e60962763eb4bae79db7120c189b9544358d0ade3c1e712a83

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
# Android Gradle plugin $3, Kotlin $4 (no Kotlin plugin if empty),
# gradle.properties $5, the wrapper's checksum $6 (none if empty), and
# Flutter's plugin loader $7. AGP's or Kotlin's version may instead be a
# whole plugin line, for lines the check can't read.
write_project() {
  local dir=$1/android
  mkdir -p "$dir/gradle/wrapper"
  {
    echo 'distributionBase=GRADLE_USER_HOME'
    echo "distributionUrl=https\\://services.gradle.org/distributions/gradle-$2-all.zip"
    if [[ -n "$6" ]]; then echo "distributionSha256Sum=$6"; fi
  } >"$dir/gradle/wrapper/gradle-wrapper.properties"
  {
    echo 'pluginManagement {'
    echo '    includeBuild("../flutter/packages/flutter_tools/gradle")'
    echo '}'
    echo
    echo 'plugins {'
    echo "    id(\"dev.flutter.flutter-plugin-loader\") version \"$7\""
    if [[ "$3" == *'('* ]]; then echo "    $3"
    else echo "    id(\"com.android.application\") version \"$3\" apply false"; fi
    if [[ "$4" == *'('* ]]; then echo "    $4"
    elif [[ -n "$4" ]]; then
      echo "    id(\"org.jetbrains.kotlin.android\") version \"$4\" apply false"
    fi
    echo '}'
  } >"$dir/settings.gradle.kts"
  printf '%s\n' "$5" >"$dir/gradle.properties"
}

# The template for the cases below: write_template [GRADLE AGP KOTLIN
# PROPERTIES LOADER].
write_template() {
  rm -rf "$tmp/template"
  write_project "$tmp/template" "${1-9.5.0}" "${2-9.3.1}" "${3-2.4.20}" \
    "${4-$TEMPLATE_PROPERTIES}" "" "${5-1.0.0}"
}

failures=0
case_number=0

# expect NAME STATUS TEXT [GRADLE AGP KOTLIN PROPERTIES SUM LOADER] : runs
# the check on an app made with those (by default the good ones) and the
# template in $tmp/template, and wants exit STATUS and TEXT in the output.
# The environment can set PATH_TO_USE, PUBLISHED_SUM, HTTP_STATUS,
# CURL_EXIT, CREATE_FAILS, IN_ACTIONS (to run as in GitHub Actions),
# EDIT, a command run in the app's android folder before the check, and
# NOT_WANTED, a text the output must not have.
expect() {
  local name=$1 want_status=$2 want_text=$3
  local proj="$tmp/case$((++case_number))"
  mkdir -p "$proj/tool"
  cp "$SCRIPT" "$LIB" "$proj/tool/"
  write_project "$proj" "${4-9.5.1}" "${5-9.3.3}" "${6-2.4.21}" \
    "${7-$GOOD_PROPERTIES}" "${8-$SUM}" "${9-1.0.0}"
  # CI's Flutter: the stand-in's.
  mkdir -p "$proj/.github/workflows"
  echo "  FLUTTER_VERSION: 9.99.0" >"$proj/.github/workflows/dart.yml"
  if [[ -n "${EDIT:-}" ]]; then (cd "$proj/android" && eval "$EDIT"); fi
  local out status=0
  out="$(PATH="${PATH_TO_USE:-$tmp/bin:/usr/bin:/bin}" TEMPLATE="$tmp/template" \
    PUBLISHED_SUM="${PUBLISHED_SUM-$SUM}" CURL_EXIT="${CURL_EXIT:-}" \
    HTTP_STATUS="${HTTP_STATUS:-}" \
    CREATE_FAILS="${CREATE_FAILS:-}" GITHUB_ACTIONS="${IN_ACTIONS:-}" \
    CURL_LOG="$proj/curl.log" FLUTTER_LOG="$proj/flutter.log" \
    "$proj/tool/check_build_tools.sh" 2>&1)" || status=$?
  if [[ "$status" == "$want_status" && "$out" == *"$want_text"* &&
        ( -z "${NOT_WANTED:-}" || "$out" != *"$NOT_WANTED"* ) ]]; then
    echo "ok: $name"
  else
    local unwanted=""
    if [[ -n "${NOT_WANTED:-}" ]]; then unwanted=", not '$NOT_WANTED'"; fi
    echo "FAIL: $name: exit $status (want $want_status), output (want '$want_text'$unwanted):"
    while IFS= read -r line; do echo "    $line"; done <<<"$out"
    failures=$((failures + 1))
  fi
}

write_template

expect "matching tools pass" 0 "The build tools match Flutter 9.99.0"
[[ "$(cat "$tmp/case$case_number/curl.log")" == \
   https://services.gradle.org/distributions/gradle-9.5.1-all.zip.sha256 ]] ||
  { echo "FAIL: the checksum's URL: $(cat "$tmp/case$case_number/curl.log")"; failures=$((failures + 1)); }
[[ "$(cat "$tmp/case$case_number/flutter.log")" == \
   "create --platforms=android --no-pub --project-name template_check /"*/template_check ]] ||
  { echo "FAIL: flutter create's arguments: $(cat "$tmp/case$case_number/flutter.log")"; failures=$((failures + 1)); }
expect "the same versions as the template pass" 0 "Kotlin (org.jetbrains.kotlin.android) 2.4.20: OK" \
  9.5.0 9.3.1 2.4.20
expect "a newer patch release passes" 0 "Kotlin (org.jetbrains.kotlin.android) 2.4.99: OK" 9.5.1 9.3.3 2.4.99
expect "a version without its patch counts as .0" 0 "Gradle 9.5: OK" 9.5
expect "an older minor line fails" 1 \
  "Kotlin (org.jetbrains.kotlin.android) 2.3.21 is on the 2.3 line, Flutter 9.99.0's template on 2.4 (2.4.20). In android/settings.gradle.kts, use the newest 2.4.x release (at least 2.4.20)." \
  9.5.1 9.3.3 2.3.21
expect "a newer minor line fails" 1 \
  "Android Gradle plugin (com.android.application) 9.4.1 is on the 9.4 line, Flutter 9.99.0's template on 9.3" \
  9.5.1 9.4.1
expect "an older minor line of Gradle fails" 1 \
  "Gradle 9.4.9 is on the 9.4 line, Flutter 9.99.0's template on 9.5 (9.5.0)" 9.4.9
expect "an older patch on the same line fails" 1 \
  "Android Gradle plugin (com.android.application) 9.3.0 is older than Flutter 9.99.0's template (9.3.1)" \
  9.5.1 9.3.0
expect "a pre-release fails" 1 "Kotlin (org.jetbrains.kotlin.android) 2.4.20-RC isn't a release" \
  9.5.1 9.3.3 2.4.20-RC
expect "a Gradle pre-release fails" 1 "Gradle 9.5.1-rc-1 isn't a release" \
  9.5.1-rc-1
expect "a plugin line the check can't read fails" 1 \
  "Android Gradle plugin (com.android.application): couldn't read the app's version in android/settings.gradle.kts" \
  9.5.1 'id("com.android.application").version("9.3.3")'
EDIT='sed -i "s/\$/\r/" gradle/wrapper/gradle-wrapper.properties settings.gradle.kts gradle.properties' \
  expect "Windows line ends are fine" 0 "The build tools match"
EDIT='sed -i "s/^    id/\tid/" settings.gradle.kts' \
  expect "tabs before the plugins are fine" 0 "Android Gradle plugin (com.android.application) 9.3.3: OK"

expect "a missing property fails" 1 \
  "android/gradle.properties: add android.builtInKotlin=false, as in Flutter 9.99.0's template." \
  9.5.1 9.3.3 2.4.21 $'org.gradle.jvmargs=-Xmx1536M\nandroid.useAndroidX=true\nandroid.newDsl=false'
expect "a different value fails" 1 \
  "android/gradle.properties: android.newDsl is 'true'; Flutter 9.99.0's template has 'false'." \
  9.5.1 9.3.3 2.4.21 "${GOOD_PROPERTIES/newDsl=false/newDsl=true}"
expect "an extra property with digits fails" 1 \
  "remove android.enableR8.fullMode=false" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nandroid.enableR8.fullMode=false'
expect "an extra property outside android.* fails" 1 \
  "remove org.gradle.caching=true" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\norg.gradle.caching=true'
expect "an extra property written with a colon fails" 1 \
  "remove android.foo=true" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nandroid.foo: true'
expect "a key with a space in it is read as Java does" 1 \
  "remove foo=bar=baz" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nfoo bar=baz'
expect "spaces, colons, comments and continued lines are fine" 0 \
  "gradle.properties: OK" \
  9.5.1 9.3.3 2.4.21 $'# a comment\norg.gradle.jvmargs = -Xmx2G \\\n    -XX:MaxMetaspaceSize=1G\nandroid.useAndroidX : true\nandroid.newDsl=  false\n\n! another comment\nandroid.builtInKotlin=fal\\\n    se'
expect "trailing spaces in a value count, as in Java" 1 \
  "android.newDsl is 'false  '; Flutter 9.99.0's template has 'false'." \
  9.5.1 9.3.3 2.4.21 "${GOOD_PROPERTIES/newDsl=false/newDsl=false  }"
expect "an empty key is read as Java does" 1 "remove (an empty key)=foo" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\n=foo'
expect "a line that is only a backslash ends there, as in Java" 0 "gradle.properties: OK" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\n\\\n\n  \\\n#c=d'
expect "and so is a line that is only =" 1 "remove (an empty key)= (Flutter" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\n='
expect "an escaped newline stays in its value" 1 'remove foo=a\nb (Flutter' \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nfoo=a\\nb'
expect "a broken \\u escape fails, as in Java" 1 \
  'error: android/gradle.properties: a \u escape without four hex digits' \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\nfoo=\\u12'
expect "escapes are read as Java does" 1 'remove a:b=\u0041 and B' \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES"$'\na\\:b=\\\\u0041 and \\u0042'

PUBLISHED_SUM="$SUM  gradle-9.5.1-all.zip"$'\n' expect \
  "a checksum file that also names the file, with a newline, is fine" 0 \
  "Gradle distribution checksum: OK"
PUBLISHED_SUM="$OTHER_SUM" expect "a wrong checksum fails" 1 \
  "distributionSha256Sum is $SUM, but Gradle publishes $OTHER_SUM for gradle-9.5.1-all.zip"
PUBLISHED_SUM='<html>Busy</html>' expect "something else than a checksum only warns" 0 \
  "warning: what Gradle's site sent for the checksum (https://services.gradle.org/distributions/gradle-9.5.1-all.zip.sha256) isn't one"
expect "no checksum fails" 1 "has no distributionSha256Sum" \
  9.5.1 9.3.3 2.4.21 "$GOOD_PROPERTIES" ""
CURL_EXIT=6 expect "Gradle's site out of reach: only a warning" 0 \
  "warning: couldn't reach Gradle's site for the checksum (https://services.gradle.org/distributions/gradle-9.5.1-all.zip.sha256), so distributionSha256Sum wasn't compared with it."
CURL_EXIT=28 IN_ACTIONS=true expect "(in GitHub Actions, as an annotation)" 0 \
  "::warning::couldn't reach Gradle's site for the checksum"
HTTP_STATUS=503 expect "Gradle's site failing: only a warning" 0 \
  "warning: Gradle's site answered HTTP 503 for the checksum"
HTTP_STATUS=410 expect "a checksum Gradle took away fails" 1 \
  "Gradle's site has no checksum for gradle-9.5.1-all.zip"
HTTP_STATUS=404 expect "no checksum on Gradle's site fails" 1 \
  "Gradle's site has no checksum for gradle-9.5.1-all.zip (https://services.gradle.org/distributions/gradle-9.5.1-all.zip.sha256): is distributionUrl right?"
EDIT='sed -i "s|services.gradle.org|mirror.example|" gradle/wrapper/gradle-wrapper.properties' \
  expect "Gradle from another site fails" 1 \
  "distributionUrl is 'https://mirror.example/distributions/gradle-9.5.1-all.zip', not a Gradle distribution on Gradle's own site"

if [[ -e /usr/bin/flutter || -e /bin/flutter ]]; then
  echo "skipped: no flutter on the PATH (this machine has one in /usr/bin or /bin)"
else
  PATH_TO_USE="$tmp/bin_no_flutter:/usr/bin:/bin" \
    expect "no flutter on the PATH fails" 1 "error: this needs flutter on the PATH"
fi
PATH_TO_USE="$tmp/bin_no_python" \
  expect "no python3 on the PATH fails" 1 "error: this needs python3 on the PATH"
CREATE_FAILS=1 expect "a failed flutter create fails" 1 "create went wrong"
EDIT='mkdir -p ../.github/workflows && echo "  FLUTTER_VERSION: 3.50.0 # pinned" >../.github/workflows/dart.yml' \
  expect "another Flutter than CI's gets a warning" 0 \
  "warning: this is Flutter 9.99.0, CI builds with 3.50.0"
EDIT='echo "  FLUTTER_VERSION: 3.50.x" >../.github/workflows/dart.yml' \
  expect "a FLUTTER_VERSION that can't be read gets a warning" 0 \
  "warning: couldn't read FLUTTER_VERSION (one line, an exact version) in .github/workflows/dart.yml"
EDIT='rm gradle.properties' expect "a missing file of the app's fails" 1 \
  "error: there is no android/gradle.properties"

EDIT='sed -i "s|^    id(\"org.jetbrains.kotlin|    // id(\"org.jetbrains.kotlin|" settings.gradle.kts' \
  expect "a plugin that is only commented out is missing" 1 \
  "Kotlin (org.jetbrains.kotlin.android): Flutter 9.99.0's template uses it (version 2.4.20); add it"
EDIT='printf "%s\n" "plugins {" "    id(\"org.example.own\") version \"1.0\"" "}" >>settings.gradle.kts' \
  expect "a plugin the template doesn't use fails" 1 \
  "org.example.own: Flutter 9.99.0's template doesn't use it. Remove it"
own='printf "%s\n" "plugins {" "    id(\"org.example.own\") version \"1.0\"" "}" >>settings.gradle.kts &&
     sed -i "s/^readonly OWN_PLUGINS=()/readonly OWN_PLUGINS=(org.example.own)/" ../tool/check_build_tools.sh'
EDIT=$own expect "unless the app lists it as its own" 0 "The build tools match"

# Templates that change.
write_template 9.5.0 9.3.1 2.4.20 "$TEMPLATE_PROPERTIES" 1.0.1
expect "an older plugin loader than the template's fails" 1 \
  "Flutter's plugin loader (dev.flutter.flutter-plugin-loader) 1.0.0 is older than Flutter 9.99.0's template (1.0.1)"
write_template 9.5.0 9.4.0-rc01
expect "a pre-release in the template fails" 1 \
  "Flutter 9.99.0's template has Android Gradle plugin (com.android.application) '9.4.0-rc01', which isn't a release version this script can compare."
write_template
printf '%s\n' 'plugins {' '    id("org.example.new").version("1.2.3")' '}' \
  >>"$tmp/template/android/settings.gradle.kts"
expect "a plugin the template adds in a form the check can't read fails" 1 \
  "org.example.new: Flutter 9.99.0's template uses it, but this script can't read how; this script needs updating."
write_template
printf '%s\n' 'plugins {' '    id("org.example.new") version "1.2.3"' '}' \
  >>"$tmp/template/android/settings.gradle.kts"
expect "a plugin the template adds fails" 1 \
  "org.example.new: Flutter 9.99.0's template uses it (version 1.2.3); add it"
write_template 9.5.0 9.3.1 "" \
  "${TEMPLATE_PROPERTIES/builtInKotlin=false/builtInKotlin=true}"
expect "a plugin the template no longer uses fails" 1 \
  "Kotlin (org.jetbrains.kotlin.android): Flutter 9.99.0's template doesn't use it." \
  9.5.1 9.3.3 2.4.21 "${GOOD_PROPERTIES/builtInKotlin=false/builtInKotlin=true}"
expect "without it in the app too, it passes" 0 "The build tools match" \
  9.5.1 9.3.3 "" "${GOOD_PROPERTIES/builtInKotlin=false/builtInKotlin=true}"
write_template 9.5.0 'id("com.android.application").version("9.3.1")'
expect "AGP that neither file gives in a form the check reads fails" 1 \
  "couldn't read the Android Gradle plugin's (com.android.application) version in Flutter 9.99.0's template" \
  9.5.1 'id("com.android.application").version("7.0.0")'
expect "and so does the template's alone" 1 \
  "couldn't read the Android Gradle plugin's (com.android.application) version in Flutter 9.99.0's template (settings.gradle.kts), so the plugins weren't compared; this script needs updating."
write_template 9.5.0 'alias(libs.plugins.android.application) apply false'
NOT_WANTED="Remove it" expect "a template that names AGP another way isn't taken as dropping it" 1 \
  "so the plugins weren't compared; this script needs updating."
write_template 9.5.0 9.3.1 'id("org.jetbrains.kotlin.android").version("2.4.20")'
NOT_WANTED="Remove it" expect "a template plugin the check can't read isn't to be removed" 1 \
  "Kotlin (org.jetbrains.kotlin.android): couldn't read its version in Flutter 9.99.0's template"
write_template
printf '%s\n' 'plugins {' '    id("org.example.own") version "2.0"' '}' \
  >>"$tmp/template/android/settings.gradle.kts"
EDIT=$own expect "an own plugin that the template also uses is compared" 1 \
  "org.example.own 1.0 is on the 1.0 line, Flutter 9.99.0's template on 2.0"
write_template
rm "$tmp/template/android/gradle.properties"
expect "a template without gradle.properties fails" 1 \
  "error: Flutter 9.99.0's template has no android/gradle.properties; this script needs updating."

if ((failures)); then
  echo "$failures of $case_number cases failed" >&2
  exit 1
fi
echo "All $case_number cases passed"
