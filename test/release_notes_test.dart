// The release notes: the README's entry for the version in pubspec.yaml and
// the short text app stores show (F-Droid and IzzyOnDroid read
// fastlane/.../changelogs/<versionCode>.txt of the tagged commit). These
// tests keep them in step with the version, so a version bump can't forget
// them.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Flutter's `--split-per-abi` version codes: the ABI's number times 1000,
/// plus the build number (tool/release_lib.sh has the same table).
const abiNumbers = {'armeabi-v7a': 1, 'arm64-v8a': 2, 'x86_64': 4};

/// What the app stores allow: plain ASCII, at most this many bytes.
const maxChangelogBytes = 500;

final changelogDir = Directory('fastlane/metadata/android/en-US/changelogs');

/// The version name and build number in pubspec.yaml.
({String name, int build}) pubspecVersion() {
  final match = RegExp(r'^version:\s*([0-9.]+)\+(\d+)\s*$', multiLine: true)
      .firstMatch(File('pubspec.yaml').readAsStringSync());
  expect(match, isNotNull, reason: 'pubspec.yaml has "version: NAME+BUILD"');
  return (name: match!.group(1)!, build: int.parse(match.group(2)!));
}

/// The version codes of the release APKs of the pubspec's version.
Map<String, int> versionCodes() {
  final build = pubspecVersion().build;
  return {
    for (final e in abiNumbers.entries) e.key: e.value * 1000 + build,
  };
}

void main() {
  test('the build number leaves room for the ABI in the version code', () {
    // release_lib.sh checks 1..999 too: 1000 or more would run into the next
    // ABI's codes.
    expect(pubspecVersion().build, inInclusiveRange(1, 999));
  });

  group('the changelog files for the app stores', () {
    test('there is one for every ABI, named after its version code', () {
      for (final entry in versionCodes().entries) {
        final file = File('${changelogDir.path}/${entry.value}.txt');
        expect(file.existsSync(), isTrue,
            reason: '${file.path} (${entry.key}) exists');
      }
    });

    test('nothing else is in the folder but files named after a version code',
        () {
      // Older versions' files stay (stores show them for older builds); a
      // stray name is a typo.
      final names = changelogDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList()
        ..sort();
      expect(names, isNotEmpty);
      for (final name in names) {
        expect(name, matches(RegExp(r'^[1-9]\d{3,}\.txt$')));
        final code = int.parse(name.split('.').first);
        expect(abiNumbers.values, contains(code ~/ 1000),
            reason: '$name starts with an ABI number');
        expect(File('${changelogDir.path}/$name').statSync().type,
            FileSystemEntityType.file);
      }
    });

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
        expect(bytes.length, lessThanOrEqualTo(maxChangelogBytes),
            reason: '$code.txt is ${bytes.length} bytes');
        // Printable ASCII and newlines only: no tabs, no carriage returns,
        // no accents, no invisible characters.
        expect(bytes.every((b) => b == 0x0A || (b >= 0x20 && b < 0x7F)),
            isTrue,
            reason: '$code.txt has only printable ASCII');
        final text = utf8.decode(bytes);
        expect(text.trim(), isNotEmpty);
        expect(text, endsWith('\n'));
        expect(text, isNot(endsWith('\n\n')));
        expect(text.split('\n').any((l) => l != l.trimRight()), isFalse,
            reason: 'no trailing spaces');
      }
    });

    test('the text says which version it is for', () {
      for (final code in versionCodes().values) {
        expect(File('${changelogDir.path}/$code.txt').readAsStringSync(),
            contains(pubspecVersion().name));
      }
    });
  });

  group("the README's release notes", () {
    final readme = File('README.md').readAsStringSync();

    test("have an entry for pubspec.yaml's version", () {
      final version = pubspecVersion().name;
      final headings = RegExp(r'^### (.*?)\s*$', multiLine: true)
          .allMatches(readme)
          .map((m) => m.group(1))
          .toList();
      expect(headings, contains(version));
    });

    test('list the versions oldest first, the newest last', () {
      final section = RegExp(r'^## Releases\s*$(.*?)^---\s*$',
              multiLine: true, dotAll: true)
          .firstMatch(readme);
      expect(section, isNotNull, reason: 'a Releases section');
      final versions = RegExp(r'^### ([0-9][0-9.]*)\s*$', multiLine: true)
          .allMatches(section!.group(1)!)
          .map((m) => m.group(1)!.split('.').map(int.parse).toList())
          .toList();
      expect(versions, hasLength(greaterThan(1)));
      for (var i = 1; i < versions.length; i++) {
        expect(_compare(versions[i - 1], versions[i]), lessThan(0),
            reason: '${versions[i - 1]} before ${versions[i]}');
      }
      expect(versions.last.join('.'), pubspecVersion().name,
          reason: 'the last entry is the version being built');
    });
  });
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return a.length.compareTo(b.length);
}
