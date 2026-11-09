#!/usr/bin/env bash
# Smoke-tests a release build of the app on an Android emulator.
#
#   tool/release_smoke_test.sh [path/to/app-release.apk]
#
# The other tests use debug builds, which skip R8. R8 shrinks release builds
# and can remove classes that a plugin only looks up at run time, so such a
# plugin breaks only in release builds (shared_preferences_android 2.5.0
# crashed at startup that way). This script installs a release build, starts
# it twice and checks it can read and write its settings:
#
# 1. First start of a fresh install: the app saves its default settings.
# 2. The stored phone template is set to the old +213 default, and the last
#    names to a custom list. Second start: the app must keep the custom names
#    (it read them) and replace the template (it wrote).
#
# After each start the app must still be running, with no crash and no Dart
# error in the log.
#
# Release builds can't be inspected with `run-as`, so this needs an emulator
# image where `adb root` works (google_apis, not google_apis_playstore). The
# app and its data are replaced, and the app is uninstalled at the end.
set -euo pipefail

cd "$(dirname "$0")/.."
source tool/emulator_lib.sh

readonly APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
readonly PREFS="/data/data/$APP_ID/shared_prefs/FlutterSharedPreferences.xml"
readonly NEW_TEMPLATE='+447700900nnn'
readonly OLD_TEMPLATE='+2134567nnnn'
readonly CUSTOM_NAMES='Zen, Zima'
readonly TIMEOUT_S=60

# adbd restarts on `adb root` / `adb unroot`, which can take a while.
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

# Fails if the app crashed or logged a Dart error since it was started.
check_no_errors() {
  if adb_ logcat -d -b crash | grep -q "$APP_ID"; then
    fail "the app crashed"
  fi
  if [[ -n "$(adb_ logcat -d -s flutter:E | grep -v '^-' || true)" ]]; then
    fail "the app logged a Dart error"
  fi
}

wait_for_pref() {
  local key="$1" want="$2" waited=0
  until [[ "$(pref "$key")" == "$want" ]]; do
    check_no_errors
    if (( waited >= TIMEOUT_S )); then
      fail "after ${TIMEOUT_S}s, $key is '$(pref "$key")', expected '$want'"
    fi
    sleep 1
    waited=$((waited + 1))
  done
}

start_app() {
  adb_ logcat -b all -c
  adb_ shell am start -W -n "$APP_ID/.MainActivity" >/dev/null
}

# Gives the app a few more seconds, then checks it is still running cleanly.
check_app_ok() {
  sleep 3
  check_no_errors
  [[ -n "$(adb_ shell pidof "$APP_ID" | tr -d '\r')" ]] ||
    fail "the app is no longer running"
}

echo "== Getting root (to read the release app's data)"
is_root && was_root=true
become_root || fail "adb root didn't work; use an emulator image without Play Store"

echo "== Installing $APK"
adb_ uninstall "$APP_ID" >/dev/null 2>&1 || true
adb_ install "$APK" >/dev/null

echo "== First start: the app should save its default settings"
start_app
wait_for_pref sPhoneNumberTemplate "$NEW_TEMPLATE"
[[ -n "$(pref sListOfLastNames)" ]] || fail "no last names saved"
check_app_ok
adb_ shell am force-stop "$APP_ID"

echo "== Changing the stored settings"
# Write the edited copy back with cat, which keeps the file's owner and
# SELinux label.
adb_ pull "$PREFS" "$tmp/prefs.xml" >/dev/null 2>&1
sed -e "s|\(name=\"flutter\.sPhoneNumberTemplate\">\)[^<]*|\1$OLD_TEMPLATE|" \
    -e "s|\(name=\"flutter\.sListOfLastNames\">\)[^<]*|\1$CUSTOM_NAMES|" \
    "$tmp/prefs.xml" > "$tmp/edited.xml"
adb_ push "$tmp/edited.xml" /data/local/tmp/fake_contacts_prefs.xml >/dev/null 2>&1
adb_ shell "cat /data/local/tmp/fake_contacts_prefs.xml > $PREFS && rm /data/local/tmp/fake_contacts_prefs.xml"
[[ "$(pref sPhoneNumberTemplate)" == "$OLD_TEMPLATE" &&
   "$(pref sListOfLastNames)" == "$CUSTOM_NAMES" ]] ||
  fail "couldn't change the stored settings"

echo "== Second start: the app should keep the names and replace the template"
start_app
wait_for_pref sPhoneNumberTemplate "$NEW_TEMPLATE"
[[ "$(pref sListOfLastNames)" == "$CUSTOM_NAMES" ]] ||
  fail "last names are '$(pref sListOfLastNames)', expected '$CUSTOM_NAMES'"
check_app_ok

echo "== Release build OK"
