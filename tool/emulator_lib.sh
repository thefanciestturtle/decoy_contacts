# Shared by the scripts in tool/ that run on an Android emulator; source it.
#
# Picks the device (ANDROID_SERIAL, or the only one connected), defines
# `adb_` to talk to it, and stops unless it is an emulator: these scripts
# change the device's contacts or app data.

readonly APP_ID=me.billdietrich.fake_contacts

serial="${ANDROID_SERIAL:-$(adb get-serialno)}"
adb_() { adb -s "$serial" "$@"; }

if [[ "$(adb_ shell getprop ro.boot.qemu | tr -d '\r')" != 1 &&
      "$(adb_ shell getprop ro.kernel.qemu | tr -d '\r')" != 1 ]]; then
  echo "error: $serial is not an emulator. This script changes the" \
       "device's data, so it only runs on an emulator." >&2
  exit 1
fi
