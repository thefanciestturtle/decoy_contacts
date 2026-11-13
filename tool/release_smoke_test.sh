#!/usr/bin/env bash
# Smoke-tests a release build of the app on an Android emulator.
#
#   tool/release_smoke_test.sh [path/to/app-release.apk]
#
# Without an APK, it builds a release APK for the emulator's ABI first.
#
# The other tests use debug builds, which skip R8. R8 shrinks release builds
# and can remove classes that a plugin only looks up at run time, so such a
# plugin breaks only in release builds. This script installs a release build,
# starts it twice and checks it can write and read its settings:
#
# 1. First start of a fresh install: the app saves its default settings.
# 2. The stored last names are changed to a custom list. Second start: the
#    app must show them in its Last names field (read from the screen with
#    `uiautomator dump`, as accessibility services see it).
#
# After each start the app must still be running, with no crash, no ANR and
# no Dart error in the log. Contacts are not exercised: the app only touches
# them when Create or Delete is tapped.
#
# It also checks that the app asks for no internet access: its privacy policy
# says it has none. (Debug and profile builds do ask, for Flutter's tools.)
#
# Release builds can't be inspected with `run-as`, so this needs an emulator
# image where `adb root` works (google_apis, not google_apis_playstore). The
# app and its data are replaced, and the app is uninstalled at the end.
set -euo pipefail

cd "$(dirname "$0")/.."
source tool/emulator_lib.sh

readonly PREFS="/data/data/$APP_ID/shared_prefs/FlutterSharedPreferences.xml"
readonly DEFAULT_TEMPLATE='+447700900nnn'
readonly CUSTOM_NAMES='Zen, Zima'
readonly TIMEOUT_S=60

# adbd restarts on `adb root` / `adb unroot`, which can take a while.
# (`timeout` can't run the adb_ function, hence plain adb with the serial.)
wait_for_device() {
  timeout 60 adb -s "$serial" wait-for-device || true
}

is_root() {
  [[ "$(adb_ shell id -u 2>/dev/null | tr -d '\r')" == 0 ]]
}

become_root() {
  local attempt
  for attempt in 1 2 3; do
    adb_ root >/dev/null 2>&1 || true
    wait_for_device
    for _ in $(seq 1 20); do
      is_root && return 0
      sleep 1
    done
  done
  return 1
}

tmp="$(mktemp -d)"
was_root=false
cleanup() {
  adb_ uninstall "$APP_ID" >/dev/null 2>&1 || true
  if ! $was_root; then
    adb_ unroot >/dev/null 2>&1 || true
    wait_for_device
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- crash log:" >&2
  adb_ logcat -d -b crash >&2 || true
  echo "--- flutter log:" >&2
  adb_ logcat -d -s flutter >&2 || true
  exit 1
}

# The value of one setting, or nothing if the app hasn't saved it.
pref() {
  adb_ shell cat "$PREFS" 2>/dev/null |
    sed -n "s/.*name=\"flutter\.$1\">\([^<]*\)<.*/\1/p"
}

# Fails if the app crashed, stopped responding or logged a Dart error since
# it was started.
check_no_errors() {
  if adb_ logcat -d -b crash | grep -q "$APP_ID"; then
    fail "the app crashed"
  fi
  if adb_ logcat -d -b main -b system | grep -q "ANR in $APP_ID"; then
    fail "the app stopped responding (ANR)"
  fi
  if [[ -n "$(adb_ logcat -d -s flutter:E | grep -v '^-' || true)" ]]; then
    fail "the app logged a Dart error"
  fi
}

wait_for_pref() {
  local key="$1" want="$2"
  local deadline=$((SECONDS + TIMEOUT_S))
  until [[ "$(pref "$key")" == "$want" ]]; do
    check_no_errors
    if (( SECONDS >= deadline )); then
      fail "after ${TIMEOUT_S}s, $key is '$(pref "$key")', expected '$want'"
    fi
    sleep 1
  done
}

# The text in the app's text field labelled $1, as the screen shows it now;
# nothing if there is no such field (or the dump failed, say because the
# app was still drawing its spinner, or it stalled). The dump is XML, one
# tag per line once split at "<" (which an attribute escapes); a label or
# text with &, < or " in it is escaped too, so this only works for plain
# ones.
field_text() {
  timeout 20 adb -s "$serial" exec-out uiautomator dump /dev/tty 2>/dev/null |
    tr '<' '\n' |
    grep -F "class=\"android.widget.EditText\"" |
    grep -F "hint=\"$1\"" |
    sed -n 's/.* text="\([^"]*\)".*/\1/p' |
    head -n 1 || true
}

# Turns the screen on and dismisses the keyguard, if they aren't already.
# The second start reads the app's screen, and with the screen off or
# locked the dump shows no app at all. Neither changes a setting.
wake_screen() {
  if ! adb_ shell input keyevent KEYCODE_WAKEUP ||
     ! adb_ shell wm dismiss-keyguard; then
    fail "couldn't turn the screen on and unlock it"
  fi
}

wait_for_field() {
  local label="$1" want="$2" shown
  local deadline=$((SECONDS + TIMEOUT_S))
  while true; do
    wake_screen # in case it went off meanwhile
    shown="$(field_text "$label")"
    [[ "$shown" == "$want" ]] && return
    check_no_errors
    if (( SECONDS >= deadline )); then
      fail "after ${TIMEOUT_S}s, the $label field shows '$shown'," \
           "expected '$want'"
    fi
    sleep 1
  done
}

start_app() {
  wake_screen
  # Only the buffers this script reads; clearing some others can fail.
  adb_ logcat -b main -b system -b crash -c || true
  local out
  if ! out="$(adb_ shell am start -n "$APP_ID/.MainActivity" 2>&1)" ||
     [[ "$out" == *Error* ]]; then
    fail "couldn't start the app: $out"
  fi
}

# Gives the app a few more seconds, then checks it is still running cleanly.
check_app_ok() {
  sleep 3
  check_no_errors
  [[ -n "$(adb_ shell pidof "$APP_ID" | tr -d '\r')" ]] ||
    fail "the app is no longer running"
}

if [[ $# -ge 1 ]]; then
  apk="$1"
else
  abi="$(adb_ shell getprop ro.product.cpu.abi | tr -d '\r')"
  case "$abi" in
    x86_64) platform=android-x64 ;;
    arm64-v8a) platform=android-arm64 ;;
    armeabi-v7a) platform=android-arm ;;
    *) fail "no Flutter target platform for ABI '$abi'" ;;
  esac
  echo "== Building a release APK for $abi"
  flutter build apk --release --target-platform "$platform"
  apk=build/app/outputs/flutter-apk/app-release.apk
fi
[[ -f "$apk" ]] || fail "no APK at $apk"

echo "== Getting root (to read the release app's data)"
is_root && was_root=true
become_root || fail "adb root didn't work; use an emulator image without Play Store"

echo "== Installing $apk"
adb_ uninstall "$APP_ID" >/dev/null 2>&1 || true
adb_ install "$apk" >/dev/null || fail "couldn't install $apk"

echo "== The app should ask for no internet access"
# Only the lines of that list: it ends at the next heading (a line ending
# in a colon).
requested="$(adb_ shell dumpsys package "$APP_ID" | tr -d '\r' |
  awk '/requested permissions:/ { bIn = 1; next } /:$/ { bIn = 0 } bIn')"
[[ "$requested" == *android.permission.READ_CONTACTS* ]] ||
  fail "couldn't read the app's requested permissions"
if [[ "$requested" == *android.permission.INTERNET* ]]; then
  fail "the app asks for internet access (android.permission.INTERNET)"
fi

echo "== First start: the app should save its default settings"
start_app
wait_for_pref sPhoneNumberTemplate "$DEFAULT_TEMPLATE"
[[ -n "$(pref sListOfLastNames)" ]] || fail "no last names saved"
check_app_ok
adb_ shell am force-stop "$APP_ID"

echo "== Changing the stored settings"
# Write the edited copy back with cat, which keeps the file's owner and
# SELinux label.
adb_ pull "$PREFS" "$tmp/prefs.xml" >/dev/null 2>&1 ||
  fail "couldn't read the app's settings file"
sed -e "s|\(name=\"flutter\.sListOfLastNames\">\)[^<]*|\1$CUSTOM_NAMES|" \
    "$tmp/prefs.xml" > "$tmp/edited.xml"
adb_ push "$tmp/edited.xml" /data/local/tmp/decoy_contacts_prefs.xml >/dev/null 2>&1 ||
  fail "couldn't copy the edited settings to the device"
adb_ shell "cat /data/local/tmp/decoy_contacts_prefs.xml > $PREFS && rm /data/local/tmp/decoy_contacts_prefs.xml" ||
  fail "couldn't write the app's settings file"
[[ "$(pref sListOfLastNames)" == "$CUSTOM_NAMES" ]] ||
  fail "couldn't change the stored settings"

echo "== Second start: the app should show the stored names"
start_app
wait_for_field "Last names" "$CUSTOM_NAMES"
check_app_ok

echo "== Release build OK"
