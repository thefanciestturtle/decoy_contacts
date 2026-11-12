#!/usr/bin/env bash
# Runs the on-device tests in integration_test/ on an Android emulator.
#
#   tool/integration_test.sh [--wipe-contacts] [extra `flutter test` args]
#
# The extra arguments go to the main run only, not to
# integration_test/permission_test.dart (see below).
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
readonly CONTACTS_PROVIDER=com.android.providers.contacts
readonly PROVIDER_TIMEOUT_S=60

# Waits until the contacts provider answers a query and the address book is
# empty, after it was emptied (see below). After a failed query it stops the
# provider's package again before the next one. Stops the script if the
# address book isn't empty, or if the provider still doesn't answer after
# PROVIDER_TIMEOUT_S seconds; then it shows what Android logged about the
# provider since $1, the emulator's time before it was emptied (for
# `logcat -T`). A query to a stuck provider takes about 20 s to fail; one
# that takes longer than 30 s is given up.
wait_for_empty_address_book() {
  local since=$1 start=$SECONDS answer
  while true; do
    # `content` prints rows or "No result found." when the provider answers,
    # and an error otherwise. Its exit status can't be relied on (on API 36
    # it is 0 after an error too), so the output is checked.
    # (`timeout` can't run the adb_ function, hence plain adb with the serial.)
    answer="$(timeout 30 adb -s "$serial" shell content query \
      --uri content://com.android.contacts/raw_contacts --projection _id \
      2>&1)" || true
    answer="${answer//$'\r'/}"
    if grep -qx 'No result found\.' <<<"$answer"; then
      return 0
    fi
    if grep -q '^Row: ' <<<"$answer"; then
      echo "error: the address book still has contacts after emptying it:" >&2
      echo "$answer" >&2
      exit 1
    fi
    if ((SECONDS - start >= PROVIDER_TIMEOUT_S)); then
      echo "error: the contacts provider still doesn't answer" \
           "$((SECONDS - start)) s after emptying the address book." \
           "The last query said:" >&2
      echo "${answer:-(nothing)}" >&2
      echo "--- what Android logged about it since then:" >&2
      adb_ logcat -d -T "$since" -s ActivityManager ContentProviderHelper |
        grep -i contacts | tail -n 20 >&2 || true
      exit 1
    fi
    adb_ shell am force-stop "$CONTACTS_PROVIDER"
    sleep 1
  done
}

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
  since="$(adb_ shell date +"'%m-%d %H:%M:%S.000'")"
  since="${since%$'\r'}"
  adb_ shell pm clear "$CONTACTS_PROVIDER"
  # While `pm clear` deletes the data, Android freezes the provider's package
  # and doesn't let its process start. If something asks for the provider
  # just then (the system often does, soon after the emulator has started),
  # Android can be left waiting for a process it never starts: every later
  # request fails, also the tests' ("Unknown authority"), until the package
  # is stopped. Stopping it now clears that. (Seen in CI, and reproduced on
  # the emulator by asking for the provider in a loop during `pm clear`:
  # stuck after 6 of 40 runs; with this stop, after none of 40.)
  adb_ shell am force-stop "$CONTACTS_PROVIDER"
  wait_for_empty_address_book "$since"
fi

echo "== Running the tests"
tests=()
for file in integration_test/*_test.dart; do
  [[ "$file" == integration_test/permission_test.dart ]] || tests+=("$file")
done
flutter test "${tests[@]}" -d "$serial" "$@"

echo "== Running the tests with the contacts permission permanently denied"
# `flutter test` uninstalled the app at the end.
adb_ install -r -t "$APK"
for permission in READ_CONTACTS WRITE_CONTACTS; do
  adb_ shell pm revoke "$APP_ID" "android.permission.$permission"
  adb_ shell pm set-permission-flags "$APP_ID" \
    "android.permission.$permission" user-set user-fixed
done
# Without the extra arguments: they are meant for the tests above (e.g. a
# --plain-name filter, which would match nothing here). The run above
# already got the packages, if it was going to.
flutter test integration_test/permission_test.dart -d "$serial" --no-pub
# It ends with the app's settings in front; leave the home screen instead.
adb_ shell input keyevent KEYCODE_HOME
