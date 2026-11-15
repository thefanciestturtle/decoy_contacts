// The store listing: the texts and images app stores show, which F-Droid
// reads from fastlane/metadata/android/<locale>/ of the tagged commit. These
// tests keep them within F-Droid's limits and rules, keep the credit line at
// the end of every description, keep what the descriptions say about the
// app true, and keep the images whole and free of metadata.
// (app_identity_test.dart checks that the titles are the app's name, and
// release_notes_test.dart the changelogs.)

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

/// The texts of each locale, and F-Droid's limit for each, in characters.
const textLimits = {
  'title.txt': 50,
  'short_description.txt': 80,
  'full_description.txt': 4000,
};

/// Characters that can't be seen, or that change how the text around them
/// shows (direction marks, line separators), and so can't be checked by
/// reading.
final invisible = RegExp(
  r'[\u00A0\u00AD\u061C\u180E\u200B-\u200F\u2028-\u202F\u2060-\u2064\u2066-\u2069\uFEFF]',
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

/// The text of [name] in [locale], without its final newline.
String read(String locale, String name) {
  final text = File('${metadataDir.path}/$locale/$name').readAsStringSync();
  return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
}

/// Checks that [file] is clean text: UTF-8, lines ending in a single "\n"
/// each, the last one too, no tabs or other control characters, no space
/// at the start or end of a line, nothing invisible, no blank line at the
/// start or end or two in a row.
void expectCleanText(File file) {
  final where = file.path;
  expect(file.existsSync(), isTrue, reason: '$where exists');
  final text = utf8.decode(file.readAsBytesSync());
  expect(text, endsWith('\n'), reason: '$where ends with a newline');
  expect(text, isNot(endsWith('\n\n')), reason: '$where: blank line at end');
  expect(text, isNot(startsWith('\n')), reason: '$where: blank line first');
  expect(text, isNot(contains('\n\n\n')), reason: '$where: two blank lines');
  expect(
    text.runes.where(
      (c) => (c < 0x20 && c != 0x0A) || (c >= 0x7F && c <= 0x9F),
    ),
    isEmpty,
    reason: '$where: no tabs, carriage returns or other controls',
  );
  expect(
    invisible.allMatches(text).map((m) => m.group(0)!.runes.single),
    isEmpty,
    reason: '$where: nothing invisible (write a plain space)',
  );
  for (final line in text.split('\n')) {
    expect(line, line.trim(), reason: '$where: space at a line start or end');
  }
}

/// The CRC-32 of [bytes], as PNG chunks carry it.
int crc32(Uint8List bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// A PNG file's header, and the types of its chunks in order.
typedef Png = ({
  int width,
  int height,
  int bitDepth,
  int colourType,
  List<String> chunks,
});

/// Reads [file] as a PNG file, checked to be whole: the signature, every
/// chunk with its CRC, IHDR first and IEND last, nothing after it, and
/// image data that unpacks to exactly the size the header gives.
Png readPng(File file) {
  final where = file.path;
  final bytes = file.readAsBytesSync();
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  expect(bytes.length, greaterThan(signature.length), reason: where);
  expect(bytes.sublist(0, 8), signature, reason: '$where is a PNG file');
  final data = ByteData.sublistView(bytes);
  final chunks = <String>[];
  final idat = BytesBuilder(copy: false);
  Uint8List? header;
  var at = 8;
  while (at + 12 <= bytes.length) {
    final length = data.getUint32(at);
    final type = ascii.decode(bytes.sublist(at + 4, at + 8));
    expect(
      at + 12 + length,
      lessThanOrEqualTo(bytes.length),
      reason: '$where: chunk $type is cut off',
    );
    final typeAndData = Uint8List.sublistView(bytes, at + 4, at + 8 + length);
    expect(
      crc32(typeAndData),
      data.getUint32(at + 8 + length),
      reason: '$where: chunk $type is damaged (CRC)',
    );
    final body = Uint8List.sublistView(bytes, at + 8, at + 8 + length);
    if (type == 'IHDR') header = body;
    if (type == 'IDAT') idat.add(body);
    chunks.add(type);
    at += 12 + length;
    if (type == 'IEND') break;
  }
  expect(at, bytes.length, reason: '$where: nothing after IEND');
  expect(chunks.first, 'IHDR', reason: '$where starts with IHDR');
  expect(chunks.last, 'IEND', reason: '$where ends with IEND');
  final ihdr = ByteData.sublistView(header!);
  final png = (
    width: ihdr.getUint32(0),
    height: ihdr.getUint32(4),
    bitDepth: ihdr.getUint8(8),
    colourType: ihdr.getUint8(9),
    chunks: chunks,
  );
  expect(ihdr.getUint8(12), 0, reason: '$where: not interlaced');
  const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
  expect(channels.keys, contains(png.colourType), reason: where);
  final bitsPerRow = png.width * channels[png.colourType]! * png.bitDepth;
  // Each row: a filter byte, then the pixels.
  final rowBytes = 1 + (bitsPerRow + 7) ~/ 8;
  expect(
    ZLibCodec().decode(idat.takeBytes()).length,
    png.height * rowBytes,
    reason: "$where: the image data is as big as the header says",
  );
  return png;
}

/// The images under any locale's images folder.
List<File> storeImages() => [
  for (final locale in locales())
    if (Directory('${metadataDir.path}/$locale/images').existsSync())
      ...Directory('${metadataDir.path}/$locale/images')
          .listSync(recursive: true)
          .whereType<File>(),
];

/// The screenshot folders among them (phoneScreenshots,
/// tenInchScreenshots, ...).
List<Directory> screenshotDirs() => [
  for (final locale in locales())
    if (Directory('${metadataDir.path}/$locale/images').existsSync())
      ...Directory('${metadataDir.path}/$locale/images')
          .listSync()
          .whereType<Directory>()
          .where((d) => baseName(d).endsWith('Screenshots')),
];

String baseName(FileSystemEntity e) =>
    e.uri.pathSegments.where((s) => s.isNotEmpty).last;

void main() {
  test('every locale has a credit line and search words', () {
    expect(locales(), unorderedEquals(credits.keys));
    expect(searchWords.keys, unorderedEquals(credits.keys));
  });

  for (final locale in credits.keys) {
    group('$locale:', () {
      for (final MapEntry(key: name, value: limit) in textLimits.entries) {
        test('$name is clean text, within $limit characters', () {
          expectCleanText(File('${metadataDir.path}/$locale/$name'));
          expect(read(locale, name).runes.length, inInclusiveRange(1, limit));
        });
      }

      test('the title and the short description are one line each', () {
        expect(read(locale, 'title.txt'), isNot(contains('\n')));
        expect(read(locale, 'short_description.txt'), isNot(contains('\n')));
      });

      test('the short description has the words people search for', () {
        expect(
          read(locale, 'short_description.txt').toLowerCase(),
          contains(searchWords[locale]),
        );
      });

      test("the short description passes F-Droid's lint", () {
        // fdroidserver/lint.py, REGEX_CHECKS['Summary'] (Python's re.match:
        // from the start), and check_duplicates. Its lint reads the app's
        // metadata, not these files: these are the same rules, kept here.
        final short = read(locale, 'short_description.txt');
        final lint = {
          r'.*\b(free software|open source)\b.*':
              'No need to specify that the app is Free Software',
          r'.*((your|for).*android|android.*(app|device|client|port|version))':
              'No need to specify that the app is for Android',
        };
        for (final MapEntry(key: pattern, value: message) in lint.entries) {
          expect(
            RegExp('^$pattern', caseSensitive: false).hasMatch(short),
            isFalse,
            reason: message,
          );
        }
        expect(
          RegExp(r'^.*[a-z0-9][.!?]( |$)').hasMatch(short),
          isFalse,
          reason: 'Punctuation should be avoided',
        );
        expect(
          short.toLowerCase(),
          isNot(read(locale, 'title.txt').toLowerCase()),
          reason: "Summary is just the app's name",
        );
      });

      group('the description', () {
        String full() => read(locale, 'full_description.txt');

        test('ends with the credit to the original app', () {
          expect(full().split('\n').last, credits[locale]);
        });

        test('is plain text, as F-Droid shows it', () {
          // F-Droid shows it as HTML (a few tags, character references,
          // each line break turned into one); other stores show tags as
          // they are. So none of either.
          expect(
            RegExp(r'<\s*[a-zA-Z/!?]').hasMatch(full()),
            isFalse,
            reason: 'no HTML tags',
          );
          expect(
            RegExp(r'&[#a-zA-Z]').hasMatch(full()),
            isFalse,
            reason: 'no character references',
          );
          expect(full(), isNot(contains('http://')));
        });

        test('has no line twice', () {
          // fdroidserver lint: "Description has a duplicate line".
          final lines = full().split('\n').where((l) => l.isNotEmpty);
          expect(lines.toSet(), hasLength(lines.length));
        });

        test("isn't just the short description", () {
          expect(
            full().toLowerCase(),
            isNot(read(locale, 'short_description.txt').toLowerCase()),
          );
        });

        test('gives the default phone range and email domain', () {
          expect(full(), contains('+44 7700 900000'));
          expect(full(), contains('900999'));
          expect(full(), contains('example.com'));
        });

        test('names only buttons the app has', () {
          // Quoted «like this», by their labels in the app.
          final home = File('lib/home_page.dart').readAsStringSync();
          for (final label in RegExp('«([^»]*)»').allMatches(full())) {
            expect(
              home,
              contains('Text("${label.group(1)}")'),
              reason: 'a button labelled "${label.group(1)}"',
            );
          }
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

  test('the Spanish description says the app is in English, while it is', () {
    // Then it names the buttons by their English labels too. Once the app
    // is translated (U10), both change.
    final bTranslated = File('pubspec.yaml')
        .readAsStringSync()
        .contains('flutter_localizations');
    final full = read('es', 'full_description.txt');
    expect(full.contains('La aplicación está en inglés.'), !bTranslated);
    expect(full.contains('«Create Fake Contacts»'), !bTranslated);
  });

  group('the images', () {
    test('are PNG files, whole, without metadata, and not too big', () {
      final images = storeImages();
      expect(images, isNotEmpty);
      for (final file in images) {
        expect(baseName(file), endsWith('.png'), reason: file.path);
        final png = readPng(file);
        // Only the image itself: no text, time or Exif chunk, which could
        // say who made it, when or where.
        expect(png.chunks.toSet().difference({'PLTE', 'tRNS'}), {
          'IHDR',
          'IDAT',
          'IEND',
        }, reason: file.path);
        // fdroidserver refuses an image of more than 0xFFFFFF pixels
        // (Pillow's limit, one pixel short of 4096 × 4096).
        expect(
          png.width * png.height,
          lessThanOrEqualTo(0xFFFFFF),
          reason: file.path,
        );
        // Small enough to keep in the repository.
        expect(file.lengthSync(), lessThan(512 * 1024), reason: file.path);
      }
    });

    test('screenshots are numbered 1.png, 2.png, ... in the order shown', () {
      final dirs = screenshotDirs();
      expect(dirs, isNotEmpty);
      for (final dir in dirs) {
        // fdroidserver sorts the names as text: 10.png would come before
        // 2.png.
        final names = dir.listSync().map(baseName).toList()..sort();
        expect(names, [
          for (var i = 1; i <= names.length; i++) '$i.png',
        ], reason: dir.path);
      }
    });

    test('screenshots are the same size, upright, and opaque', () {
      for (final dir in screenshotDirs()) {
        (int, int)? size;
        for (final file in dir.listSync().whereType<File>()) {
          final where = file.path;
          final png = readPng(file);
          expect(png.height, greaterThan(png.width), reason: '$where upright');
          size ??= (png.width, png.height);
          expect(
            (png.width, png.height),
            size,
            reason: '$where is as big as the others',
          );
          // 8 bits per channel, colour type 2: RGB without alpha.
          expect(png.bitDepth, 8, reason: where);
          expect(png.colourType, 2, reason: '$where: RGB, no alpha');
        }
      }
    });
  });
}
