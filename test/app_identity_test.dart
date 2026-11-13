// The app's name and ID are spelled out in several files outside lib/;
// these tests keep them in step.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:decoy_contacts/about_page.dart'
    show kLicensePackage, kSourceUrl;
import 'package:decoy_contacts/app_info.dart';

/// The app's ID (applicationId). Once released it can't change: Android
/// keys the app's storage, and with it the record of the contacts it
/// created, by this ID.
const String kAppId = 'io.github.thefanciestturtle.decoy_contacts';

/// The one value of `key = "..."` in [text].
String gradleValue(String text, String key) {
  final matches =
      RegExp('^\\s*$key\\s*=\\s*"([^"]*)"', multiLine: true).allMatches(text);
  expect(matches, hasLength(1), reason: 'one $key in build.gradle.kts');
  return matches.single.group(1)!;
}

void main() {
  test('the app ID is the same in Gradle, the Kotlin code and the scripts',
      () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradleValue(gradle, 'applicationId'), kAppId);
    // The same as the ID, so `<ID>/.MainActivity` names the activity (the
    // release smoke test starts it that way).
    expect(gradleValue(gradle, 'namespace'), kAppId);

    final activity = File('android/app/src/main/kotlin/'
        '${kAppId.replaceAll('.', '/')}/MainActivity.kt');
    expect(activity.existsSync(), isTrue, reason: '${activity.path} exists');
    expect(activity.readAsLinesSync().first, 'package $kAppId');

    expect(File('tool/emulator_lib.sh').readAsLinesSync(),
        contains('readonly APP_ID=$kAppId'));
    // Release builds are made in the folder F-Droid builds the app in,
    // named after the ID.
    expect(File('tool/release_lib.sh').readAsLinesSync(),
        contains('readonly RELEASE_PROJECT_DIR=/home/vagrant/build/$kAppId'));
  });

  test('the package, the repository and the ID end in the same name', () {
    final name = RegExp(r'^name:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync())
        ?.group(1);
    expect(name, 'decoy_contacts');
    expect(kAppId.split('.').last, name);
    expect(kSourceUrl.pathSegments.last, name);
    expect(kLicensePackage, name);
  });

  test("the app's name is the same on the launcher, in the stores and the "
      'README', () {
    expect(kAppName, 'Decoy Contacts');

    final label = RegExp(r'android:label="([^"]*)"')
        .allMatches(File('android/app/src/main/AndroidManifest.xml')
            .readAsStringSync())
        .map((m) => m.group(1))
        .toList();
    expect(label, [kAppName]);

    final titles = Directory('fastlane/metadata/android')
        .listSync()
        .whereType<Directory>()
        .map((locale) => File('${locale.path}/title.txt'))
        .toList();
    expect(titles, isNotEmpty);
    for (final title in titles) {
      expect(title.readAsStringSync().trim(), kAppName, reason: title.path);
    }

    expect(File('README.md').readAsLinesSync().first, '# $kAppName');
  });
}
