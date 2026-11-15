// The store listing: the texts and screenshots app stores show, which
// F-Droid reads from fastlane/metadata/android/<locale>/ of the tagged
// commit. These tests keep them within F-Droid's limits and rules, keep the
// credit line at the end of every description, keep what the descriptions
// say about the defaults true, and keep the screenshots free of metadata.
// (The titles are checked in app_identity_test.dart, the changelogs in
// release_notes_test.dart.)

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

final metadataDir = Directory('fastlane/metadata/android');

/// The last line of each locale's description: the credit to the original
/// app. A new locale gets its own line here.
const credits = {
  'en-US': 'Based on Fake Contacts by Bill Dietrich.',
  'es': 'Basada en Fake Contacts, de Bill Dietrich.',
};

/// Words each short description keeps, so a search for them finds the app.
const searchWords = {'en-US': 'fake contacts', 'es': 'contactos falsos'};

/// F-Droid's limits, in characters.
const maxTitle = 50, maxShort = 80, maxFull = 4000;

/// Where the screenshots are; other locales show these.
final screenshotDir = Directory(
  'fastlane/metadata/android/en-US/images/phoneScreenshots',
);

/// Characters that can't be seen, and so can't be checked by reading.
final invisible = RegExp(
  r'[\u00A0\u00AD\u200B-\u200F\u2060\uFEFF]',
  unicode: true,
);

/// The locale folders.
List<String> locales() =>
    metadataDir
        .listSync()
        .whereType<Directory>()
        .map((dir) => dir.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toList()
      ..sort();

/// The text of [name] in [locale], checked to be clean text: UTF-8, lines
/// ending in a single "\n" each, the last one too, no tabs or other control
/// characters, no space at the end of a line, nothing invisible, no blank
/// line at the start or two in a row. Without the final newline.
String readText(String locale, String name) {
  final file = File('${metadataDir.path}/$locale/$name');
  expect(file.existsSync(), isTrue, reason: '${file.path} exists');
  final text = utf8.decode(file.readAsBytesSync());
  final where = file.path;
  expect(text, endsWith('\n'), reason: '$where ends with a newline');
  expect(
    text,
    isNot(endsWith('\n\n')),
    reason: '$where: no blank line at the end',
  );
  expect(text, isNot(startsWith('\n')), reason: '$where: no blank line first');
  expect(
    text,
    isNot(contains('\n\n\n')),
    reason: '$where: no two blank lines in a row',
  );
  expect(
    text.runes.where(
      (c) => (c < 0x20 && c != 0x0A) || (c >= 0x7F && c <= 0x9F),
    ),
    isEmpty,
    reason: '$where: no tabs, carriage returns or other controls',
  );
  expect(
    invisible.hasMatch(text),
    isFalse,
    reason: '$where: nothing invisible (write a plain space)',
  );
  for (final line in text.split('\n')) {
    expect(line, line.trimRight(), reason: '$where: no space at a line end');
    expect(line, line.trimLeft(), reason: '$where: no space at a line start');
  }
  return text.substring(0, text.length - 1);
}

/// The PNG chunks of [bytes] in order, as (type, data), checked to be one
/// whole PNG file.
List<(String, Uint8List)> pngChunks(Uint8List bytes, String where) {
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  expect(bytes.length, greaterThan(signature.length), reason: where);
  expect(bytes.sublist(0, 8), signature, reason: '$where is a PNG file');
  final data = ByteData.sublistView(bytes);
  final chunks = <(String, Uint8List)>[];
  var at = 8;
  while (at + 12 <= bytes.length) {
    final length = data.getUint32(at);
    final type = ascii.decode(bytes.sublist(at + 4, at + 8));
    expect(
      at + 12 + length,
      lessThanOrEqualTo(bytes.length),
      reason: '$where: chunk $type is cut off',
    );
    chunks.add((type, bytes.sublist(at + 8, at + 8 + length)));
    at += 12 + length;
    if (type == 'IEND') break;
  }
  expect(at, bytes.length, reason: '$where: nothing after IEND');
  expect(
    chunks.isNotEmpty ? chunks.last.$1 : null,
    'IEND',
    reason: '$where ends with IEND',
  );
  return chunks;
}

void main() {
  test('every locale has a credit line and search words', () {
    expect(locales(), unorderedEquals(credits.keys));
    expect(searchWords.keys, unorderedEquals(credits.keys));
  });

  for (final locale in credits.keys) {
    group('$locale:', () {
      test('the title fits on one line', () {
        final title = readText(locale, 'title.txt');
        expect(title, isNot(contains('\n')));
        expect(title.runes.length, inInclusiveRange(1, maxTitle));
      });

      group('the short description', () {
        String short() => readText(locale, 'short_description.txt');

        test('fits on one line', () {
          expect(short(), isNot(contains('\n')));
          expect(short().runes.length, inInclusiveRange(1, maxShort));
        });

        test('has the words people search for', () {
          expect(short().toLowerCase(), contains(searchWords[locale]));
        });

        test('passes the checks of F-Droid\'s lint', () {
          // fdroidserver/lint.py, REGEX_CHECKS['Summary'] (Python's
          // re.match: from the start).
          final lint = {
            r'.*\b(free software|open source)\b.*':
                'No need to specify that the app is Free Software',
            r'.*((your|for).*android|android.*(app|device|client|port|version))':
                'No need to specify that the app is for Android',
          };
          for (final MapEntry(key: pattern, value: message) in lint.entries) {
            expect(
              RegExp('^$pattern', caseSensitive: false).hasMatch(short()),
              isFalse,
              reason: message,
            );
          }
          expect(
            RegExp(r'^.*[a-z0-9][.!?]( |$)').hasMatch(short()),
            isFalse,
            reason: 'Punctuation should be avoided',
          );
          expect(
            short().toLowerCase(),
            isNot(readText(locale, 'title.txt').toLowerCase()),
            reason: "Summary is just the app's name",
          );
        });
      });

      group('the description', () {
        String full() => readText(locale, 'full_description.txt');

        test('fits', () {
          expect(full().runes.length, inInclusiveRange(1, maxFull));
        });

        test('ends with the credit to the original app', () {
          expect(full().split('\n').last, credits[locale]);
        });

        test('is plain text, as F-Droid shows it', () {
          // F-Droid takes a few HTML tags and turns each line break into
          // one; other stores show tags as they are. So none.
          expect(RegExp(r'<\s*[a-zA-Z/!]').hasMatch(full()), isFalse);
          expect(full(), isNot(contains('http://')));
        });

        test('has no line twice', () {
          // fdroidserver lint: "Description has a duplicate line".
          final lines = full().split('\n').where((l) => l.isNotEmpty);
          expect(lines.toSet(), hasLength(lines.length));
        });

        test("doesn't repeat the short description", () {
          expect(
            full().toLowerCase(),
            isNot(readText(locale, 'short_description.txt').toLowerCase()),
          );
        });

        test('gives the default phone range and email domain', () {
          expect(full(), contains('+44 7700 900000'));
          expect(full(), contains('900999'));
          expect(full(), contains('example.com'));
        });
      });
    });
  }

  test('what the descriptions say about the defaults is true', () {
    // They say the names start with Z, the numbers are in the UK range for
    // TV and film (+44 7700 900000 to 900999) and the email addresses use
    // example.com. If a default changes, change them too.
    for (final name in [
      ...parseNames(kDefaultFirstNames),
      ...parseNames(kDefaultLastNames),
    ]) {
      expect(name, startsWith('Z'));
    }
    expect(kDefaultPhoneTemplate, '+447700900nnn');
    expect(kDefaultEmailTemplate, endsWith('@example.com'));
  });

  group('the screenshots', () {
    List<File> screenshots() {
      final files = screenshotDir.listSync().whereType<File>().toList();
      int number(File f) => int.parse(f.uri.pathSegments.last.split('.').first);
      return files..sort((a, b) => number(a).compareTo(number(b)));
    }

    test('are numbered 1.png, 2.png, ... in the order shown', () {
      final names = screenshotDir
          .listSync()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList();
      expect(names, isNotEmpty);
      expect(
        names,
        unorderedEquals([for (var i = 1; i <= names.length; i++) '$i.png']),
      );
    });

    test('are the same size, upright, and opaque', () {
      (int, int)? size;
      for (final file in screenshots()) {
        final where = file.path;
        final chunks = pngChunks(file.readAsBytesSync(), where);
        expect(chunks.first.$1, 'IHDR', reason: where);
        final header = ByteData.sublistView(chunks.first.$2);
        final width = header.getUint32(0), height = header.getUint32(4);
        // fdroidserver refuses images of more than 4096 × 4096 pixels.
        expect(width * height, lessThanOrEqualTo(0xFFFFFF), reason: where);
        expect(height, greaterThan(width), reason: '$where is upright');
        size ??= (width, height);
        expect((width, height), size, reason: '$where is as big as the others');
        // 8 bits per channel, colour type 2: RGB without alpha.
        expect(header.getUint8(8), 8, reason: '$where: 8 bits per channel');
        expect(header.getUint8(9), 2, reason: '$where: RGB, no alpha');
      }
    });

    test('have no metadata', () {
      // Only the image itself: no text, time or Exif chunk, which could
      // say who made it, when or where.
      for (final file in screenshots()) {
        final types = pngChunks(
          file.readAsBytesSync(),
          file.path,
        ).map((c) => c.$1).toSet();
        expect(types, {'IHDR', 'IDAT', 'IEND'}, reason: file.path);
      }
    });

    test('are small enough to keep in the repository', () {
      for (final file in screenshots()) {
        expect(file.lengthSync(), lessThan(512 * 1024), reason: file.path);
      }
    });
  });
}
