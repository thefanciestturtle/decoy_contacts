#!/usr/bin/env bash
# Builds the release APK the way F-Droid's build server builds the app, so
# that F-Droid's build of the same commit is the same file. The APK is left
# unsigned: sign it with tool/sign_release.sh.
#
#   tool/build_release.sh [--flutter-sdk DIR] [--gradle-home DIR] [REF]
#
# REF is the commit or tag to build (default HEAD). Only what is committed
# is built: the script builds a fresh clone, never the working tree. The
# APK goes to dist/decoy_contacts-<version>-unsigned.apk. If that file is
# already there, the new build must be the same file (it is then kept);
# otherwise the script stops, so a signed APK beside it can't end up next
# to a different build.
#
# Flutter compiles absolute paths into the app: the project's path into
# libapp.so, and the paths of the project, its packages and the Android NDK
# into the build IDs of native libraries compiled from source. A build in
# the repository's folder would name this computer's folders, including the
# home folder, and differ from anyone else's build. So the build runs in a
# sandbox (bubblewrap) where everything is at F-Droid's build server's paths:
#
#   the project       /home/vagrant/build/io.github.thefanciestturtle.decoy_contacts
#   its packages      the project's .pub-cache folder (PUB_CACHE)
#   Flutter           /home/vagrant/build/srclib/flutter
#   the Android SDK   /opt/android-sdk
#   the home folder   /home/vagrant (empty; the user is "vagrant")
#
# Afterwards it checks that the APK is unsigned and names no other folder
# in /home.
#
# Flutter and the JDK are the versions the commit's CI builds with
# (FLUTTER_VERSION and JAVA_VERSION in .github/workflows/dart.yml): the JDK
# compiles the Java and Kotlin code, and another version can compile it
# differently. JAVA_HOME must be that JDK. Flutter is by default a copy kept
# for release builds in ~/.cache/decoy_contacts/flutter-<version>, cloned
# from Flutter's repository the first time (Flutter writes into its own
# folder when it runs from another path, so the Flutter you use otherwise is
# left alone). Gradle's downloads are kept in ~/.cache/decoy_contacts/gradle.
# CI passes its own Flutter and Gradle folders.
#
# Needs: git, bubblewrap (bwrap) with unprivileged user namespaces,
# python3, JAVA_HOME and ANDROID_HOME set, and the internet.
set -euo pipefail

readonly CALLER_DIR="$PWD"
cd "$(dirname "$0")/.."
source tool/check_lib.sh
source tool/release_lib.sh

readonly SANDBOX_FLUTTER=/home/vagrant/build/srclib/flutter
readonly SANDBOX_ANDROID_SDK=/opt/android-sdk
readonly SANDBOX_JDK=/opt/jdk

usage() {
  echo "usage: tool/build_release.sh [--flutter-sdk DIR] [--gradle-home DIR] [REF]" >&2
  exit 2
}

flutter_sdk=""
gradle_home=""
while (($#)); do
  case "$1" in
    --flutter-sdk)
      (($# >= 2)) || usage
      flutter_sdk="$(absolute_path "$2" "$CALLER_DIR")"
      shift 2 ;;
    --gradle-home)
      (($# >= 2)) || usage
      gradle_home="$(absolute_path "$2" "$CALLER_DIR")"
      shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
(($# <= 1)) || usage
ref="${1:-HEAD}"

need git bwrap python3 sha256sum
[[ -n "${JAVA_HOME:-}" && -x "$JAVA_HOME/bin/java" ]] ||
  fail "set JAVA_HOME to the JDK to build with"
sdk="$(android_sdk)" || exit 1
commit="$(git rev-parse --verify --quiet "$ref^{commit}")" ||
  fail "no commit '$ref'"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Without this computer's git settings (line ends, filters), which could
# change the files checked out.
echo "== Building $(git describe --always --tags "$commit") ($commit)"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git clone --quiet --no-checkout . "$work/src"
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -C "$work/src" checkout --quiet --detach "$commit"

# The versions that commit's CI builds with.
flutter_version="$(cd "$work/src" && ci_flutter_version)" ||
  fail "couldn't read FLUTTER_VERSION from the commit's .github/workflows/dart.yml"
java_wanted="$(cd "$work/src" && ci_java_version)" ||
  fail "couldn't read JAVA_VERSION from the commit's .github/workflows/dart.yml"
java_found="$(java_version "$JAVA_HOME/bin/java")"
[[ "$java_found" == "$java_wanted" ]] ||
  fail "JAVA_HOME is Java ${java_found:-unknown}; this commit is built with" \
       "Java $java_wanted (JAVA_VERSION in .github/workflows/dart.yml)"
version="$(sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' \
  "$work/src/pubspec.yaml")"
[[ -n "$version" ]] || fail "no version in pubspec.yaml"
out="$DIST_DIR/decoy_contacts-$version-unsigned.apk"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/decoy_contacts"
if [[ -z "$flutter_sdk" ]]; then
  flutter_sdk="$cache/flutter-$flutter_version"
  if [[ ! -d "$flutter_sdk" ]]; then
    echo "== Getting Flutter $flutter_version for release builds into $flutter_sdk"
    mkdir -p "$cache"
    rm -rf "$flutter_sdk.partial"
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git clone --quiet --depth 1 --branch "$flutter_version" \
        https://github.com/flutter/flutter.git "$flutter_sdk.partial"
    mv "$flutter_sdk.partial" "$flutter_sdk"
  fi
fi
found="$(git -C "$flutter_sdk" describe --tags --exact-match HEAD 2>/dev/null)" ||
  found=""
[[ "$found" == "$flutter_version" ]] ||
  fail "Flutter in $flutter_sdk is '${found:-not a release}', not $flutter_version"
gradle_home="${gradle_home:-$cache/gradle}"
mkdir -p "$gradle_home"

# The sandbox's user and machine, so nothing reads this computer's.
printf 'root:x:0:0:root:/root:/bin/sh\nvagrant:x:%s:%s:vagrant:/home/vagrant:/bin/bash\n' \
  "$(id -u)" "$(id -g)" >"$work/passwd"
printf 'root:x:0:\nvagrant:x:%s:\n' "$(id -g)" >"$work/group"
echo buildserver >"$work/hostname"

# In the sandbox. No Gradle daemon, and the Kotlin compiler in Gradle's
# process: a daemon could outlive the sandbox or be one from outside it.
inner='set -euo pipefail
flutter config --no-analytics >/dev/null
flutter --version
java -version 2>&1 | head -n 1
flutter pub get --enforce-lockfile
flutter build apk --release'

env -i \
  HOME=/home/vagrant USER=vagrant LOGNAME=vagrant LANG=C.UTF-8 TERM=dumb \
  PATH="$SANDBOX_FLUTTER/bin:$SANDBOX_JDK/bin:/usr/local/bin:/usr/bin:/bin" \
  JAVA_HOME="$SANDBOX_JDK" \
  ANDROID_HOME="$SANDBOX_ANDROID_SDK" ANDROID_SDK_ROOT="$SANDBOX_ANDROID_SDK" \
  PUB_CACHE="$RELEASE_PROJECT_DIR/.pub-cache" \
  GRADLE_OPTS=-Dorg.gradle.daemon=false \
  ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy=in-process \
  bwrap \
    --dev-bind / / \
    --tmpfs /home --tmpfs /opt --tmpfs /tmp \
    --ro-bind "$work/passwd" /etc/passwd \
    --ro-bind "$work/group" /etc/group \
    --ro-bind "$work/hostname" /etc/hostname \
    --unshare-uts --hostname buildserver \
    --unshare-pid --die-with-parent \
    --bind "$work/src" "$RELEASE_PROJECT_DIR" \
    --bind "$flutter_sdk" "$SANDBOX_FLUTTER" \
    --bind "$sdk" "$SANDBOX_ANDROID_SDK" \
    --ro-bind "$JAVA_HOME" "$SANDBOX_JDK" \
    --bind "$gradle_home" /home/vagrant/.gradle \
    --chdir "$RELEASE_PROJECT_DIR" \
    bash -c "$inner" ||
  fail "the build failed"

apk="$work/src/build/app/outputs/flutter-apk/app-release.apk"
[[ -f "$apk" ]] || fail "the build made no APK at ${apk#"$work/src/"}"
if is_signed "$apk"; then
  fail "the APK is signed: release builds must be unsigned" \
       "(android/app/build.gradle.kts)"
fi
apk_check home-paths "$apk" || fail "the APK names a home folder"

mkdir -p "$DIST_DIR"
if [[ -e "$out" ]]; then
  apk_check same "$out" "$apk" ||
    fail "this build isn't the same file as the $out already there;" \
         "move that away first"
  echo "== The same file as the $out already there"
else
  cp "$apk" "$out"
  echo "== Built $out"
fi
sha256sum "$out"
