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

# Runs tool/apk_check.py.
apk_check() {
  python3 -I tool/apk_check.py "$@"
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

# apksigner from the newest build-tools in the Android SDK, 35 or newer:
# since 35 apksigner moves files within the APK as it signs, unless told
# --alignment-preserved, which older ones don't know. (F-Droid can't copy a
# signature made that way onto its own build: fdroiddata issue 3299.)
apksigner_path() {
  local sdk dir newest=""
  sdk="$(android_sdk)" || return 1
  for dir in "$sdk"/build-tools/*/; do
    [[ -x "${dir}apksigner" ]] || continue
    dir="$(basename "$dir")"
    if [[ -z "$newest" ||
          "$(printf '%s\n%s\n' "$newest" "$dir" | sort -V | tail -n 1)" == "$dir" ]]; then
      newest="$dir"
    fi
  done
  if [[ -z "$newest" ]] || version_older "${newest%%-*}" 35; then
    echo "error: this needs apksigner from Android build-tools 35 or newer" \
         "in $sdk/build-tools (has: ${newest:-none})" >&2
    return 1
  fi
  echo "$sdk/build-tools/$newest/apksigner"
}

# Runs apksigner with "$@", with the JDK in JAVA_HOME if that is set (the
# apksigner script runs the `java` on the PATH). Allowing native access
# keeps newer JDKs from warning that apksigner loads a native library (its
# -J options are passed to java with one more "-").
apksigner_() {
  local apksigner
  apksigner="$(apksigner_path)" || return 1
  PATH="${JAVA_HOME:+$JAVA_HOME/bin:}$PATH" \
    "$apksigner" -J-enable-native-access=ALL-UNNAMED "$@"
}

# Signs release APK $1 with the debug key into $2, so it can be installed
# for testing. Android Studio and Gradle make the debug key with the first
# debug build.
debug_sign() {
  local keystore="${ANDROID_USER_HOME:-$HOME/.android}/debug.keystore"
  if [[ ! -f "$keystore" ]]; then
    echo "error: no debug key at $keystore; a debug build makes one" \
         "(flutter build apk --debug)" >&2
    return 1
  fi
  apksigner_ sign --ks "$keystore" --ks-pass pass:android \
    --ks-key-alias androiddebugkey --key-pass pass:android \
    --alignment-preserved --out "$2" "$1"
}

# The pinned release certificate's fingerprint; fails if there is none.
release_cert_sha256() {
  local sum
  sum="$(tr -d '[:space:]' <"$RELEASE_CERT_FILE" 2>/dev/null)" || sum=""
  if [[ ! "$sum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "error: no release certificate fingerprint in $RELEASE_CERT_FILE" \
         "(tool/make_release_key.sh writes it)" >&2
    return 1
  fi
  echo "$sum"
}
