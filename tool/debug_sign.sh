#!/usr/bin/env bash
# Signs a copy of a release APK with the debug key, so it can be installed
# for testing. Release builds are unsigned (the release key signs them by
# hand, see tool/sign_release.sh), so `flutter run --release` and
# `adb install` can't install them as they are.
#
#   tool/debug_sign.sh APK [OUT]
#
# OUT is by default APK with "-debug-signed" before ".apk", e.g.
# build/app/outputs/flutter-apk/app-release-debug-signed.apk. Then:
# adb install OUT. Gradle makes the debug key with the first debug build.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/check_lib.sh
source tool/release_lib.sh

if (($# < 1 || $# > 2)); then
  echo "usage: tool/debug_sign.sh APK [OUT]" >&2
  exit 2
fi
apk="$(absolute_path "$1" "$CALLER_DIR")"
out="$(absolute_path "${2:-${1%.apk}-debug-signed.apk}" "$CALLER_DIR")"

need python3
[[ -f "$apk" ]] || fail "no APK at $apk"
[[ ! -e "$out" ]] || fail "$out already exists; move it away first"
if is_signed "$apk"; then
  fail "$apk is already signed"
fi
debug_sign "$apk" "$out" || fail "couldn't sign $apk with the debug key"
echo "== Signed with the debug key: $out"
