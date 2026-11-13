# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables are for the scripts that source it
# Shared by the scripts in tool/ that build, sign or install release APKs;
# source it from the repository's root, after tool/check_lib.sh.

# Where a release build puts the project: the folder F-Droid's build server
# builds the app in. Flutter compiles the project's path into the app, so a
# build elsewhere would differ from F-Droid's (and could name a home folder).
readonly RELEASE_PROJECT_DIR=/home/vagrant/build/io.github.thefanciestturtle.decoy_contacts

# The SHA-256 fingerprint of the release key's certificate, as apksigner
# prints it (64 lowercase hex digits), made by tool/make_release_key.sh.
readonly RELEASE_CERT_FILE=tool/release_certificate.sha256

# The release builds and the signed APKs go here (not tracked by git).
readonly DIST_DIR=dist

fail() {
  echo "error: $*" >&2
  exit 1
}

# Path $1 as an absolute path, a relative one taken from folder $2: the
# scripts move to the repository's root, so they turn the paths they are
# given into absolute ones first, from the folder they were run in.
absolute_path() {
  if [[ "$1" == /* ]]; then
    echo "$1"
  else
    echo "$2/$1"
  fi
}

# Runs tool/apk_check.py.
apk_check() {
  python3 -I tool/apk_check.py "$@"
}

# Stops the script (fail) if APK $1 names a home folder other than the
# build sandbox's, this computer's (wherever it is) included. (Not the
# computer's name: the sandbox has its own, and short or common names, such
# as localhost, are in every APK.)
check_home_paths() {
  local status=0
  apk_check home-paths "$1" "$(cd ~ && pwd -P)/" || status=$?
  case "$status" in
    0) ;;
    1) fail "$1 names a home folder" ;;
    *) fail "couldn't read $1 as an APK" ;;
  esac
}

# Puts release build $1 into dist as $2 (…-unsigned.apk). If $2 is already
# there, the build must be the same file (it is then kept); if the signed
# APK (….apk) is there, it must be this build signed. Otherwise it stops, so
# a signed APK can't end up next to a different build.
place_release() {
  local apk=$1 out=$2 signed="${2%-unsigned.apk}.apk"
  if [[ -e "$signed" ]] && ! apk_check only-signature-added "$signed" "$apk"; then
    fail "$signed, already there, isn't this build signed;" \
         "move it and $out away first"
  fi
  if [[ -e "$out" ]]; then
    apk_check same "$out" "$apk" ||
      fail "this build isn't the same file as the $out already there;" \
           "move that away first"
    echo "== The same file as the $out already there"
  else
    mkdir -p "$(dirname "$out")"
    cp "$apk" "$out.partial"
    mv "$out.partial" "$out"
    echo "== Built $out"
  fi
}

# Whether APK $1 is signed; stops the script (fail) if it can't be read.
is_signed() {
  local found
  found="$(apk_check signature "$1")" || fail "couldn't read $1 as an APK"
  [[ -n "$found" ]]
}

# The Java version (java.specification.version: 25, 21, 17, 1.8, ...) of
# the java command $1.
java_version() {
  "$1" -XshowSettings:properties -version 2>&1 |
    sed -n 's/^[[:space:]]*java\.specification\.version = //p'
}

# The Android SDK: ANDROID_HOME, else ANDROID_SDK_ROOT. Fails if neither is
# a folder.
android_sdk() {
  local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [[ -z "$sdk" || ! -d "$sdk" ]]; then
    echo "error: set ANDROID_HOME to the Android SDK" >&2
    return 1
  fi
  echo "$sdk"
}

# apksigner from the newest build-tools release in the Android SDK (not a
# preview such as 36.0.0-rc1), 35 or newer: since 35 apksigner moves files
# within the APK as it signs, unless told --alignment-preserved, which older
# ones don't know. (F-Droid can't copy a signature made that way onto its
# own build: fdroiddata issue 3299.)
apksigner_path() {
  local sdk dir newest=""
  sdk="$(android_sdk)" || return 1
  for dir in "$sdk"/build-tools/*/; do
    [[ -x "${dir}apksigner" ]] || continue
    dir="$(basename "$dir")"
    [[ "$dir" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    if [[ -z "$newest" ]] || version_older "$newest" "$dir"; then
      newest="$dir"
    fi
  done
  if [[ -z "$newest" ]] || version_older "$newest" 35; then
    echo "error: this needs apksigner from Android build-tools 35 or newer" \
         "in $sdk/build-tools (has: ${newest:-none})" >&2
    return 1
  fi
  echo "$sdk/build-tools/$newest/apksigner"
}

# Runs apksigner with "$@", with the JDK in JAVA_HOME if that is set (the
# apksigner script runs the `java` on the PATH). On Java 17 and newer it
# allows apksigner native access, which keeps newer JDKs from warning that
# it loads a native library (its -J options are passed to java with one
# more "-"); older ones don't know that option.
apksigner_() {
  local apksigner java_options=()
  apksigner="$(apksigner_path)" || return 1
  local -x PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"
  if ! version_older "$(java_version java)" 17; then
    java_options=(-J-enable-native-access=ALL-UNNAMED)
  fi
  "$apksigner" "${java_options[@]}" "$@"
}

# How release APKs are signed: APK Signature Scheme v2 and v3 only (Android
# 7 and newer read v2; v3 would let a later release move to a new key; v1
# only matters before Android 7), keeping the files where they are.
readonly SIGNING_OPTIONS=(
  --alignment-preserved
  --v1-signing-enabled false --v2-signing-enabled true
  --v3-signing-enabled true --v4-signing-enabled false
)

# The debug key. Android Studio and Gradle make it with the first debug
# build, in the folder Android's tools keep their settings in:
# ANDROID_USER_HOME, else .android in ANDROID_PREFS_ROOT, ANDROID_SDK_HOME
# (both deprecated) or the home folder. Fails, saying so, if it isn't there.
debug_keystore() {
  local folder
  if [[ -n "${ANDROID_USER_HOME:-}" ]]; then
    folder="$ANDROID_USER_HOME"
  else
    folder="${ANDROID_PREFS_ROOT:-${ANDROID_SDK_HOME:-$HOME}}/.android"
  fi
  if [[ ! -f "$folder/debug.keystore" ]]; then
    echo "error: no debug key at $folder/debug.keystore; a debug build" \
         "makes one (flutter build apk --debug)" >&2
    return 1
  fi
  echo "$folder/debug.keystore"
}

# Signs release APK $1 with the debug key into $2, as release APKs are
# signed, so it can be installed for testing.
debug_sign() {
  local keystore
  keystore="$(debug_keystore)" || return 1
  apksigner_ sign --ks "$keystore" --ks-pass pass:android \
    --ks-key-alias androiddebugkey --key-pass pass:android \
    "${SIGNING_OPTIONS[@]}" --out "$2" "$1"
}

# The pinned release certificate's fingerprint; fails if there is none.
release_cert_sha256() {
  local sum
  sum="$(tr -d '[:space:]' 2>/dev/null <"$RELEASE_CERT_FILE")" || sum=""
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: no release certificate fingerprint in $RELEASE_CERT_FILE" \
         "(tool/make_release_key.sh writes it)" >&2
    return 1
  fi
  echo "$sum"
}
