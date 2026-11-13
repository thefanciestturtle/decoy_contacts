// Release builds are left unsigned by Gradle and signed by hand with the
// release key (tool/sign_release.sh); these tests keep the build files and
// the README in step with that.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The pinned SHA-256 fingerprint of the release key's certificate.
String releaseCertificate() =>
    File('tool/release_certificate.sha256').readAsStringSync().trim();

void main() {
  final gradle = File('android/app/build.gradle.kts').readAsStringSync();
  // Without the comment lines, which explain the signing.
  final code = gradle
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  test('Gradle signs no release build, not even with the debug key', () {
    expect(code, isNot(contains('signingConfig')));
  });

  test("Gradle leaves out Google's dependency metadata", () {
    final block = RegExp(r'dependenciesInfo\s*\{([^}]*)\}').firstMatch(code);
    expect(block, isNotNull, reason: 'a dependenciesInfo block');
    final settings = block!.group(1)!;
    expect(settings, matches(RegExp(r'includeInApk\s*=\s*false')));
    expect(settings, matches(RegExp(r'includeInBundle\s*=\s*false')));
  });

  test('a release key is pinned', () {
    expect(releaseCertificate(), matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test("the README shows the release key's fingerprint", () {
    expect(File('README.md').readAsStringSync(),
        contains('`${releaseCertificate()}`'));
  });
}
