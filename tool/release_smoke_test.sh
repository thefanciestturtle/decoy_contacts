#!/usr/bin/env bash
# Smoke-tests a release build of the app on an Android emulator.
#
#   tool/release_smoke_test.sh [APK]
#
# e.g. dist/decoy_contacts-<version>-x86_64-unsigned.apk (the emulator's
# ABI).
#
# Without an APK, it first builds the release APK for the emulator's ABI,
# as releases are built (one APK per ABI, flutter build apk --split-per-abi).
# Release builds are unsigned (the release key signs them by hand, see
# tool/sign_release.sh), so it installs a copy signed with the debug key, as
# tool/debug_sign.sh makes; an APK that is already signed is installed as
# it is.
#
# The other tests use debug builds, which skip R8. R8 shrinks release builds
# and can remove classes that a plugin only looks up at run time, so such a
# plugin breaks only in release builds. This script installs a release build,
# starts it three times and checks it can write and read its settings:
#
# 1. First start of a fresh install: the app saves its default settings.
# 2. The stored last names are changed to a custom list. Second start: the
#    app must show them in its Last names field (read from the screen with
#    `uiautomator dump`, as accessibility services see it).
#
# 3. With access to the contacts and a record of one fake whose raw contact
#    doesn't exist, third start: the app reads the address book to count
#    the fakes (with its own Android code, RawContactsReader.kt, which R8
#    shrinks too), and its status line must say there are none. Had the
#    read failed, the line would stay empty. The address book is only read.
#
# After each start the app must still be running, with no crash, no ANR and
# no Dart error in the log. Create and Delete aren't exercised.
#
# It also checks that the app asks for no internet access: its privacy policy
# says it has none. (Debug and profile builds do ask, for Flutter's tools.)
# And before installing it, that the APK asks for no permission but access
# to contacts, as the store listing says (check_permissions in
# release_lib.sh, which build_release.sh runs on every release APK too).
#
# Release builds can't be inspected with `run-as`, so this needs an emulator
# image where `adb root` works (google_apis, not google_apis_playstore). The
# app and its data are replaced, and the app is uninstalled at the end.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/emulator_lib.sh
source tool/check_lib.sh
source tool/release_lib.sh

readonly PREFS="/data/data/$APP_ID/shared_prefs/FlutterSharedPreferences.xml"
readonly DEFAULT_TEMPLATE='+447700900nnn'
readonly CUSTOM_NAMES='Zen, Zima'
readonly NO_FAKES='No fake contacts on this phone.'
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

# What it needs, checked before anything on the emulator is changed (the
# cleanup below uninstalls the app): aapt2, to read the APK's permissions;
# to sign an unsigned APK, or the one it builds, with the debug key,
# apksigner and that key.
need python3
aapt2_path >/dev/null || exit 1
# (Only read: nothing on the emulator changes yet.)
abi="$(adb_ shell getprop ro.product.cpu.abi | tr -d '\r')"
needs_signing=true
if [[ $# -ge 1 ]]; then
  apk="$(absolute_path "$1" "$CALLER_DIR")"
  [[ -f "$apk" ]] || fail "no APK at $apk"
  # One with native code must have it for the emulator's own ABI.
  check_apk_abi "$apk" "$abi"
  if is_signed "$apk"; then needs_signing=false; fi
fi
if $needs_signing; then
  apksigner_path >/dev/null || exit 1
  debug_keystore >/dev/null || exit 1
fi

# Without an APK, the one to test is built here, also before anything on
# the emulator is changed.
if [[ $# -eq 0 ]]; then
  is_release_abi "$abi" ||
    fail "releases have no APK for the emulator's ABI, '${abi:-unknown}'"
  echo "== Building the release APK for $abi"
  flutter build apk --release --split-per-abi \
    --target-platform "${ABI_PLATFORM[$abi]}"
  apk="build/app/outputs/flutter-apk/app-$abi-release.apk"
  [[ -f "$apk" ]] || fail "the build made no APK at $apk"
fi

echo "== The APK should ask for no permission but access to contacts"
# As the store listing says. (build_release.sh checks every release APK so
# too; this one may have been built some other way.)
check_permissions "$apk" "$abi"

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

# What the screen shows now, as `uiautomator dump` (accessibility services)
# sees it: XML, one tag per line once split at "<" (which an attribute
# escapes). Nothing if the dump failed, say because the app was still
# drawing its spinner, or it stalled.
dump_screen() {
  timeout 20 adb -s "$serial" exec-out uiautomator dump /dev/tty 2>/dev/null |
    tr '<' '\n' || true
}

# The text in the app's text field labelled $1, as the screen shows it now;
# nothing if there is no such field (or the dump failed). A label or text
# with &, < or " in it is escaped in the dump, so this only works for plain
# ones.
field_text() {
  dump_screen |
    grep -F "class=\"android.widget.EditText\"" |
    grep -F "hint=\"$1\"" |
    sed -n 's/.* text="\([^"]*\)".*/\1/p' |
    head -n 1 || true
}

# Whether the app's screen now shows the plain text $1, as a label or as
# text (escaped as field_text says).
screen_shows() {
  dump_screen | grep -q -F -e "content-desc=\"$1\"" -e "text=\"$1\""
}

wait_for_text() {
  local deadline=$((SECONDS + TIMEOUT_S))
  until screen_shows "$1"; do
    wake_screen # in case it went off meanwhile
    check_no_errors
    if (( SECONDS >= deadline )); then
      fail "after ${TIMEOUT_S}s, the app doesn't show '$1'"
    fi
    sleep 1
  done
}

# Puts back the stored settings from $1 (a copy on this computer), with
# cat, which keeps the file's owner and SELinux label.
write_prefs() {
  adb_ push "$1" /data/local/tmp/decoy_contacts_prefs.xml >/dev/null 2>&1 ||
    fail "couldn't copy the edited settings to the device"
  adb_ shell "cat /data/local/tmp/decoy_contacts_prefs.xml > $PREFS && rm /data/local/tmp/decoy_contacts_prefs.xml" ||
    fail "couldn't write the app's settings file"
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
      # Which window was in front, in case it wasn't the app's.
      fail "after ${TIMEOUT_S}s, the $label field shows '$shown'," \
           "expected '$want'; in front:" \
           "$(adb_ shell dumpsys window | grep -m 1 mCurrentFocus | tr -d '\r')"
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

if $needs_signing; then
  echo "== Signing a copy with the debug key"
  debug_sign "$apk" "$tmp/debug-signed.apk" ||
    fail "couldn't sign $apk with the debug key"
  apk="$tmp/debug-signed.apk"
fi

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
write_prefs "$tmp/edited.xml"
[[ "$(pref sListOfLastNames)" == "$CUSTOM_NAMES" ]] ||
  fail "couldn't change the stored settings"

echo "== Second start: the app should show the stored names"
start_app
wait_for_field "Last names" "$CUSTOM_NAMES"
check_app_ok
# Still stored as they were.
[[ "$(pref sListOfLastNames)" == "$CUSTOM_NAMES" ]] ||
  fail "last names are now stored as '$(pref sListOfLastNames)'," \
       "expected '$CUSTOM_NAMES'"
adb_ shell am force-stop "$APP_ID"

echo "== Third start, with access to contacts: the app should read them"
for permission in READ_CONTACTS WRITE_CONTACTS; do
  adb_ shell pm grant "$APP_ID" "android.permission.$permission" ||
    fail "couldn't grant $permission"
done
# Raw contact IDs start at 1, so raw contact 0 never exists. (In the file,
# the JSON's quotes are &quot;, and & is special in sed's replacement.)
adb_ pull "$PREFS" "$tmp/prefs.xml" >/dev/null 2>&1 ||
  fail "couldn't read the app's settings file"
sed -e 's|</map>|    <string name="flutter.fakeRawContactLedgerV1">{\&quot;0\&quot;:{\&quot;name\&quot;:\&quot;Zoe Zen\&quot;,\&quot;phone\&quot;:\&quot;\&quot;,\&quot;email\&quot;:\&quot;\&quot;}}</string>\n</map>|' \
    "$tmp/prefs.xml" > "$tmp/edited.xml"
grep -q -F 'fakeRawContactLedgerV1">{&quot;0&quot;:' "$tmp/edited.xml" ||
  fail "couldn't add a record of a fake to the settings"
write_prefs "$tmp/edited.xml"
start_app
wait_for_text "$NO_FAKES"
check_app_ok

echo "== Release build OK"
