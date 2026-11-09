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
# runtime permissions that were already granted. After them,
# integration_test/permission_test.dart runs with the permission
# permanently denied instead (revoked and "user fixed", as two "Don't allow"
# taps leave it), which also needs no tap.
set -euo pipefail

cd "$(dirname "$0")/.."

readonly APK=build/app/outputs/flutter-apk/app-debug.apk

wipe=false
if [[ "${1:-}" == --wipe-contacts ]]; then
  wipe=true
  shift
fi

source tool/emulator_lib.sh

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
flutter test integration_test/app_test.dart -d "$serial" "$@"

echo "== Running the tests with the contacts permission permanently denied"
# `flutter test` uninstalled the app at the end.
adb_ install -r -t "$APK"
for permission in READ_CONTACTS WRITE_CONTACTS; do
  adb_ shell pm revoke "$APP_ID" "android.permission.$permission"
  adb_ shell pm set-permission-flags "$APP_ID" \
    "android.permission.$permission" user-set user-fixed
done
flutter test integration_test/permission_test.dart -d "$serial" "$@"
