#!/usr/bin/env bash
# Runs the on-device tests in integration_test/ on an Android emulator.
#
#   tool/integration_test.sh [--wipe-contacts] [extra `flutter test` args]
#
# The tests create and delete contacts in the device's real address book, so
# this script refuses to run on anything but an emulator. The tests need an
# empty address book and stop if it isn't; --wipe-contacts empties it first
# (all contacts and the call log on the emulator are lost). Pick the emulator
# with ANDROID_SERIAL if more than one device is connected.
#
# Permission: the app is installed and granted the contacts permission with
# `pm grant` before the tests run, so nobody has to tap the system dialog.
# `flutter test` then reinstalls the app with `adb install -r`, which keeps
# runtime permissions that were already granted.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly APP_ID=me.billdietrich.fake_contacts
readonly APK=build/app/outputs/flutter-apk/app-debug.apk

wipe=false
if [[ "${1:-}" == --wipe-contacts ]]; then
  wipe=true
  shift
fi

serial="${ANDROID_SERIAL:-$(adb get-serialno)}"
adb_() { adb -s "$serial" "$@"; }

if [[ "$(adb_ shell getprop ro.boot.qemu | tr -d '\r')" != 1 &&
      "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]]; then
  echo "error: $serial is not an emulator. These tests change the address" \
       "book, so they only run on an emulator." >&2
  exit 1
fi

echo "== Installing the app and granting the contacts permission"
flutter build apk --debug
adb_ install -r -t "$APK"
adb_ shell pm grant "$APP_ID" android.permission.READ_CONTACTS
adb_ shell pm grant "$APP_ID" android.permission.WRITE_CONTACTS

if $wipe; then
  echo "== Emptying the emulator's address book"
  adb_ shell pm clear com.android.providers.contacts
fi

echo "== Running the tests"
flutter test integration_test -d "$serial" "$@"
