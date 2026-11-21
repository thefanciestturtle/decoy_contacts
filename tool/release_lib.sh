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

# The ABIs (processor types) a release has an APK for, one each, built with
# `flutter build apk --split-per-abi`: 32-bit ARM phones, 64-bit ARM phones,
# and x86_64 (Chromebooks, emulators). Each one's APK has the versionCode 10
# * the build number (the number after the + in pubspec.yaml's version) +
# ABI_CODE. The ABI is the last digit, as F-Droid's documentation asks, so
# that F-Droid, which keeps the APKs with the highest codes, keeps the newest
# of every ABI; and app stores offer a 64-bit phone the arm64-v8a APK, the
# highest code it can run. android/app/build.gradle.kts sets the codes
# (Flutter's own, ABI * 1000 + the build number, are replaced there) and has
# the same digits; tool/build_release.sh checks every APK's.
readonly RELEASE_ABIS=(armeabi-v7a arm64-v8a x86_64)
declare -rA ABI_CODE=([armeabi-v7a]=1 [arm64-v8a]=2 [x86_64]=3)
# The name Flutter's --target-platform knows each one by.
declare -rA ABI_PLATFORM=(
  [armeabi-v7a]=android-arm [arm64-v8a]=android-arm64 [x86_64]=android-x64
)

# The lowest build number a release can have. Versions 2.0.0 and 2.0.1 had
# Flutter's own versionCodes, ABI * 1000 + the build number, up to 4006
# (x86_64, build number 6). Android installs an update only over a lower
# versionCode, so every code of a release must be above those: with 401 the
# codes are 4011, 4012 and 4013. (test/release_notes_test.dart checks this.)
# It is only a floor: each release must also have a higher build number than
# the one before it (DEVELOPMENT.md), which nothing here can check.
readonly RELEASE_MIN_BUILD=401

# Stops the script (fail) if APK $1 has native code, but none for ABI $2
# (so it would test another ABI's build, or not install at all).
check_apk_abi() {
  local found
  found="$(apk_check abis "$1")" || fail "couldn't read $1 as an APK"
  if [[ -n "$found" ]] && ! grep -qxF -- "$2" <<<"$found"; then
    fail "$1 has native code for $(paste -sd ' ' <<<"$found"), not for" \
         "${2:-an unknown ABI}"
  fi
}

# Whether $1 is one of RELEASE_ABIS.
is_release_abi() {
  local abi
  for abi in "${RELEASE_ABIS[@]}"; do
    [[ "$abi" == "$1" ]] && return 0
  done
  return 1
}

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

# The name of the signed APK that signing unsigned APK $1 makes, next to
# it: dist/decoy_contacts-2.0.0-x86_64-unsigned.apk gives
# dist/decoy_contacts-2.0.0-x86_64.apk.
signed_name() {
  echo "${1%-unsigned.apk}.apk"
}

# Stops the script (fail) unless release build $1 can go into dist as $2
# (…-unsigned.apk): if $2 is already there, the build must be the same
# file; if the signed APK (see signed_name) is there, it must be this build
# signed. So a signed APK can't end up next to a different build.
check_placement() {
  local apk=$1 out=$2 signed
  signed="$(signed_name "$2")"
  if [[ -e "$signed" ]] && ! apk_check only-signature-added "$signed" "$apk"; then
    fail "$signed, already there, isn't this build signed;" \
         "move it and $out away first"
  fi
  if [[ -e "$out" ]] && ! apk_check same "$out" "$apk"; then
    fail "this build isn't the same file as the $out already there;" \
         "move that away first"
  fi
}

# Puts release builds into dist, all of them or none: $1 as $2, $3 as $4,
# and so on. Each must pass check_placement, or none goes there; one that
# is already there (the same file) is kept. The others are copied in as
# ….partial files first, and renamed only once all are copied, so a
# failure partway (say with the disk full) leaves none of them either.
place_releases() {
  local args=("$@") i apk out staged=() new=()
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    check_placement "${args[i]}" "${args[i + 1]}"
  done
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    apk=${args[i]} out=${args[i + 1]}
    [[ ! -e "$out" ]] || continue
    if ! mkdir -p "$(dirname "$out")" || ! cp "$apk" "$out.partial"; then
      rm -f "$out.partial" "${staged[@]}"
      fail "couldn't copy the build to $out.partial; none was put there"
    fi
    staged+=("$out.partial")
    new[i]=1
  done
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    out=${args[i + 1]}
    if [[ -n "${new[i]:-}" ]]; then
      mv "$out.partial" "$out"
      echo "== Built $out"
    else
      echo "== The same file as the $out already there"
    fi
  done
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

# The newest build-tools release in the Android SDK $1 (not a preview such
# as 36.0.0-rc1) that has the tool $2, e.g. 36.1.0; nothing if none has it.
newest_build_tools() {
  local dir newest=""
  for dir in "$1"/build-tools/*/; do
    [[ -x "$dir$2" ]] || continue
    dir="$(basename "$dir")"
    [[ "$dir" =~ ^[0-9]+(\.[0-9]+)*$ ]] || continue
    if [[ -z "$newest" ]] || version_older "$newest" "$dir"; then
      newest="$dir"
    fi
  done
  echo "$newest"
}

# apksigner from the newest build-tools release in the Android SDK, 35 or
# newer: since 35 apksigner moves files within the APK as it signs, unless
# told --alignment-preserved, which older ones don't know. (F-Droid can't
# copy a signature made that way onto its own build: fdroiddata issue 3299.)
apksigner_path() {
  local sdk newest
  sdk="$(android_sdk)" || return 1
  newest="$(newest_build_tools "$sdk" apksigner)"
  if [[ -z "$newest" ]] || version_older "$newest" 35; then
    echo "error: this needs apksigner from Android build-tools 35 or newer" \
         "in $sdk/build-tools (has: ${newest:-none})" >&2
    return 1
  fi
  echo "$sdk/build-tools/$newest/apksigner"
}

# aapt2 from the newest build-tools release in the Android SDK.
aapt2_path() {
  local sdk newest
  sdk="$(android_sdk)" || return 1
  newest="$(newest_build_tools "$sdk" aapt2)"
  if [[ -z "$newest" ]]; then
    echo "error: this needs aapt2 from Android build-tools in" \
         "$sdk/build-tools" >&2
    return 1
  fi
  echo "$sdk/build-tools/$newest/aapt2"
}

# What `aapt2 dump $1` says about APK $2 (badging, permissions, ...); fails,
# with aapt2's error, if it can't read it.
aapt2_dump() {
  local aapt2 dump
  aapt2="$(aapt2_path)" || return 1
  if ! dump="$("$aapt2" dump "$1" "$2" 2>&1)"; then
    echo "$dump" >&2
    return 1
  fi
  echo "$dump"
}

# The versionCode and versionName of APK $1, as "CODE NAME"; fails, with
# aapt2's error, if it can't read them.
apk_version() {
  local badging found
  badging="$(aapt2_dump badging "$1")" || return 1
  found="$(sed -n \
    "s/^package: .* versionCode='\([0-9]\{1,\}\)' versionName='\([^']*\)'.*/\1 \2/p" \
    <<<"$badging")"
  [[ -n "$found" ]] || return 1
  echo "$found"
}

# The minSdkVersion of APK $1 (the oldest Android it installs on, as an API
# level); fails, with aapt2's error, if it can't read it. (aapt2 from
# build-tools 36 on says "minSdkVersion:'24'"; older ones may say
# "sdkVersion:'24'", as aapt did.)
apk_min_sdk() {
  local badging found
  badging="$(aapt2_dump badging "$1")" || return 1
  found="$(sed -nE "s/^(minS|s)dkVersion:'([0-9]+)'$/\2/p" <<<"$badging" |
    head -n 1)"
  [[ -n "$found" ]] || return 1
  echo "$found"
}

# The permissions APK $1 asks for (uses-permission, uses-permission-sdk-23),
# one per line, after its package name on the first line; fails, with
# aapt2's error, if it can't read them.
apk_permissions() {
  local dump package
  dump="$(aapt2_dump permissions "$1")" || return 1
  package="$(sed -n "s/^package: \(.*\)$/\1/p" <<<"$dump")"
  [[ -n "$package" ]] || return 1
  echo "$package"
  sed -n "s/^uses-permission[-a-z0-9]*: name='\([^']*\)'.*/\1/p" <<<"$dump"
}

# The only permissions a release may ask for: access to contacts, as the
# store listing says ("The only permission it asks you for is access to
# your contacts"), and no internet access, as the privacy policy says. Plugins
# can add permissions to the build. (The app's own
# <package>.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION, which androidx.core
# declares so that only the app itself can send it some broadcasts, is
# never asked of anyone, and is allowed too.)
readonly RELEASE_PERMISSIONS=(
  android.permission.READ_CONTACTS
  android.permission.WRITE_CONTACTS
)

# The oldest Android that can install a release APK at all, as an API
# level: 7.0, the first with v2 signatures. Release APKs have no v1
# signature (SIGNING_OPTIONS), which older Android needs.
readonly OLDEST_SIGNABLE_SDK=24

# The oldest Android a release installs on, as an API level: 24 is Android
# 7.0, and the README says the app "needs Android 7.0 or newer"
# (test/readme_test.dart keeps the two in step). It is Flutter's own
# minimum (minSdk = flutter.minSdkVersion in android/app/build.gradle.kts),
# so a Flutter upgrade can change it: the release build then fails, until
# this and the README are changed with it. It can't be below
# OLDEST_SIGNABLE_SDK.
readonly RELEASE_MIN_SDK=24

# The versionName and build number in pubspec.yaml file $1, as "NAME
# BUILD": "version: 2.0.2+401" gives "2.0.2 401". The name is numbers and
# dots (it goes into the APKs' file names). The APKs' versionCodes are made
# from the build number (see RELEASE_ABIS), so it must be there: at least
# RELEASE_MIN_BUILD, at most 999999, written without a leading zero (as
# Flutter reads it). Quoted or not, with or without a comment after it
# (after a space, as YAML wants). Fails otherwise, or if there isn't exactly
# one version line.
pubspec_version() {
  local line value
  line="$(grep '^version:' "$1" 2>/dev/null)" || return 1
  [[ "$line" != *$'\n'* ]] || return 1
  local version='([0-9]+(\.[0-9]+)*)\+([1-9][0-9]{2,5})'
  local after='([[:space:]]+#.*)?[[:space:]]*$'
  value="${line#version:}"
  if [[ "$value" =~ ^[[:space:]]*$version$after ||
        "$value" =~ ^[[:space:]]*\"$version\"$after ||
        "$value" =~ ^[[:space:]]*\'$version\'$after ]]; then
    ((BASH_REMATCH[3] >= RELEASE_MIN_BUILD)) || return 1
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[3]}"
  else
    return 1
  fi
}

# Stops the script (fail) unless APK $1 is the release APK for ABI $2 of
# version $3 with build number $4: unsigned, with native code for that ABI
# only, with the versionCode 10 * $4 + ABI_CODE and the versionName $3,
# the minSdkVersion RELEASE_MIN_SDK (not below OLDEST_SIGNABLE_SDK), asking
# for no permission but RELEASE_PERMISSIONS, and naming no home folder but
# the build sandbox's.
check_release_apk() {
  local apk=$1 abi=$2 version=$3 build=$4 found
  local code=$((build * 10 + ABI_CODE[$abi]))
  if is_signed "$apk"; then
    fail "the $abi APK is signed: release builds must be unsigned" \
         "(android/app/build.gradle.kts)"
  fi
  found="$(apk_check abis "$apk")" || fail "couldn't read the $abi APK"
  [[ "$found" == "$abi" ]] ||
    fail "the $abi APK has native code for: $(paste -sd ' ' <<<"${found:-none}")"
  found="$(apk_version "$apk")" || fail "couldn't read the $abi APK's version"
  [[ "$found" == "$code $version" ]] ||
    fail "the $abi APK has versionCode and versionName '$found'," \
         "not '$code $version' (10 * $build + ${ABI_CODE[$abi]})"
  found="$(apk_min_sdk "$apk")" ||
    fail "couldn't read the $abi APK's minSdkVersion"
  ((found >= OLDEST_SIGNABLE_SDK)) ||
    fail "the $abi APK's minSdkVersion is $found, but release APKs have" \
         "no v1 signature (SIGNING_OPTIONS), which Android before 7.0 (API" \
         "$OLDEST_SIGNABLE_SDK) needs: set minSdk to $OLDEST_SIGNABLE_SDK or more" \
         "in android/app/build.gradle.kts"
  [[ "$found" == "$RELEASE_MIN_SDK" ]] ||
    fail "the $abi APK's minSdkVersion is $found, not $RELEASE_MIN_SDK:" \
         "change RELEASE_MIN_SDK in tool/release_lib.sh, and the Android" \
         "version the README names, to match"
  check_permissions "$apk" "$abi"
  check_home_paths "$apk"
}

# Fails if APK $1 (for ABI $2) asks for a permission that isn't in
# RELEASE_PERMISSIONS (or the app's own, see there).
check_permissions() {
  local apk=$1 abi=$2 found package permission
  found="$(apk_permissions "$apk")" ||
    fail "couldn't read the $abi APK's permissions"
  package="$(head -n 1 <<<"$found")"
  while read -r permission; do
    [[ -z "$permission" ||
       "$permission" == "$package.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION" ]] &&
      continue
    is_release_permission "$permission" ||
      fail "the $abi APK asks for $permission: a release may ask only for" \
           "${RELEASE_PERMISSIONS[*]}"
  done < <(tail -n +2 <<<"$found")
}

# Whether $1 is one of RELEASE_PERMISSIONS.
is_release_permission() {
  local permission
  for permission in "${RELEASE_PERMISSIONS[@]}"; do
    [[ "$permission" == "$1" ]] && return 0
  done
  return 1
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
