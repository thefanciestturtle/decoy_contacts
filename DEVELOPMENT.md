# Development

Decoy Contacts is a Flutter app for Android.  (See the [README](README.md) for what it does.)

## Building

It needs:
* Flutter, at the version CI builds with: `FLUTTER_VERSION` in `.github/workflows/dart.yml`.
* A JDK, of the major version CI uses: `JAVA_VERSION` there.
* The Android SDK.  `flutter doctor` says what is missing.

`flutter run` then builds the app and starts it on a phone or an emulator.

## Tests
* `flutter test` runs the unit and widget tests.
* `tool/integration_test.sh --wipe-contacts` runs the on-device tests in `integration_test/`, which create and delete contacts through the app. The script only runs on an Android emulator, and `--wipe-contacts` empties the emulator's address book first.
* `tool/release_smoke_test.sh` builds a release APK, signs a copy with the debug key, installs it on an emulator, starts it, and checks it doesn't crash and can read and write its settings. Release builds go through R8, which the other tests don't, and which can break plugins. It doesn't exercise contacts (the app only touches them when a button is tapped). It needs an emulator image without Play Store (for `adb root`).
* `tool/check_build_tools.sh` checks that Gradle, the Android Gradle plugin, Kotlin and `gradle.properties` match the project template of the Flutter in use, and that the Gradle download's checksum is Gradle's. Run it after a Flutter upgrade: it says what to change. `tool/test/` has tests for it and for `tool/check_flutter_release.sh`.
* CI runs all of these; the on-device tests and the smoke test run on both Android 16 (API 36) and Android 17 (API 37.0) (whose memory limits for apps the emulator doesn't set). A weekly workflow also opens an issue when a newer stable Flutter is out (`tool/check_flutter_release.sh`), and closes it once the app has moved to it.

## The icon
The launcher icon is an adaptive icon (`android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`): the colour `ic_launcher_background` (in `values/`) behind the duck, `drawable/ic_launcher_foreground.xml`, and a one-colour version for themed icons, `drawable/ic_launcher_monochrome.xml`. Android 7 has no adaptive icons and uses the PNGs in `mipmap-*dpi/`, and app stores show `fastlane/metadata/android/en-US/images/icon.png`. `tool/make_icon_pngs.py` (Python with Pillow) draws those PNGs from the background and the foreground: run it after changing either. `--check` says whether they are up to date, and `test/app_icon_test.dart` checks that too, with Flutter's own drawing of the layers, and that the layers stay inside the 66 dp circle that no launcher cuts off. `tool/test/make_icon_pngs_test.sh` tests the tool (it needs Pillow too, so CI doesn't run it).

## Release builds
* `tool/build_release.sh [TAG]` builds the release APKs of a commit, unsigned, into `dist/`: one per ABI (`armeabi-v7a`, `arm64-v8a`, `x86_64`; `--abi ABI` builds only that one, and can be given again for more). Each is built on its own with `flutter build apk --split-per-abi`, as F-Droid builds them, and has Flutter's versionCode for its ABI: 1000, 2000 or 4000 plus the build number (the number after the "+" in `pubspec.yaml`'s version). It builds in a sandbox (bubblewrap) where the project, its packages, Flutter and the Android SDK are at the paths F-Droid's build server uses, so that F-Droid's builds of the same commit are the same files. (Flutter compiles these paths into the app, so a build in your own folder would also name your home folder.) It checks each APK: its ABI and version, that it is unsigned, that it names no home folder, that it asks for no permission but access to contacts, as the store listing says, and that its minimum Android version is `RELEASE_MIN_SDK` (in `tool/release_lib.sh`), the one the README names. It keeps a copy of the Flutter that CI uses, and Gradle's downloads, in `~/.cache/decoy_contacts`.
* `tool/sign_release.sh KEYSTORE dist/decoy_contacts-<version>-*-unsigned.apk` signs them with the release key (it asks for the password once) and checks each signed APK: the key's fingerprint, and that only the signature was added.
* `tool/make_release_key.sh` made the release key, once.
* Release builds are unsigned, so `flutter run --release` can't install them. `tool/debug_sign.sh APK [OUT]` makes a copy signed with the debug key, for `adb install`: say `tool/debug_sign.sh dist/decoy_contacts-<version>-x86_64-unsigned.apk build/x86_64-debug-signed.apk` (never into `dist/`), or of `build/app/outputs/flutter-apk/app-x86_64-release.apk` after `flutter build apk --release --split-per-abi --target-platform android-x64`.  A release APK's versionCode (1000 to 4000 more than the build number) is higher than a debug build's, so uninstall it before going back to a debug build: Android won't install a lower versionCode over it, and `flutter run` then uninstalls it itself, with the app's data.
* CI builds the release APKs twice and checks that each is the same file both times. `tool/test/release_test.sh` tests the release scripts with throwaway keys.
* Each version's notes go into [CHANGELOG.md](CHANGELOG.md), and a short text (at most 500 bytes of plain ASCII) into `fastlane/metadata/android/en-US/changelogs/`, one file named after each ABI's versionCode, for app stores. `test/release_notes_test.dart` checks both against the version in `pubspec.yaml`.
