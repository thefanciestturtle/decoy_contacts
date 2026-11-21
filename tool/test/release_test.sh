#!/usr/bin/env bash
# Tests the release scripts: tool/make_release_key.sh and
# tool/sign_release.sh with throwaway keys and small APKs made with aapt2,
# tool/build_release.sh's checks before it builds, tool/apk_check.py and
# tool/release_lib.sh. Builds no app: CI runs tool/build_release.sh itself.
#
#   tool/test/release_test.sh
#
# Needs the Android SDK (ANDROID_HOME) with build-tools 35 or newer and a
# platform, a JDK (JAVA_HOME or keytool on the PATH), python3, openssl,
# git, bwrap and setsid. The scripts run without a terminal, so keytool and
# apksigner read the passwords from the test, never from you.
set -euo pipefail

cd "$(dirname "$0")/../.."
source tool/check_lib.sh
source tool/release_lib.sh
# Set by the tests themselves, for one call each; not taken from outside.
unset RELEASE_TEST_MANIFEST RELEASE_TEST_MIN_SDK

java_home="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
keytool="$java_home/bin/keytool"
need python3 openssl setsid git "$keytool"
java_major="$(java_version "$java_home/bin/java")"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A copy of the scripts, in a git repository of its own: they write the
# pinned fingerprint and dist/ next to themselves.
repo="$tmp/repo"
mkdir -p "$repo/tool" "$repo/.github/workflows" "$repo/dist"
cp tool/check_lib.sh tool/release_lib.sh tool/apk_check.py \
  tool/make_release_key.sh tool/sign_release.sh tool/build_release.sh \
  tool/debug_sign.sh "$repo/tool/"
echo 'version: 1.2.3+401' >"$repo/pubspec.yaml"
git -C "$repo" init --quiet
# commit FLUTTER JAVA [TAG] : commits CI's versions of Flutter and the JDK.
commit() {
  printf '  FLUTTER_VERSION: %s\n  JAVA_VERSION: "%s"\n' "$1" "$2" \
    >"$repo/.github/workflows/dart.yml"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid \
    commit --quiet -m test
  if [[ -n "${3:-}" ]]; then git -C "$repo" tag "$3"; fi
}
commit 9.97.0 "$java_major" older-flutter
commit 9.99.0 "$((java_major + 1))" other-jdk
echo 'version: 1.2.3' >"$repo/pubspec.yaml"
commit 9.99.0 "$java_major" no-build-number
echo 'version: 1.2.3+401' >"$repo/pubspec.yaml"
commit 9.99.0 "$java_major"

failures=0
cases=0

# run INPUT COMMAND... : runs COMMAND in the copy (or in folder RUN_IN),
# without a terminal and with INPUT on stdin; sets $status and $out (stdout
# and stderr).
run() {
  local input=$1
  shift
  status=0
  out="$(cd "${RUN_IN:-$repo}" && printf '%b' "$input" | setsid -w "$@" 2>&1)" ||
    status=$?
}

# expect NAME STATUS TEXT : wants the last run to have exited with STATUS
# and printed TEXT.
expect() {
  cases=$((cases + 1))
  if [[ "$status" == "$2" && "$out" == *"$3"* ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: exit $status (want $2), output (want '$3'):"
    while IFS= read -r line; do echo "    $line"; done <<<"$out"
    failures=$((failures + 1))
  fi
}

# expect_exact NAME STATUS TEXT : as expect, but the output must be TEXT
# exactly.
expect_exact() {
  cases=$((cases + 1))
  if [[ "$status" == "$2" && "$out" == "$3" ]]; then
    echo "ok: $1"
  else
    echo "FAIL: $1: exit $status (want $2), output '$out' (want '$3')"
    failures=$((failures + 1))
  fi
}

# check NAME COMMAND... : wants COMMAND to succeed.
check() {
  cases=$((cases + 1))
  if (cd "$repo" && "${@:2}") >/dev/null 2>&1; then
    echo "ok: $1"
  else
    echo "FAIL: $1"
    failures=$((failures + 1))
  fi
}

# The certificate in keystore $1 (alias $2, password $3), as text.
cert_text() {
  "$keytool" -exportcert -rfc -keystore "$1" -alias "$2" -storepass "$3" |
    openssl x509 -noout -nameopt RFC2253 -subject -issuer -startdate \
      -enddate -fingerprint -sha256 -text
}

# --- APKs: a tiny app made with aapt2, with a native library holding
# $2 added uncompressed (as Gradle stores native libraries) and out of line,
# so an apksigner that realigns files would change it.
sdk="$(android_sdk)"
build_tools="$(dirname "$(apksigner_path)")"
platform="$(printf '%s\n' "$sdk"/platforms/android-*/ | sort -V | tail -n 1)"
cat >"$tmp/AndroidManifest.xml" <<EOF
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="org.example.release_test">
  <uses-sdk android:minSdkVersion="$RELEASE_MIN_SDK" android:targetSdkVersion="36" />
  <application />
</manifest>
EOF
"$build_tools/aapt2" link -o "$tmp/base.apk" \
  --manifest "$tmp/AndroidManifest.xml" -I "$platform/android.jar"

make_apk() {
  cp "$tmp/base.apk" "$1"
  python3 -I - "$1" "$2" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a', zipfile.ZIP_STORED) as apk:
    apk.writestr('lib/x86_64/libapp.so',
                 b'\x7fELF' + bytes(99) + sys.argv[2].encode() + bytes(5000))
EOF
}

# add_block APK ID... : puts an APK signing block holding blocks with these
# IDs (with made-up contents) into APK, as a signing tool would, after the
# bytes PADDING (hex; none by default).
add_block() {
  python3 -I - "$@" <<'EOF'
import os, struct, sys
path, ids = sys.argv[1], [int(i, 16) for i in sys.argv[2:]]
padding = bytes.fromhex(os.environ.get('PADDING', ''))
data = open(path, 'rb').read()
eocd = data.rfind(b'PK\x05\x06')
cd = struct.unpack('<I', data[eocd + 16:eocd + 20])[0]
pairs = b''.join(struct.pack('<QI', 4 + 8, i) + bytes(8) for i in ids)
size = len(pairs) + 8 + 16
block = padding + struct.pack('<Q', size) + pairs + struct.pack('<Q', size) + b'APK Sig Block 42'
out = bytearray(data[:cd] + block + data[cd:])
field = eocd + len(block) + 16
out[field:field + 4] = struct.pack('<I', cd + len(block))
open(path, 'wb').write(bytes(out))
EOF
}

readonly CLEAN='file:///home/vagrant/build/org.example/.dart_tool/flutter_build/dart_plugin_registrant.dart'
readonly LEAK='file:///home/someone/code/app/.dart_tool/flutter_build/dart_plugin_registrant.dart'
make_apk "$tmp/clean.apk" "$CLEAN"
make_apk "$tmp/leak.apk" "$LEAK"
make_apk "$tmp/arm.apk" "$CLEAN for arm" # another clean one

# --- tool/apk_check.py
check "an unsigned APK has no signature" bash -c \
  "[[ -z \"\$(python3 -I tool/apk_check.py signature '$tmp/clean.apk')\" ]]"
cp "$tmp/clean.apk" "$tmp/blocks.apk"
add_block "$tmp/blocks.apk" 7109871a 504b4453 42726577 12345678
run "" python3 -I tool/apk_check.py signature "$tmp/blocks.apk"
expect "the blocks of a signing block are named" 0 $'v2\ndependency-info\npadding\n0x12345678'
run "" python3 -I tool/apk_check.py home-paths "$tmp/clean.apk"
expect "paths in /home/vagrant/ are fine" 0 ""
run "" python3 -I tool/apk_check.py home-paths "$tmp/leak.apk"
expect "a path in another home folder fails" 1 \
  "lib/x86_64/libapp.so: /home/someone/code/app/.dart_tool"
for home in /var/home/someone /Users/someone /root; do
  make_apk "$tmp/other-home.apk" "file://$home/app/main.dart"
  run "" python3 -I tool/apk_check.py home-paths "$tmp/other-home.apk"
  expect "a path in $home fails too" 1 "libapp.so: $home/app/main.dart"
done
# add_entry APK NAME HOW TEXT : adds a file holding TEXT, as UTF-16 or
# zlib-compressed (HOW: utf16, zlib).
add_entry() {
  python3 -I - "$@" <<'EOF'
import sys, zipfile, zlib
path, name, how, text = sys.argv[1:]
if how == 'utf16':
    data = b'\0\1' + text.encode('utf-16-le') + b'\0\0'
else:
    data = zlib.compress(text.encode())
with zipfile.ZipFile(path, 'a') as apk:
    apk.writestr(name, data)
EOF
}
cp "$tmp/clean.apk" "$tmp/utf16.apk"
add_entry "$tmp/utf16.apk" res/raw/allowed.bin utf16 "x /home/vagrant/build/y"
run "" python3 -I tool/apk_check.py home-paths "$tmp/utf16.apk"
expect "UTF-16 text in /home/vagrant/ is fine" 0 ""
add_entry "$tmp/utf16.apk" res/raw/strings.bin utf16 "x /home/someone/app"
run "" python3 -I tool/apk_check.py home-paths "$tmp/utf16.apk"
expect "UTF-16 text naming another home folder fails" 1 \
  "res/raw/strings.bin: /home/someone/app"
cp "$tmp/clean.apk" "$tmp/zlib.apk"
add_entry "$tmp/zlib.apk" assets/flutter_assets/NOTICES.Z zlib "see /Users/someone/app"
run "" python3 -I tool/apk_check.py home-paths "$tmp/zlib.apk"
expect "a home folder inside a compressed asset fails" 1 \
  "assets/flutter_assets/NOTICES.Z: /Users/someone/app"
make_apk "$tmp/names.apk" "built on buildhost7 by abc"
run "" python3 -I tool/apk_check.py home-paths "$tmp/names.apk" buildhost7
expect "a text it is given fails" 1 "libapp.so: buildhost7"
run "" python3 -I tool/apk_check.py home-paths "$tmp/names.apk" abc
expect "... unless it is shorter than 4 characters" 0 ""
run "" python3 -I tool/apk_check.py home-paths
expect "home-paths without an APK fails" 2 "apk_check.py home-paths APK"
run "" python3 -I tool/apk_check.py only-signature-added "$tmp/clean.apk" "$tmp/clean.apk"
expect "an unsigned APK isn't a signed one" 1 "has no APK signing block"
run "" python3 -I tool/apk_check.py only-signature-added "$tmp/blocks.apk" "$tmp/clean.apk"
expect "a signing block added and nothing else passes" 0 ""
run "" python3 -I tool/apk_check.py only-signature-added "$tmp/blocks.apk" "$tmp/leak.apk"
expect "a signing block added to another APK fails" 1 "is not"
cp "$tmp/clean.apk" "$tmp/padded.apk"
PADDING=000000000000 add_block "$tmp/padded.apk" 7109871a
run "" python3 -I tool/apk_check.py only-signature-added "$tmp/padded.apk" "$tmp/clean.apk"
expect "zeros before the signing block are fine" 0 ""
cp "$tmp/clean.apk" "$tmp/padded.apk"
PADDING=000000ff0000 add_block "$tmp/padded.apk" 7109871a
run "" python3 -I tool/apk_check.py only-signature-added "$tmp/padded.apk" "$tmp/clean.apk"
expect "anything else before the signing block fails" 1 "is not"
run "" python3 -I tool/apk_check.py signature "$tmp/AndroidManifest.xml"
expect "a file that isn't an APK fails" 2 "AndroidManifest.xml"
cp "$tmp/clean.apk" "$tmp/clean2.apk"
run "" python3 -I tool/apk_check.py same "$tmp/clean.apk" "$tmp/clean2.apk"
expect "the same APK twice is the same" 0 ""
run "" python3 -I tool/apk_check.py same "$tmp/clean.apk" "$tmp/leak.apk"
expect "APKs that differ inside list the files" 1 $'differ\n  lib/x86_64/libapp.so'
run "" python3 -I tool/apk_check.py same "$tmp/clean.apk" "$tmp/blocks.apk"
expect "APKs that differ only outside their files say so" 1 \
  "not in the files they hold"
run "" python3 -I tool/apk_check.py abis "$tmp/clean.apk"
expect_exact "abis: the ABI an APK has native code for" 0 "x86_64"
cp "$tmp/clean.apk" "$tmp/fat.apk"
add_entry "$tmp/fat.apk" lib/arm64-v8a/libapp.so zlib "code"
add_entry "$tmp/fat.apk" lib/arm64-v8a/libflutter.so zlib "code"
add_entry "$tmp/fat.apk" lib/notes.txt zlib "not an ABI's folder"
run "" python3 -I tool/apk_check.py abis "$tmp/fat.apk"
expect_exact "abis: each ABI of a fat APK, once" 0 $'arm64-v8a\nx86_64'
check "abis: an APK without native code has none" bash -c \
  "[[ -z \"\$(python3 -I tool/apk_check.py abis '$tmp/base.apk')\" ]]"

# --- release_lib.sh: apksigner from the newest build-tools, 35 or newer.
for v in 34.0.0 35.0.0 36.1.0 36.0.0; do
  mkdir -p "$tmp/sdk/build-tools/$v"
  touch "$tmp/sdk/build-tools/$v/apksigner"
  chmod +x "$tmp/sdk/build-tools/$v/apksigner"
done
mkdir -p "$tmp/sdk/build-tools/37.0.0" # no apksigner in it
for v in 36.2.0-rc1 37.0.0-rc1; do # previews
  mkdir -p "$tmp/sdk/build-tools/$v"
  touch "$tmp/sdk/build-tools/$v/apksigner"
  chmod +x "$tmp/sdk/build-tools/$v/apksigner"
done
run "" env ANDROID_HOME="$tmp/sdk" bash -c \
  'source tool/check_lib.sh; source tool/release_lib.sh; apksigner_path'
expect "apksigner from the newest build-tools release that has one" 0 \
  "$tmp/sdk/build-tools/36.1.0/apksigner"
rm -r "$tmp/sdk/build-tools/"3[5-7]*
run "" env ANDROID_HOME="$tmp/sdk" bash -c \
  'source tool/check_lib.sh; source tool/release_lib.sh; apksigner_path'
expect "apksigner older than 35 fails" 1 "build-tools 35 or newer"
run "" env -u ANDROID_HOME -u ANDROID_SDK_ROOT bash -c \
  'source tool/check_lib.sh; source tool/release_lib.sh; apksigner_path'
expect "no Android SDK fails" 1 "set ANDROID_HOME"

# --- release_lib.sh: aapt2 from the newest build-tools release that has it
for v in 36.0.0 37.0.0 38.0.0-rc1; do
  mkdir -p "$tmp/sdk2/build-tools/$v"
  touch "$tmp/sdk2/build-tools/$v/aapt2"
  chmod +x "$tmp/sdk2/build-tools/$v/aapt2"
done
mkdir -p "$tmp/sdk2/build-tools/38.0.0" # no aapt2 in it
run "" env ANDROID_HOME="$tmp/sdk2" bash -c \
  'source tool/check_lib.sh; source tool/release_lib.sh; aapt2_path'
expect "aapt2 from the newest build-tools release that has one" 0 \
  "$tmp/sdk2/build-tools/37.0.0/aapt2"
run "" env ANDROID_HOME="$tmp/sdk" bash -c \
  'source tool/check_lib.sh; source tool/release_lib.sh; aapt2_path'
expect "no aapt2 fails" 1 "this needs aapt2"

# --- release_lib.sh: apk_version
"$build_tools/aapt2" link -o "$tmp/versioned.apk" \
  --manifest "$tmp/AndroidManifest.xml" -I "$platform/android.jar" \
  --version-code 4012 --version-name 1.2.3
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_version '$tmp/versioned.apk'"
expect "apk_version: the versionCode and versionName" 0 "4012 1.2.3"
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_version '$tmp/base.apk' || echo none"
expect "apk_version: an APK without a versionCode fails" 0 "none"

# --- release_lib.sh: apk_min_sdk
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_min_sdk '$tmp/versioned.apk'"
expect_exact "apk_min_sdk: the minSdkVersion" 0 "$RELEASE_MIN_SDK"
# An aapt2 that says it as aapt did ("sdkVersion"), and nothing else that
# ends in it.
mkdir -p "$tmp/sdk-aapt/build-tools/99.0.0"
cat >"$tmp/sdk-aapt/build-tools/99.0.0/aapt2" <<'EOF2'
#!/usr/bin/env bash
echo "package: name='org.example.release_test' versionCode='1' versionName='1'"
echo "sdkVersion:'23'"
echo "targetSdkVersion:'36'"
EOF2
chmod +x "$tmp/sdk-aapt/build-tools/99.0.0/aapt2"
run "" env ANDROID_HOME="$tmp/sdk-aapt" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_min_sdk '$tmp/versioned.apk'"
expect_exact "apk_min_sdk: an older aapt2's sdkVersion" 0 "23"
cat >"$tmp/no-sdk-manifest.xml" <<'EOF2'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="org.example.release_test">
  <application />
</manifest>
EOF2
"$build_tools/aapt2" link -o "$tmp/no-sdk.apk" \
  --manifest "$tmp/no-sdk-manifest.xml" -I "$platform/android.jar"
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_min_sdk '$tmp/no-sdk.apk' || echo none"
expect_exact "apk_min_sdk: an APK without a minSdkVersion fails" 0 "none"
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apk_min_sdk '$tmp/AndroidManifest.xml' || echo none"
expect "apk_min_sdk: a file that isn't an APK fails" 0 "none"

# --- release_lib.sh: pubspec_version
# pubspec CONTENTS NAME WANT : wants pubspec_version of a pubspec.yaml
# holding CONTENTS to print WANT (or fail: "none").
pubspec() {
  printf '%b' "$1" >"$tmp/pubspec.yaml"
  run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; pubspec_version '$tmp/pubspec.yaml' || echo none"
  expect_exact "pubspec_version: $2" 0 "$3"
}
pubspec 'name: app\nversion: 2.0.2+401\n' "the name and the build number" "2.0.2 401"
pubspec "version: '2.0.2+415' # the release\n" "quoted, with a comment" "2.0.2 415"
pubspec 'version: 2.0.2\n' "without a build number it fails" "none"
pubspec 'version: 2.0.2+401\nversion: 2.0.3+402\n' "two versions fail" "none"
pubspec 'name: app\n' "no version fails" "none"
# RELEASE_MIN_BUILD (401) is the first build number whose codes, 4011 to
# 4013, are above 2.0.1's highest, 4006, which had Flutter's own numbering.
pubspec 'version: 2.0.2+401\n' "the lowest build number, 401" "2.0.2 401"
pubspec 'version: 2.0.2+400\n' "build number 400 fails (its codes could be below 4006)" "none"
pubspec 'version: 2.0.1+6\n' "2.0.1's build number fails" "none"
pubspec 'version: 2.0.2+99\n' "a two-digit build number fails" "none"
pubspec 'version: 2.0.2+999999\n' "build number 999999" "2.0.2 999999"
pubspec 'version: 2.0.2+1000000\n' "build number 1000000 fails" "none"
pubspec 'version: 2.0.2+0\n' "build number 0 fails" "none"
pubspec 'version: 2.0.2+0401\n' "a leading zero fails" "none"
pubspec 'version: "2.0.2+401"\n' "double quotes" "2.0.2 401"
pubspec 'version: 2.0.2+401\r\n' "a Windows line end" "2.0.2 401"
pubspec 'version: 2.0.2-rc.1+401\n' "a name with more than numbers and dots fails" "none"
pubspec 'version: 1.0/../x+401\n' "... say one that would make a path" "none"
pubspec 'version: 2.0.2+401#x\n' "a # with no space before it isn't a comment" "none"
pubspec 'version: "2.0.2+401 #x"\n' "... nor one inside quotes" "none"

# --- release_lib.sh: the release ABIs, each with a code and a platform
# (and no code or platform for another).
# shellcheck disable=SC2016 # (the inner bash expands it)
run "" bash -c 'source tool/check_lib.sh; source tool/release_lib.sh
  for abi in "${RELEASE_ABIS[@]}"; do
    [[ -n "${ABI_CODE[$abi]:-}" && -n "${ABI_PLATFORM[$abi]:-}" ]] || echo "missing: $abi"
  done
  for abi in "${!ABI_CODE[@]}" "${!ABI_PLATFORM[@]}"; do
    is_release_abi "$abi" || echo "extra: $abi"
  done
  echo "codes: $(printf "%s\n" "${ABI_CODE[@]}" | sort -u | wc -l) of ${#RELEASE_ABIS[@]}"'
expect_exact "the release ABIs each have their own code and a platform" 0 "codes: 3 of 3"

# --- release_lib.sh: check_apk_abi
check_abi() {
  run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; check_apk_abi '$1' '$2' && echo fine"
}
check_abi "$tmp/clean.apk" x86_64
expect "check_apk_abi: an APK with native code for the ABI passes" 0 fine
check_abi "$tmp/clean.apk" arm64-v8a
expect "check_apk_abi: one without fails" 1 \
  "$tmp/clean.apk has native code for x86_64, not for arm64-v8a"
check_abi "$tmp/fat.apk" arm64-v8a
expect "check_apk_abi: a fat APK with it passes" 0 fine
check_abi "$tmp/base.apk" arm64-v8a
expect "check_apk_abi: an APK without native code passes" 0 fine
check_abi "$tmp/clean.apk" ""
expect "check_apk_abi: an unknown ABI fails" 1 "not for an unknown ABI"

# --- release_lib.sh: check_release_apk, on APKs made with aapt2
# release_apk OUT CODE NAME TEXT [ABI...] : an APK with versionCode CODE
# and versionName NAME, holding TEXT in a native library for each ABI
# (x86_64 by default). Its manifest is $RELEASE_TEST_MANIFEST if set,
# else the tiny app's.
release_apk() {
  local out=$1 code=$2 name=$3 text=$4
  shift 4
  "$build_tools/aapt2" link -o "$out" \
    --manifest "${RELEASE_TEST_MANIFEST:-$tmp/AndroidManifest.xml}" \
    -I "$platform/android.jar" --version-code "$code" --version-name "$name"
  python3 -I - "$out" "$text" "${@:-x86_64}" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'a', zipfile.ZIP_STORED) as apk:
    for abi in sys.argv[3:]:
        apk.writestr('lib/%s/libapp.so' % abi, sys.argv[2].encode())
EOF
}
# check_apk NAME STATUS TEXT APK ABI VERSION BUILD
check_apk() {
  run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; check_release_apk '$4' '$5' '$6' '$7' && echo fine"
  expect "check_release_apk: $1" "$2" "$3"
}
release_apk "$tmp/split.apk" 4013 1.2.3 "$CLEAN"
check_apk "the right APK passes" 0 fine "$tmp/split.apk" x86_64 1.2.3 401
check_apk "another ABI's APK fails" 1 \
  "the arm64-v8a APK has native code for: x86_64" "$tmp/split.apk" arm64-v8a 1.2.3 401
check_apk "another build number fails" 1 \
  "has versionCode and versionName '4013 1.2.3', not '4023 1.2.3' (10 * 402 + 3)" \
  "$tmp/split.apk" x86_64 1.2.3 402
check_apk "another versionName fails" 1 "not '4013 1.2.4'" \
  "$tmp/split.apk" x86_64 1.2.4 401
# Another ABI's digit (4012 is arm64-v8a's), and Flutter's own code for the
# ABI (4 * 1000 + 401), which android/app/build.gradle.kts replaces: a
# build that lost that block would make these.
release_apk "$tmp/arm64-code.apk" 4012 1.2.3 "$CLEAN"
check_apk "another ABI's digit fails" 1 \
  "has versionCode and versionName '4012 1.2.3', not '4013 1.2.3' (10 * 401 + 3)" \
  "$tmp/arm64-code.apk" x86_64 1.2.3 401
release_apk "$tmp/flutter-code.apk" 4401 1.2.3 "$CLEAN"
check_apk "Flutter's own code for the ABI fails" 1 \
  "has versionCode and versionName '4401 1.2.3', not '4013 1.2.3' (10 * 401 + 3)" \
  "$tmp/flutter-code.apk" x86_64 1.2.3 401
release_apk "$tmp/fat-split.apk" 4013 1.2.3 "$CLEAN" arm64-v8a x86_64
check_apk "an APK with other ABIs too fails" 1 \
  "has native code for: arm64-v8a x86_64" "$tmp/fat-split.apk" x86_64 1.2.3 401
"$build_tools/aapt2" link -o "$tmp/no-code.apk" --manifest "$tmp/AndroidManifest.xml" \
  -I "$platform/android.jar" --version-code 4013 --version-name 1.2.3
check_apk "an APK without native code fails" 1 "has native code for: none" \
  "$tmp/no-code.apk" x86_64 1.2.3 401
release_apk "$tmp/leak-split.apk" 4013 1.2.3 "$LEAK"
check_apk "an APK naming a home folder fails" 1 "names a home folder" \
  "$tmp/leak-split.apk" x86_64 1.2.3 401
add_block "$tmp/split.apk" 7109871a
check_apk "a signed APK fails" 1 "the x86_64 APK is signed" \
  "$tmp/split.apk" x86_64 1.2.3 401

# permissions_apk OUT TAG... : a release APK for x86_64 (4013, 1.2.3) whose
# manifest has these tags too, and the minSdkVersion $RELEASE_TEST_MIN_SDK
# (if unset, RELEASE_MIN_SDK).
permissions_apk() {
  local out=$1
  shift
  {
    echo '<manifest xmlns:android="http://schemas.android.com/apk/res/android"'
    echo '    package="org.example.release_test">'
    echo "  <uses-sdk android:minSdkVersion=\"${RELEASE_TEST_MIN_SDK:-$RELEASE_MIN_SDK}\" android:targetSdkVersion=\"36\" />"
    printf '  %s\n' "$@"
    echo '  <application />'
    echo '</manifest>'
  } >"$tmp/permissions-manifest.xml"
  RELEASE_TEST_MANIFEST="$tmp/permissions-manifest.xml" \
    release_apk "$out" 4013 1.2.3 "$CLEAN"
}
uses() { echo "<uses-permission $* />"; }
readonly OWN=org.example.release_test.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION
permissions_apk "$tmp/contacts.apk" \
  "$(uses 'android:name="android.permission.READ_CONTACTS"')" \
  "$(uses 'android:name="android.permission.WRITE_CONTACTS"')" \
  "<permission android:name=\"$OWN\" android:protectionLevel=\"signature\" />" \
  "$(uses "android:name=\"$OWN\"")"
check_apk "one asking only for contacts and its own permission passes" 0 \
  fine "$tmp/contacts.apk" x86_64 1.2.3 401
permissions_apk "$tmp/internet.apk" \
  "$(uses 'android:name="android.permission.READ_CONTACTS"')" \
  "$(uses 'android:name="android.permission.INTERNET"')"
check_apk "one asking for internet access fails" 1 \
  "the x86_64 APK asks for android.permission.INTERNET" \
  "$tmp/internet.apk" x86_64 1.2.3 401
permissions_apk "$tmp/sdk23.apk" \
  '<uses-permission-sdk-23 android:name="android.permission.CAMERA" />'
check_apk "one asking for more from Android 6 on fails" 1 \
  "the x86_64 APK asks for android.permission.CAMERA" \
  "$tmp/sdk23.apk" x86_64 1.2.3 401
permissions_apk "$tmp/max-sdk.apk" \
  "$(uses 'android:maxSdkVersion="32" android:name="android.permission.READ_PHONE_STATE"')"
check_apk "one asking for more up to some Android version fails" 1 \
  "the x86_64 APK asks for android.permission.READ_PHONE_STATE" \
  "$tmp/max-sdk.apk" x86_64 1.2.3 401
permissions_apk "$tmp/other-own.apk" \
  "$(uses 'android:name="org.example.other.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"')"
check_apk "one asking for another app's own permission fails" 1 \
  "asks for org.example.other.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" \
  "$tmp/other-own.apk" x86_64 1.2.3 401
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; check_permissions '$tmp/AndroidManifest.xml' x86_64 && echo fine"
expect "check_permissions: a file that isn't an APK fails" 1 \
  "couldn't read the x86_64 APK's permissions"
newer=$((RELEASE_MIN_SDK + 2))
RELEASE_TEST_MIN_SDK=$newer permissions_apk "$tmp/min-sdk-newer.apk"
check_apk "one for a newer Android than the README says fails" 1 \
  "the x86_64 APK's minSdkVersion is $newer, not $RELEASE_MIN_SDK" \
  "$tmp/min-sdk-newer.apk" x86_64 1.2.3 401
older=$((OLDEST_SIGNABLE_SDK - 3))
RELEASE_TEST_MIN_SDK=$older permissions_apk "$tmp/min-sdk-older.apk"
check_apk "one for an Android without v2 signatures fails, saying why" 1 \
  "the x86_64 APK's minSdkVersion is $older, but release APKs have no v1 signature" \
  "$tmp/min-sdk-older.apk" x86_64 1.2.3 401
RELEASE_TEST_MANIFEST="$tmp/no-sdk-manifest.xml" \
  release_apk "$tmp/no-sdk-split.apk" 4013 1.2.3 "$CLEAN"
check_apk "one without a minSdkVersion fails" 1 \
  "couldn't read the x86_64 APK's minSdkVersion" "$tmp/no-sdk-split.apk" x86_64 1.2.3 401

# --- release_lib.sh: debug_sign
mkdir -p "$tmp/android-empty" "$tmp/android"
run "" env ANDROID_USER_HOME="$tmp/android-empty" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_sign '$tmp/clean.apk' '$tmp/debug.apk'"
expect "debug signing without a debug key fails" 1 "no debug key at $tmp/android-empty/debug.keystore"
run "" env ANDROID_USER_HOME="$tmp/android-empty" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_keystore"
expect "... and debug_keystore says so" 1 "no debug key at $tmp/android-empty/debug.keystore"
"$keytool" -genkeypair -keystore "$tmp/android/debug.keystore" \
  -storetype PKCS12 -alias androiddebugkey -storepass android \
  -keypass android -keyalg RSA -keysize 2048 -validity 1 \
  -dname 'CN=Android Debug,O=Android,C=US' >/dev/null 2>&1
run "" env ANDROID_USER_HOME="$tmp/android" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_sign '$tmp/clean.apk' '$tmp/debug.apk' &&
   apksigner_ verify --print-certs '$tmp/debug.apk'"
expect "debug signing signs with the debug key" 0 "CN=Android Debug"
# (A home folder without one, so no other debug key can stand in.)
mkdir -p "$tmp/prefs-root" "$tmp/no-home"
cp -r "$tmp/android" "$tmp/prefs-root/.android"
run "" env -u ANDROID_USER_HOME HOME="$tmp/no-home" \
  ANDROID_PREFS_ROOT="$tmp/prefs-root" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_sign '$tmp/clean.apk' '$tmp/debug2.apk' && echo signed"
expect "... also from ANDROID_PREFS_ROOT" 0 "signed"

# --- tool/debug_sign.sh
cp "$tmp/clean.apk" "$tmp/app-release.apk"
RUN_IN="$tmp" run "" env ANDROID_USER_HOME="$tmp/android" \
  repo/tool/debug_sign.sh app-release.apk
expect "debug_sign.sh signs a copy next to the APK" 0 \
  "Signed with the debug key: $tmp/app-release-debug-signed.apk"
check "... which verifies" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; apksigner_ verify '$tmp/app-release-debug-signed.apk'"
check "... signed as releases are: v2 and v3, nothing else added" bash -c \
  "[[ \"\$(python3 -I tool/apk_check.py signature '$tmp/app-release-debug-signed.apk' | tr '\n' ' ')\" == 'v2 v3 '* ]] &&
   python3 -I tool/apk_check.py only-signature-added '$tmp/app-release-debug-signed.apk' '$tmp/app-release.apk'"
check "... leaving the APK unsigned" bash -c \
  "[[ -z \"\$(python3 -I tool/apk_check.py signature '$tmp/app-release.apk')\" ]]"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  "$tmp/app-release-debug-signed.apk" "$tmp/twice.apk"
expect "debug_sign.sh won't sign a signed APK" 1 "is already signed"
before="$(sha256sum "$tmp/app-release.apk")"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  "$tmp/app-release.apk" "$tmp/app-release.apk"
expect "debug_sign.sh won't write over its APK" 1 "already exists"
check "... which is left as it was" \
  test "$(sha256sum "$tmp/app-release.apk")" == "$before"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  "$tmp/app-release.apk"
expect "debug_sign.sh won't replace an earlier copy" 1 "already exists"
cp "$tmp/clean.apk" "$repo/dist/debug-test-unsigned.apk"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  dist/debug-test-unsigned.apk
expect "debug_sign.sh won't write into dist/, with the release APKs" 1 \
  "would be in dist/, with the release APKs"
check "... and writes nothing there" test ! -e "$repo/dist/debug-test-unsigned-debug-signed.apk"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  dist/debug-test-unsigned.apk "$tmp/debug-test.apk"
expect "... but signs a copy elsewhere" 0 "Signed with the debug key: $tmp/debug-test.apk"
run "" env ANDROID_USER_HOME="$tmp/android" tool/debug_sign.sh \
  dist/debug-test-unsigned.apk "$tmp/new-folder/debug-test.apk"
expect "... also into a folder that isn't there yet" 0 \
  "Signed with the debug key: $tmp/new-folder/debug-test.apk"

# --- release_lib.sh: check_home_paths, with this computer's home folder
# (Not in a folder named "home", which fails anyway.)
mkdir -p "$tmp/people/me"
make_apk "$tmp/my-home.apk" "file://$tmp/people/me/app/main.dart"
make_apk "$tmp/near-home.apk" "file://$tmp/people/me-too/app/main.dart"
for apk in my-home near-home; do
  run "" env HOME="$tmp/people/me" bash -c \
    "source tool/check_lib.sh; source tool/release_lib.sh; check_home_paths '$tmp/$apk.apk' && echo clean"
  if [[ "$apk" == my-home ]]; then
    expect "check_home_paths: this computer's home folder fails" 1 "names a home folder"
  else
    expect "... a folder whose name only starts the same is fine" 0 "clean"
  fi
done

# --- release_lib.sh: place_releases
mkdir -p "$tmp/place"
# place APK OUT [APK OUT]... : place_releases into $tmp/place/OUT.
place() {
  local args=()
  while (($# >= 2)); do
    args+=("$1" "$tmp/place/$2")
    shift 2
  done
  run "" bash -c 'source tool/check_lib.sh; source tool/release_lib.sh; place_releases "$@"' \
    place "${args[@]}"
}
place "$tmp/clean.apk" app-1.0-unsigned.apk
expect "place_releases: a new build goes in" 0 "Built $tmp/place/app-1.0-unsigned.apk"
check "... as the same file" cmp "$tmp/clean.apk" "$tmp/place/app-1.0-unsigned.apk"
place "$tmp/clean.apk" app-1.0-unsigned.apk
expect "place_releases: the same build again is kept" 0 "The same file as"
place "$tmp/leak.apk" app-1.0-unsigned.apk
expect "place_releases: another build stops" 1 "isn't the same file as"
check "... leaving the first one" cmp "$tmp/clean.apk" "$tmp/place/app-1.0-unsigned.apk"
cp "$tmp/app-release-debug-signed.apk" "$tmp/place/app-1.0.apk"
place "$tmp/clean.apk" app-1.0-unsigned.apk
expect "place_releases: a signed APK of this build is fine" 0 "The same file as"
rm "$tmp/place/app-1.0-unsigned.apk"
place "$tmp/leak.apk" app-1.0-unsigned.apk
expect "place_releases: a signed APK of another build stops" 1 \
  "isn't this build signed"
check "... and nothing goes in" test ! -e "$tmp/place/app-1.0-unsigned.apk"
# Several: all of them or none.
place "$tmp/clean.apk" app-2.0-x86_64-unsigned.apk \
  "$tmp/arm.apk" app-2.0-arm64-v8a-unsigned.apk
expect "place_releases: several go in" 0 "Built $tmp/place/app-2.0-arm64-v8a-unsigned.apk"
check "... each as its build" bash -c \
  "cmp '$tmp/clean.apk' '$tmp/place/app-2.0-x86_64-unsigned.apk' &&
   cmp '$tmp/arm.apk' '$tmp/place/app-2.0-arm64-v8a-unsigned.apk'"
cp "$tmp/leak.apk" "$tmp/place/app-3.0-x86_64-unsigned.apk"
place "$tmp/arm.apk" app-3.0-arm64-v8a-unsigned.apk \
  "$tmp/clean.apk" app-3.0-x86_64-unsigned.apk
expect "place_releases: if a later one can't go in, it stops" 1 \
  "isn't the same file as the $tmp/place/app-3.0-x86_64-unsigned.apk"
check "... before putting in any, not even an earlier one" \
  test ! -e "$tmp/place/app-3.0-arm64-v8a-unsigned.apk"
mkdir -p "$tmp/place/locked"
chmod a-w "$tmp/place/locked"
place "$tmp/arm.apk" app-4.0-arm64-v8a-unsigned.apk \
  "$tmp/clean.apk" locked/app-4.0-x86_64-unsigned.apk
chmod u+w "$tmp/place/locked"
expect "place_releases: if copying one fails, it stops" 1 \
  "couldn't copy the build to $tmp/place/locked/app-4.0-x86_64-unsigned.apk.partial"
check "... leaving none, nor a partial file" bash -c \
  "[[ ! -e '$tmp/place/app-4.0-arm64-v8a-unsigned.apk' &&
     ! -e '$tmp/place/app-4.0-arm64-v8a-unsigned.apk.partial' ]] &&
   ! ls -A '$tmp/place/locked' | grep -q ."

# --- release_lib.sh: apksigner_ allows native access only on Java 17 and
# newer. A stand-in java says it is $SPEC and rejects that option.
mkdir -p "$tmp/java/bin"
cat >"$tmp/java/bin/java" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == -XshowSettings:properties ]]; then
  echo "    java.specification.version = \$SPEC" >&2
  exit 0
fi
for arg in "\$@"; do
  [[ "\$arg" != --enable-native-access=* ]] || { echo "Unrecognized option: \$arg" >&2; exit 1; }
done
exec "$java_home/bin/java" "\$@"
EOF
chmod +x "$tmp/java/bin/java"
for spec in 11 1.8; do
  run "" env JAVA_HOME="$tmp/java" SPEC="$spec" bash -c \
    "source tool/check_lib.sh; source tool/release_lib.sh; apksigner_ verify '$tmp/debug.apk' && echo verified"
  expect "apksigner runs on Java $spec" 0 "verified"
done
run "" env JAVA_HOME="$tmp/java" SPEC=17 bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; apksigner_ verify '$tmp/debug.apk'"
expect "... and on Java 17 it allows native access" 1 \
  "Unrecognized option: --enable-native-access=ALL-UNNAMED"

# --- tool/make_release_key.sh
readonly PW=release-pw
# Not UTC, so a start date read in local time would show.
export TZ=America/Chicago
run "$PW\nother\n" tool/make_release_key.sh "$tmp/release.p12"
expect "passwords that differ fail" 1 "the passwords differ"
check "... and make no keystore" test ! -e "$tmp/release.p12"
# From another folder, with a path relative to it. (The day before and
# after, in case it is midnight UTC.)
day_before="$(TZ=UTC date +'%Y-%m-%d')"
RUN_IN="$tmp" run "$PW\n$PW\n" repo/tool/make_release_key.sh release.p12
day_after="$(TZ=UTC date +'%Y-%m-%d')"
expect "makes the key" 0 "Copy the keystore to two safe places"
check "... where it was asked to, not in the repository" bash -c \
  "[[ -f '$tmp/release.p12' && ! -e release.p12 && ! -e tool/release.p12 ]]"
cert="$(cert_text "$tmp/release.p12" release "$PW" 2>&1)" || cert=""
cases=$((cases + 1))
# validity DAY : the certificate's dates if it was made on DAY.
validity() {
  echo "notBefore=$(TZ=UTC date -d "$1" +'%b %e 00:00:00 %Y GMT')"
  echo "notAfter=$(TZ=UTC date -d "$1 +10950 days" +'%b %e 00:00:00 %Y GMT')"
}
want_sum="$(sed -n 's/^sha256 Fingerprint=//p' <<<"$cert" | tr -d ':' |
  tr '[:upper:]' '[:lower:]')"
if [[ "$cert" == *$'subject=CN=Decoy Contacts\n'* &&
      "$cert" == *$'issuer=CN=Decoy Contacts\n'* &&
      ( "$cert" == *"$(validity "$day_before")"* ||
        "$cert" == *"$(validity "$day_after")"* ) &&
      "$cert" == *"Public-Key: (4096 bit)"* &&
      "$want_sum" =~ ^[0-9a-f]{64}$ &&
      "$(cat "$repo/$RELEASE_CERT_FILE")" == "$want_sum" &&
      "$(stat -c %a "$tmp/release.p12")" == 600 ]]; then
  echo "ok: the certificate names only the app, starts at midnight UTC," \
       "lasts 30 years, has a 4096-bit key; its fingerprint is pinned"
else
  echo "FAIL: the certificate, the pinned fingerprint" \
       "'$(cat "$repo/$RELEASE_CERT_FILE")' or the keystore's mode" \
       "$(stat -c %a "$tmp/release.p12"):"
  while IFS= read -r line; do
    [[ "$line" =~ ^\ *[0-9a-f]{2}: ]] || echo "    $line" # not key bytes
  done <<<"$cert"
  failures=$((failures + 1))
fi

run "$PW\n$PW\n" tool/make_release_key.sh inside.p12
expect "won't put a key in the repository" 1 "is in the repository"
check "... and makes none there" test ! -e inside.p12
run "$PW\n$PW\n" tool/make_release_key.sh "$tmp/second.p12"
expect "won't make a second key once one is pinned" 1 "already holds"
check "... and makes no keystore" test ! -e "$tmp/second.p12"

pinned="$(cat "$repo/$RELEASE_CERT_FILE")"
: >"$repo/$RELEASE_CERT_FILE"
run "wrong\n" tool/make_release_key.sh "$tmp/release.p12"
expect "a wrong password when reading the certificate fails" 1 "run this again to retry"
check "... and pins nothing" test ! -s "$RELEASE_CERT_FILE"
run "$PW\n" tool/make_release_key.sh "$tmp/release.p12"
expect "run again, it only reads the certificate" 0 "already exists: reading its certificate"
check "... and pins it" test "$(cat "$repo/$RELEASE_CERT_FILE")" == "$pinned"
# A password with spaces at its ends is taken as typed, as sign_release.sh
# takes it.
"$keytool" -genkeypair -keystore "$tmp/spaced-release.p12" -storetype PKCS12 \
  -alias release -storepass ' sp pw 1 ' -keyalg RSA -keysize 2048 \
  -validity 1 -dname 'CN=Decoy Contacts' >/dev/null 2>&1
: >"$repo/$RELEASE_CERT_FILE"
run " sp pw 1 \n" tool/make_release_key.sh "$tmp/spaced-release.p12"
expect "a password with spaces at its ends is kept as typed" 0 \
  "The release key is in"
echo "$pinned" >"$repo/$RELEASE_CERT_FILE"
unset TZ

# --- tool/sign_release.sh
cp "$tmp/clean.apk" "$repo/dist/app-1.0-unsigned.apk"
# From another folder, with paths relative to it.
RUN_IN="$tmp" run "$PW\n" repo/tool/sign_release.sh release.p12 \
  repo/dist/app-1.0-unsigned.apk
expect "signs with the release key" 0 "Signed $repo/dist/app-1.0.apk"
signed="$repo/dist/app-1.0.apk"
check "... with v2 and v3 only" bash -c \
  "[[ \"\$(python3 -I tool/apk_check.py signature '$signed' | tr '\n' ' ')\" == 'v2 v3 '* ]]"
run "" bash -c "source tool/check_lib.sh; source tool/release_lib.sh; apksigner_ verify -v '$signed'"
expect "... and Android accepts it, without v1" 0 \
  "Verified using v1 scheme (JAR signing): false"
check "... adding only the signature" \
  python3 -I tool/apk_check.py only-signature-added "$signed" "$repo/dist/app-1.0-unsigned.apk"
check "... and leaving no partial file" bash -c '! ls dist/*.partial*'

before="$(sha256sum "$signed")"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/app-1.0-unsigned.apk
expect "won't replace a signed APK" 1 "already exists"
check "... which is left as it was" test "$(sha256sum "$signed")" == "$before"

cp "$signed" "$repo/dist/again-unsigned.apk"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/again-unsigned.apk
expect "won't sign a signed APK" 1 "is already signed"

cp "$tmp/leak.apk" "$repo/dist/leak-unsigned.apk"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/leak-unsigned.apk
expect "won't sign an APK that names a home folder" 1 "names a home folder"
check "... and writes nothing" test ! -e dist/leak.apk

cp "$tmp/AndroidManifest.xml" "$repo/dist/broken-unsigned.apk"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/broken-unsigned.apk
expect "won't sign a file that isn't an APK" 1 \
  "couldn't read $repo/dist/broken-unsigned.apk as an APK"

cp "$tmp/clean.apk" "$repo/dist/app-2.0.apk.in"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/app-2.0.apk.in
expect "wants an APK named as unsigned" 1 "isn't named like an unsigned release"

cp "$tmp/clean.apk" "$repo/dist/app-3.0-unsigned.apk"
run "wrong\n" tool/sign_release.sh "$tmp/release.p12" dist/app-3.0-unsigned.apk
expect "a wrong password fails" 1 "apksigner couldn't sign"
check "... and writes nothing" bash -c '! ls dist/app-3.0.apk*'

"$keytool" -genkeypair -keystore "$tmp/other.p12" -storetype PKCS12 \
  -alias other -storepass other-pw -keyalg RSA -keysize 2048 -validity 1 \
  -dname 'CN=Decoy Contacts' >/dev/null 2>&1
run "other-pw\n" tool/sign_release.sh "$tmp/other.p12" dist/app-3.0-unsigned.apk
expect "another key with the same name fails" 1 "isn't the release key"
check "... and writes nothing" bash -c '! ls dist/app-3.0.apk*'

# A password with spaces at its ends reaches apksigner as typed (it signs;
# then the key isn't the release key).
"$keytool" -genkeypair -keystore "$tmp/spaced.p12" -storetype PKCS12 \
  -alias spaced -storepass ' spaced pw ' -keyalg RSA -keysize 2048 \
  -validity 1 -dname 'CN=Decoy Contacts' >/dev/null 2>&1
run " spaced pw \n" tool/sign_release.sh "$tmp/spaced.p12" dist/app-3.0-unsigned.apk
expect "a password with spaces at its ends is kept as typed" 1 "isn't the release key"

run "$PW\n" tool/sign_release.sh "$tmp/missing.p12" dist/app-3.0-unsigned.apk
expect "a missing keystore fails" 1 "no keystore at $tmp/missing.p12"

echo 'not a fingerprint' >"$repo/$RELEASE_CERT_FILE"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/app-3.0-unsigned.apk
expect "without a pinned fingerprint it fails" 1 "no release certificate fingerprint"
echo "$pinned" >"$repo/$RELEASE_CERT_FILE"

run "" tool/sign_release.sh "$tmp/release.p12"
expect "without an APK it fails" 2 "usage:"

# Several at once, one APK per ABI, with the password asked once.
for v in 4.0 5.0 6.0; do
  cp "$tmp/arm.apk" "$repo/dist/app-$v-arm64-v8a-unsigned.apk"
  cp "$tmp/clean.apk" "$repo/dist/app-$v-x86_64-unsigned.apk"
done
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  dist/app-4.0-arm64-v8a-unsigned.apk dist/app-4.0-x86_64-unsigned.apk
expect "signs several APKs, with the password given once" 0 \
  "Signed $repo/dist/app-4.0-x86_64.apk"
# shellcheck disable=SC2016 # (the inner bash expands $OUT)
check "... without apksigner's own password prompts" env OUT="$out" \
  bash -c '[[ "$OUT" != *"password for signer"* ]]'
check "... each with only its signature added" bash -c \
  "for abi in arm64-v8a x86_64; do
     python3 -I tool/apk_check.py only-signature-added dist/app-4.0-\$abi.apk dist/app-4.0-\$abi-unsigned.apk || exit 1
   done"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  dist/app-5.0-x86_64-unsigned.apk ./dist/../dist/app-5.0-x86_64-unsigned.apk
expect "the same APK twice fails" 1 \
  "is given twice (as $repo/dist/app-5.0-x86_64-unsigned.apk)"
ln -s app-5.0-x86_64-unsigned.apk "$repo/dist/link-5.0-x86_64-unsigned.apk"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  dist/app-5.0-x86_64-unsigned.apk dist/link-5.0-x86_64-unsigned.apk
expect "... also through a link" 1 "link-5.0-x86_64-unsigned.apk is given twice"
rm "$repo/dist/link-5.0-x86_64-unsigned.apk"
# One that apksigner can't sign (no manifest), after one it can.
python3 -I - "$repo/dist/app-5.0-x86_64-unsigned.apk" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w') as apk:
    apk.writestr('lib/x86_64/libapp.so', bytes(100))
EOF
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  dist/app-5.0-arm64-v8a-unsigned.apk dist/app-5.0-x86_64-unsigned.apk
expect "if one can't be signed, it fails" 1 \
  "apksigner couldn't sign $repo/dist/app-5.0-x86_64-unsigned.apk"
check "... and writes none, not even the one signed before it" bash -c \
  '[[ ! -e dist/app-5.0-arm64-v8a.apk ]] && ! ls dist/*.partial*'
# One that turns up at a signed APK's place after the checks (say from
# another run) isn't written over, and the other isn't kept. A stand-in
# apksigner, in an SDK of its own, makes $APPEAR turn up as it signs.
mkdir -p "$tmp/hook-sdk/build-tools/99.0.0"
cat >"$tmp/hook-sdk/build-tools/99.0.0/apksigner" <<EOF
#!/usr/bin/env bash
if [[ " \$* " == *" sign "* && -n "\${APPEAR:-}" && ! -e "\$APPEAR" ]]; then
  if [[ "\${APPEAR_AS:-file}" == folder ]]; then
    mkdir "\$APPEAR"
  else
    echo meanwhile >"\$APPEAR"
  fi
fi
exec "$build_tools/apksigner" "\$@"
EOF
chmod +x "$tmp/hook-sdk/build-tools/99.0.0/apksigner"
cp "$tmp/arm.apk" "$repo/dist/app-7.0-arm64-v8a-unsigned.apk"
cp "$tmp/clean.apk" "$repo/dist/app-7.0-x86_64-unsigned.apk"
run "$PW\n" env ANDROID_HOME="$tmp/hook-sdk" \
  APPEAR="$repo/dist/app-7.0-x86_64.apk" tool/sign_release.sh \
  "$tmp/release.p12" dist/app-7.0-arm64-v8a-unsigned.apk \
  dist/app-7.0-x86_64-unsigned.apk
expect "a signed APK that turns up meanwhile stops it" 1 \
  "couldn't write $repo/dist/app-7.0-x86_64.apk (ln: "
# (ln's own words for it differ between versions: "File exists" here,
# "Already exists" on GitHub's runner.)
expect "... saying why" 1 "app-7.0-x86_64.apk': "
expect "... and that none was written" 1 "); none of the APKs was written"
check "... and isn't written over" \
  test "$(cat "$repo/dist/app-7.0-x86_64.apk")" == meanwhile
check "... and the other signed APK isn't kept" bash -c \
  '[[ ! -e dist/app-7.0-arm64-v8a.apk ]] && ! ls dist/*.partial*'
# The same with a folder, which ln would otherwise put the APK in.
run "$PW\n" env ANDROID_HOME="$tmp/hook-sdk" \
  APPEAR="$repo/dist/app-7.0-arm64-v8a.apk" APPEAR_AS=folder \
  tool/sign_release.sh "$tmp/release.p12" dist/app-7.0-arm64-v8a-unsigned.apk
expect "a folder that turns up meanwhile stops it too" 1 \
  "couldn't write $repo/dist/app-7.0-arm64-v8a.apk (ln: "
check "... and stays empty" bash -c '! ls -A dist/app-7.0-arm64-v8a.apk | grep -q .'

# The APK named through a link to a folder and "..": the one the system
# opens is signed, next to it.
mkdir -p "$repo/other/sub" "$repo/other/dist"
cp "$tmp/arm.apk" "$repo/other/dist/app-8.0-x86_64-unsigned.apk"
cp "$tmp/clean.apk" "$repo/dist/app-8.0-x86_64-unsigned.apk"
ln -s other/sub "$repo/link"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  link/../dist/app-8.0-x86_64-unsigned.apk
expect "a path through a link to a folder signs the file it names" 0 "Signed"
check "... next to it" python3 -I tool/apk_check.py only-signature-added \
  other/dist/app-8.0-x86_64.apk other/dist/app-8.0-x86_64-unsigned.apk
check "... and not the one the path looks like" test ! -e dist/app-8.0-x86_64.apk
cp "$repo/dist/app-4.0-x86_64.apk" "$repo/dist/app-6.0-x86_64.apk"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" \
  dist/app-6.0-arm64-v8a-unsigned.apk dist/app-6.0-x86_64-unsigned.apk
expect "if one is signed already, it fails" 1 "app-6.0-x86_64.apk already exists"
check "... before signing any" test ! -e "$repo/dist/app-6.0-arm64-v8a.apk"

# --- tool/build_release.sh, up to the build
run "" tool/build_release.sh --bogus
expect "build: an unknown option fails" 2 "usage:"
run "" tool/build_release.sh HEAD HEAD
expect "build: two commits fail" 2 "usage:"
run "" tool/build_release.sh --abi mips
expect "build: an unknown ABI fails, listing the ABIs" 2 \
  "ABIs: armeabi-v7a arm64-v8a x86_64"
run "" tool/build_release.sh --abi
expect "build: --abi without an ABI fails" 2 "usage:"
run "" tool/build_release.sh --abi ""
expect "build: --abi with an empty ABI fails" 2 "usage:"
run "" tool/build_release.sh --abi "arm64-v8a x86_64"
expect "build: --abi with two ABIs at once fails" 2 "usage:"
run "" env JAVA_HOME="$java_home" ANDROID_HOME="$tmp/sdk" tool/build_release.sh
expect "build: without aapt2 it fails" 1 "this needs aapt2"
# A stand-in for Flutter's repository.
mkdir -p "$tmp/flutter/sub" "$tmp/not-git"
echo flutter >"$tmp/flutter/README.md"
git -C "$tmp/flutter" init --quiet --initial-branch=main
git -C "$tmp/flutter" add README.md
git -C "$tmp/flutter" -c user.name=test -c user.email=test@example.invalid \
  commit --quiet -m flutter
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/not-git"
expect "build: a Flutter that isn't a git checkout fails" 1 \
  "$tmp/not-git isn't a git checkout of Flutter"
expect "build: ... and it would have built every ABI" 1 \
  " for armeabi-v7a arm64-v8a x86_64"$'\n'
run "" env JAVA_HOME="$java_home" tool/build_release.sh --abi x86_64 \
  --abi armeabi-v7a --abi x86_64 --flutter-sdk "$tmp/not-git"
expect "build: --abi chooses ABIs, each once, in the usual order" 1 \
  " for armeabi-v7a x86_64"$'\n'
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/flutter/sub"
expect "build: a folder within a checkout fails" 1 \
  "$tmp/flutter/sub isn't a git checkout of Flutter"
run "" env JAVA_HOME="$java_home" \
  tool/build_release.sh --flutter-sdk "$tmp/flutter" no-such-commit
expect "build: a commit that doesn't exist fails" 1 "no commit 'no-such-commit'"
run "" env JAVA_HOME="$java_home" \
  tool/build_release.sh --flutter-sdk "$tmp/flutter" other-jdk
expect "build: another JDK than the commit's fails" 1 \
  "JAVA_HOME is Java $java_major; this commit is built with Java $((java_major + 1))"
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/flutter"
expect "build: a Flutter that isn't a release fails" 1 "is 'not a release', not 9.99.0"
git -C "$tmp/flutter" tag 9.98.0
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/flutter"
expect "build: another Flutter version fails" 1 "is '9.98.0', not 9.99.0"
# The commit's own version, not the one checked out now; and the Flutter
# folder given relative to where the script runs.
RUN_IN="$tmp" run "" env JAVA_HOME="$java_home" \
  repo/tool/build_release.sh --flutter-sdk flutter older-flutter
expect "build: the Flutter version is the commit's" 1 \
  "Flutter in $tmp/flutter is '9.98.0', not 9.97.0"
git -C "$tmp/flutter" tag 9.99.0
run "" env JAVA_HOME="$java_home" \
  tool/build_release.sh --flutter-sdk "$tmp/flutter" no-build-number
expect "build: a version without a build number fails" 1 \
  "pubspec.yaml must look like 2.0.2+401: numbers and dots, then + and a build number from $RELEASE_MIN_BUILD (RELEASE_MIN_BUILD in tool/release_lib.sh) to 999999"
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/flutter"
expect "build: a Flutter that isn't on a branch named stable fails" 1 \
  "is on 'main', not on a branch named stable"
git -C "$tmp/flutter" checkout --quiet -B stable
echo changed >"$tmp/flutter/README.md"
run "" env JAVA_HOME="$java_home" tool/build_release.sh --flutter-sdk "$tmp/flutter"
expect "build: a Flutter with changes fails" 1 "has changes"
check "... and builds nothing" bash -c '! ls dist/decoy_contacts-*'

if ((failures)); then
  echo "$failures of $cases cases failed" >&2
  exit 1
fi
echo "All $cases cases passed"
