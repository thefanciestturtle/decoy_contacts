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
echo 'version: 1.2.3+4' >"$repo/pubspec.yaml"
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
cat >"$tmp/AndroidManifest.xml" <<'EOF'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="org.example.release_test">
  <uses-sdk android:minSdkVersion="24" android:targetSdkVersion="36" />
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

# --- release_lib.sh: debug_sign
mkdir -p "$tmp/android-empty" "$tmp/android"
run "" env ANDROID_USER_HOME="$tmp/android-empty" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_sign '$tmp/clean.apk' '$tmp/debug.apk'"
expect "debug signing without a debug key fails" 1 "no debug key at $tmp/android-empty/debug.keystore"
"$keytool" -genkeypair -keystore "$tmp/android/debug.keystore" \
  -storetype PKCS12 -alias androiddebugkey -storepass android \
  -keypass android -keyalg RSA -keysize 2048 -validity 1 \
  -dname 'CN=Android Debug,O=Android,C=US' >/dev/null 2>&1
run "" env ANDROID_USER_HOME="$tmp/android" bash -c \
  "source tool/check_lib.sh; source tool/release_lib.sh; debug_sign '$tmp/clean.apk' '$tmp/debug.apk' &&
   apksigner_ verify --print-certs '$tmp/debug.apk'"
expect "debug signing signs with the debug key" 0 "CN=Android Debug"

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

run "$PW\n" tool/sign_release.sh "$tmp/missing.p12" dist/app-3.0-unsigned.apk
expect "a missing keystore fails" 1 "no keystore at $tmp/missing.p12"

echo 'not a fingerprint' >"$repo/$RELEASE_CERT_FILE"
run "$PW\n" tool/sign_release.sh "$tmp/release.p12" dist/app-3.0-unsigned.apk
expect "without a pinned fingerprint it fails" 1 "no release certificate fingerprint"
echo "$pinned" >"$repo/$RELEASE_CERT_FILE"

# --- tool/build_release.sh, up to the build
run "" tool/build_release.sh --bogus
expect "build: an unknown option fails" 2 "usage:"
run "" tool/build_release.sh HEAD HEAD
expect "build: two commits fail" 2 "usage:"
mkdir "$tmp/flutter"
git -C "$tmp/flutter" init --quiet
git -C "$tmp/flutter" -c user.name=test -c user.email=test@example.invalid \
  commit --quiet --allow-empty -m flutter
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
check "... and builds nothing" bash -c '! ls dist/decoy_contacts-*'

if ((failures)); then
  echo "$failures of $cases cases failed" >&2
  exit 1
fi
echo "All $cases cases passed"
