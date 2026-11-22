// The release notes: CHANGELOG.md's entry for the version in pubspec.yaml
// and the short text app stores show (F-Droid and IzzyOnDroid read
// fastlane/.../changelogs/<versionCode>.txt of the tagged commit). These
// tests keep them in step with the version, so a version bump can't forget
// them.

import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';

/// The ABI's number in a release APK's version code: ten times the build
/// number, plus this (tests below check tool/release_lib.sh's table and
/// android/app/build.gradle.kts's).
const abiNumbers = {'armeabi-v7a': 1, 'arm64-v8a': 2, 'x86_64': 3};

/// Versions 2.0.0 and 2.0.1 had Flutter's own `--split-per-abi` codes, the
/// ABI's number below times 1000, plus the build number (5 and 6), and
/// their changelog files are named so. The highest was 4006.
const flutterAbiNumbers = {'armeabi-v7a': 1, 'arm64-v8a': 2, 'x86_64': 4};
const highestFlutterCode = 4006;

/// The highest build number tool/release_lib.sh accepts.
const maxBuild = 999999;

/// What the app stores allow: plain ASCII, at most this many bytes.
const maxChangelogBytes = 500;

final changelogDir = Directory('fastlane/metadata/android/en-US/changelogs');

/// The version name and build number in pubspec.yaml.
({String name, int build}) pubspecVersion() {
  final match = RegExp(
    r'^version:\s*([0-9.]+)\+(\d+)\s*$',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml has "version: NAME+BUILD"');
  return (name: match!.group(1)!, build: int.parse(match.group(2)!));
}

/// The version codes of the release APKs of the pubspec's version.
Map<String, int> versionCodes() {
  final build = pubspecVersion().build;
  return {for (final e in abiNumbers.entries) e.key: build * 10 + e.value};
}

/// The lowest build number tool/release_lib.sh accepts (RELEASE_MIN_BUILD).
int minBuild() {
  final match = RegExp(
    r'^readonly RELEASE_MIN_BUILD=(\d+)\s*$',
    multiLine: true,
  ).firstMatch(File('tool/release_lib.sh').readAsStringSync());
  expect(match, isNotNull, reason: 'release_lib.sh has RELEASE_MIN_BUILD');
  return int.parse(match!.group(1)!);
}

void main() {
  test("the ABI numbers are the ones the release scripts use", () {
    final line = RegExp(
      r'^declare -rA ABI_CODE=\((.*)\)\s*$',
      multiLine: true,
    ).firstMatch(File('tool/release_lib.sh').readAsStringSync());
    expect(line, isNotNull, reason: 'release_lib.sh has ABI_CODE');
    final scripts = {
      for (final m in RegExp(r'\[([\w-]+)\]=(\d+)').allMatches(line!.group(1)!))
        m.group(1)!: int.parse(m.group(2)!),
    };
    expect(scripts, abiNumbers);
  });

  test('... and the ones android/app/build.gradle.kts gives the APKs', () {
    final line = RegExp(
      r'^val abiDigits = mapOf\((.*)\)\s*$',
      multiLine: true,
    ).firstMatch(File('android/app/build.gradle.kts').readAsStringSync());
    expect(line, isNotNull, reason: 'build.gradle.kts has abiDigits');
    final gradle = {
      for (final m in RegExp(
        r'"([\w-]+)" to (\d+)',
      ).allMatches(line!.group(1)!))
        m.group(1)!: int.parse(m.group(2)!),
    };
    expect(gradle, abiNumbers);
  });

  test('the build number puts every version code above the older ones', () {
    // Android installs an update only over a lower versionCode, and the
    // first two releases had Flutter's numbering, up to 4006.
    final lowest = minBuild() * 10 + abiNumbers.values.reduce(min);
    expect(lowest, greaterThan(highestFlutterCode));
    expect(pubspecVersion().build, greaterThanOrEqualTo(minBuild()));
    expect(pubspecVersion().build, lessThanOrEqualTo(maxBuild));
  });

  group('the changelog files for the app stores', () {
    test('there is one for every ABI, named after its version code', () {
      for (final entry in versionCodes().entries) {
        final file = File('${changelogDir.path}/${entry.value}.txt');
        expect(
          file.existsSync(),
          isTrue,
          reason: '${file.path} (${entry.key}) exists',
        );
      }
    });

    test(
      'nothing else is in the folder but files named after a version code',
      () {
        // Older versions' files stay (stores show them for older builds); a
        // stray name is a typo.
        final names =
            changelogDir.listSync().map((e) => e.uri.pathSegments.last).toList()
              ..sort();
        expect(names, isNotEmpty);
        for (final name in names) {
          expect(name, matches(RegExp(r'^[1-9]\d{3,}\.txt$')));
          final code = int.parse(name.split('.').first);
          if (code <= highestFlutterCode) {
            expect(
              flutterAbiNumbers.values,
              contains(code ~/ 1000),
              reason:
                  "$name (Flutter's own numbering) starts with an ABI number",
            );
          } else {
            expect(
              abiNumbers.values,
              contains(code % 10),
              reason: '$name ends with an ABI number',
            );
          }
          expect(
            File('${changelogDir.path}/$name').statSync().type,
            FileSystemEntityType.file,
          );
        }
      },
    );

    test('they are the same text for every ABI', () {
      final texts = {
        for (final code in versionCodes().values)
          code: File('${changelogDir.path}/$code.txt').readAsStringSync(),
      };
      expect(texts.values.toSet(), hasLength(1), reason: '$texts');
    });

    test('the text is short, plain ASCII, and ends with one newline', () {
      for (final code in versionCodes().values) {
        final bytes = File('${changelogDir.path}/$code.txt').readAsBytesSync();
        expect(
          bytes.length,
          lessThanOrEqualTo(maxChangelogBytes),
          reason: '$code.txt is ${bytes.length} bytes',
        );
        // Printable ASCII and newlines only: no tabs, no carriage returns,
        // no accents, no invisible characters.
        expect(
          bytes.every((b) => b == 0x0A || (b >= 0x20 && b < 0x7F)),
          isTrue,
          reason: '$code.txt has only printable ASCII',
        );
        final text = utf8.decode(bytes);
        expect(text.trim(), isNotEmpty);
        expect(text, endsWith('\n'));
        expect(text, isNot(endsWith('\n\n')));
        expect(
          text.split('\n').any((l) => l != l.trimRight()),
          isFalse,
          reason: 'no trailing spaces',
        );
      }
    });

    test('the text starts by saying which version it is for', () {
      for (final code in versionCodes().values) {
        expect(
          File('${changelogDir.path}/$code.txt').readAsStringSync(),
          startsWith('Version ${pubspecVersion().name}: '),
        );
      }
    });
  });

  group('CHANGELOG.md', () {
    final changelog = File('CHANGELOG.md').readAsStringSync();
    // The version of every heading that names one, at any level (the
    // original app's are a level down), in the order they come.
    final versions = RegExp(r'^#+ ([0-9][0-9.]*)\s*$', multiLine: true)
        .allMatches(changelog)
        .map((m) => m.group(1)!)
        .toList();

    test("starts with pubspec.yaml's version, as an entry of its own", () {
      final version = pubspecVersion().name;
      expect(versions, isNotEmpty);
      expect(versions.first, version, reason: 'the newest entry first');
      final heading = RegExp(
        '^## ${RegExp.escape(version)}\\s*\$',
        multiLine: true,
      ).firstMatch(changelog);
      expect(heading, isNotNull, reason: 'a "## $version" heading');
      // With its notes, up to the next entry (its own subheadings, such as
      // "### Fixed", are part of it).
      final rest = changelog.substring(heading!.end);
      final next = RegExp(r'^#{1,2} ', multiLine: true).firstMatch(rest);
      final notes = next == null ? rest : rest.substring(0, next.start);
      final text = notes.split('\n').where((line) => !line.startsWith('#'));
      expect(text.join().trim(), isNotEmpty, reason: 'notes for $version');
    });

    test('lists the versions newest first, each once', () {
      expect(versions, hasLength(greaterThan(1)));
      for (final version in versions) {
        expect(version, matches(RegExp(r'^[0-9]+(\.[0-9]+)*$')));
      }
      final numbers = [
        for (final version in versions)
          version.split('.').map(int.parse).toList(),
      ];
      for (var i = 1; i < numbers.length; i++) {
        expect(
          _compare(numbers[i - 1], numbers[i]),
          greaterThan(0),
          reason: '${versions[i - 1]} before ${versions[i]}',
        );
      }
    });
  });
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}
