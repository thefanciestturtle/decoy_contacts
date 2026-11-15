// The store listing: the texts and images app stores show, which F-Droid
// reads from fastlane/metadata/android/<locale>/ of the tagged commit. These
// tests keep them within F-Droid's limits and rules, keep the credit line at
// the end of every description, keep what the descriptions say about the
// app true, and keep the images whole and free of metadata.
// (app_identity_test.dart checks that the titles are the app's name, and
// release_notes_test.dart the changelogs.)

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:decoy_contacts/about_page.dart' show kAboutSections;
import 'package:decoy_contacts/contact_actions.dart';
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/main.dart';
import 'package:decoy_contacts/result_messages.dart';
import 'package:decoy_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'in_memory_contacts_gateway.dart';

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
/// shows, and so can't be checked by reading: controls (tabs, carriage
/// returns, ...), format characters (direction marks, zero-width
/// spaces, ...), private or unassigned ones, line and paragraph
/// separators, every space but the plain one, and the marks and fillers
/// that show nothing (variation selectors, Hangul fillers, the blank
/// Braille pattern, ...). Newlines end lines, and are allowed.
final invisible = RegExp(
  r'(?![ \n])[\p{C}\p{Z}\u034F\u115F\u1160\u17B4\u17B5\u2800\u3164\uFE00-\uFE0F\uFFA0\u{E0100}-\u{E01EF}]',
  unicode: true,
);

/// The locale folders.
List<String> locales() =>
    metadataDir.listSync().whereType<Directory>().map(baseName).toList()
      ..sort();

String baseName(FileSystemEntity e) =>
    e.uri.pathSegments.where((s) => s.isNotEmpty).last;

/// The text of [name] in [locale], without its final newline.
String read(String locale, String name) {
  final text = File('${metadataDir.path}/$locale/$name').readAsStringSync();
  return text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
}

/// Checks that [file] is clean text: UTF-8, lines ending in a single "\n"
/// each, the last one too, nothing [invisible] (no tabs either), no space
/// at the start or end of a line, no blank line at the start or end or two
/// in a row.
void expectCleanText(File file) {
  final where = file.path;
  expect(file.existsSync(), isTrue, reason: '$where exists');
  final text = utf8.decode(file.readAsBytesSync());
  expect(text, endsWith('\n'), reason: '$where ends with a newline');
  expect(text, isNot(endsWith('\n\n')), reason: '$where: blank line at end');
  expect(text, isNot(startsWith('\n')), reason: '$where: blank line first');
  expect(text, isNot(contains('\n\n\n')), reason: '$where: two blank lines');
  expect(
    [
      for (final m in invisible.allMatches(text))
        'U+${m.group(0)!.runes.single.toRadixString(16).toUpperCase()}',
    ],
    isEmpty,
    reason: '$where: nothing invisible, no tabs (write a plain space)',
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
/// image data that unpacks to exactly the size the header gives. Each file
/// is read once.
Png readPng(File file) => _pngs.putIfAbsent(file.path, () => _readPng(file));

final _pngs = <String, Png>{};

Png _readPng(File file) {
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
  expect(chunks, isNotEmpty, reason: '$where has chunks');
  expect(chunks.first, 'IHDR', reason: '$where starts with IHDR');
  expect(chunks.where((c) => c == 'IHDR'), hasLength(1), reason: where);
  expect(chunks.last, 'IEND', reason: '$where ends with IEND');
  final firstIdat = chunks.indexOf('IDAT');
  expect(firstIdat, isNonNegative, reason: '$where has image data');
  expect(
    chunks.lastIndexOf('IDAT') - firstIdat + 1,
    chunks.where((c) => c == 'IDAT').length,
    reason: '$where: the IDAT chunks come one after another',
  );
  expect(header!.length, 13, reason: '$where: IHDR is 13 bytes');
  final ihdr = ByteData.sublistView(header);
  final png = (
    width: ihdr.getUint32(0),
    height: ihdr.getUint32(4),
    bitDepth: ihdr.getUint8(8),
    colourType: ihdr.getUint8(9),
    chunks: chunks,
  );
  expect(ihdr.getUint8(10), 0, reason: '$where: compression method 0');
  expect(ihdr.getUint8(11), 0, reason: '$where: filter method 0');
  expect(ihdr.getUint8(12), 0, reason: '$where: not interlaced');
  const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
  const bitDepths = {
    0: [1, 2, 4, 8, 16],
    2: [8, 16],
    3: [1, 2, 4, 8],
    4: [8, 16],
    6: [8, 16],
  };
  expect(channels.keys, contains(png.colourType), reason: where);
  expect(
    bitDepths[png.colourType],
    contains(png.bitDepth),
    reason: '$where: a bit depth its colour type allows',
  );
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

/// The images folders of the locales that have one.
List<Directory> imagesDirs() => [
  for (final locale in locales())
    Directory('${metadataDir.path}/$locale/images'),
].where((dir) => dir.existsSync()).toList();

/// The images in them.
List<File> storeImages() => [
  for (final dir in imagesDirs())
    ...dir.listSync(recursive: true).whereType<File>(),
];

/// The screenshot folders among them (phoneScreenshots,
/// tenInchScreenshots, ...).
List<Directory> screenshotDirs() => [
  for (final dir in imagesDirs())
    ...dir.listSync().whereType<Directory>().where(
      (d) => baseName(d).endsWith('Screenshots'),
    ),
];

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

  testWidgets('the buttons the descriptions name by their labels are the '
      "app's", (tester) async {
    // Quoted «like this». (The English one calls them Create and Delete.)
    final labels = {
      for (final locale in credits.keys)
        for (final m in RegExp(
          '«([^»]*)»',
        ).allMatches(read(locale, 'full_description.txt')))
          m.group(1)!,
    };
    expect(labels, isNotEmpty);
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(MyApp(contacts: InMemoryContactsGateway()));
    await tester.pumpAndSettle();
    for (final label in labels) {
      expect(
        find.ancestor(
          of: find.text(label),
          matching: find.bySubtype<ButtonStyleButton>(),
        ),
        findsOneWidget,
        reason: 'a button labelled "$label"',
      );
    }
  });

  test('the descriptions say what the app asks for and keeps', () {
    // "No internet access", "The only permission it asks for is access to
    // your contacts" and "isn't backed up". (Plugins can add permissions
    // to the build: tool/release_lib.sh checks each release APK's.)
    String withoutComments(String xml) =>
        xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');
    String? attribute(String tag, String name) =>
        RegExp('\\s$name="([^"]*)"').firstMatch(tag)?.group(1);
    final manifest = withoutComments(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    // <uses-permission ...>, <uses-permission-sdk-23 ...>
    expect(
      [
        for (final tag in RegExp(
          r'<uses-permission[^>]*>',
        ).allMatches(manifest))
          attribute(tag.group(0)!, 'android:name'),
      ],
      unorderedEquals([
        'android.permission.READ_CONTACTS',
        'android.permission.WRITE_CONTACTS',
      ]),
    );
    final application = RegExp(r'<application\b[^>]*>').allMatches(manifest);
    expect(application, hasLength(1));
    final tag = application.single.group(0)!;
    expect(attribute(tag, 'android:allowBackup'), 'false');
    expect(
      attribute(tag, 'android:dataExtractionRules'),
      '@xml/data_extraction_rules',
    );
    final rules = withoutComments(
      File('android/app/src/main/res/xml/data_extraction_rules.xml')
          .readAsStringSync(),
    );
    for (final section in ['cloud-backup', 'device-transfer']) {
      final body = RegExp(
        '<$section>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules)?.group(1);
      expect(body, isNotNull, reason: section);
      expect(
        RegExp(r'<exclude domain="(\w+)" path="\." />')
            .allMatches(body!)
            .map((m) => m.group(1))
            .toSet(),
        containsAll([
          'root',
          'file',
          'database',
          'sharedpref',
          'external',
          'device_root',
          'device_file',
          'device_database',
          'device_sharedpref',
        ]),
        reason: '$section excludes everything',
      );
      expect(body, isNot(contains('<include')), reason: section);
    }
  });

  test('the Spanish description says the app is in English, while it is', () {
    // Then it names the buttons by their English labels too. Once the app
    // is translated into Spanish (U10: its texts in ARB files), all change.
    final bTranslated = Directory('lib')
        .listSync(recursive: true)
        .any((f) => RegExp(r'_es(_\w+)?\.arb$').hasMatch(f.path));
    final full = read('es', 'full_description.txt');
    for (final english in [
      'La aplicación está en inglés.',
      '«Create Fake Contacts»',
      '«Delete Fake Contacts»',
    ]) {
      expect(full.contains(english), !bTranslated, reason: english);
    }
  });

  test('the About text screenshot 4 shows is still the app\'s', () {
    // en-US/images/phoneScreenshots/4.png shows About from the top: the
    // name, the version, then these, down to the next heading and the start
    // of its text. If they change, retake it. (Not the version: it shows
    // the one it was taken with.)
    const shownOfNext =
        'None of this is backed up or moved to a new phone. '
        'After a move to a new phone, clearing the';
    expect(
      [
        for (final (heading, paragraphs) in kAboutSections.take(3))
          [heading, ...paragraphs],
        [
          kAboutSections[3].$1,
          kAboutSections[3].$2.first.substring(
            0,
            min(shownOfNext.length, kAboutSections[3].$2.first.length),
          ),
        ],
      ],
      [
        [
          'What it does',
          'Some apps and companies copy the contacts on your phone, to use or '
              'sell them. This app adds fake contacts among your real ones, so '
              'what they copy is worth less. This is called data poisoning.',
          "The fake contacts don't get in the way of your real ones. By "
              'default their names start with Z, so they sort to the end.',
        ],
        [
          'Create and Delete',
          'Create adds a fake contact for each first name with each last '
              'name. In the phone number template, each n becomes a digit. In '
              'the email address template, FIRST and LAST become the names.',
          'Delete only removes fake contacts this app created, and only if '
              'they are still as it made them. Your real contacts are never '
              'touched.',
        ],
        [
          'What it stores',
          'Your names and templates, and a list of the fake contacts it '
              "created, so Delete can find them. They stay in the app's own "
              'storage on this phone.',
        ],
        ['New phone or backup', shownOfNext],
      ],
      reason: 'screenshot 4 shows this text: retake it',
    );
  });

  testWidgets("the text screenshots 1, 2, 3 and 5 show is still the app's", (
    tester,
  ) async {
    // 1.png and 5.png: the home screen with the default settings after
    // creating all 756 fake contacts (5.png without the result); 2.png and
    // 3.png: the dialogs before Create and Delete, over it. If any of this
    // changes, retake them.
    expect(
      kDefaultLastNames,
      'Zen,Zaragoza,Zabinski,Zimmermann,Zapata,Zona,Zidane,Zeiss,Zimmer,Zaal,'
      'Zaman,Zambrano,Zanetti,Zangari,Zappa,Zavala,Zawisza,Zeegers,Zelenka,'
      'Zellweger,Zeni,Zhang,Zhao,Zheng,Zhou,Ziegler,Zima',
    );
    expect(
      kDefaultFirstNames,
      'Zoe,Zach,Zbigniew,Zaire,Zero,Zakai,Zamir,Zan,Zanna,Zareen,Zeb,Zeki,'
      'Zelda,Zella,Zeno,Zephyr,Zhen,Zhi,Zhong,Zhu,Ziba,Ziggy,Zion,Zola,'
      'Zolyan,Zora,Zsazsa,Zuzana',
    );
    expect(kDefaultPhoneTemplate, '+447700900nnn');
    expect(kDefaultEmailTemplate, 'FIRST.LAST@example.com');
    expect(
      settingsPreviewText(previewSettings(Settings.defaults)).text,
      [
        '27 last names × 28 first names = 756 fake contacts.',
        'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com',
      ].join('\n'),
    );
    const all = DeletePreview(
      toDelete: 756,
      skippedMerged: 0,
      skippedChanged: 0,
    );
    expect(statusMessage(all), '756 fake contacts on this phone.');
    expect(
      createdMessage(
        const CreateResult(created: 756, alreadyExisted: 0, untracked: 0),
      ),
      const ResultMessage('Created 756 fake contacts.'),
    );
    expect(
      createConfirmation(const CreatePreview(toCreate: 756, alreadyExisted: 0)),
      (
        title: 'Create 756 fake contacts?',
        body: 'They are added to the contacts on this phone.',
        action: 'Create',
      ),
    );
    expect(deleteConfirmation(all), (
      title: 'Delete 756 fake contacts?',
      body: 'Only contacts this app created are deleted.',
      action: 'Delete',
    ));

    // The labels, as the app shows them; and a dialog's Cancel.
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(MyApp(contacts: InMemoryContactsGateway()));
    await tester.pumpAndSettle();
    for (final label in [
      'Decoy Contacts',
      'Last names',
      'First names',
      'Phone number template',
      'Email address template',
      'Create Fake Contacts',
      'Delete Fake Contacts',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await tester.ensureVisible(find.text('Create Fake Contacts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Fake Contacts'));
    await tester.pumpAndSettle();
    expect(find.text('Create 756 fake contacts?'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Create'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
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

    test('screenshots are numbered 1, 2, ... in the order shown', () {
      final dirs = screenshotDirs();
      expect(dirs, isNotEmpty);
      for (final dir in dirs) {
        // fdroidserver sorts the names as text, so from 10 on they need
        // the same number of digits (01.png, ...): 10.png would come
        // before 2.png.
        final names = dir.listSync().map(baseName).toList()..sort();
        expect(
          [
            for (final name in names)
              int.tryParse(
                RegExp(r'^(\d+)\.png$').firstMatch(name)?.group(1) ?? '',
              ),
          ],
          [for (var i = 1; i <= names.length; i++) i],
          reason: '${dir.path}: $names',
        );
      }
    });

    test('screenshots are the same size, upright (phone), and opaque', () {
      for (final dir in screenshotDirs()) {
        (int, int)? size;
        for (final file in dir.listSync().whereType<File>()) {
          final where = file.path;
          final png = readPng(file);
          // (Phone screenshots: TV and tablet ones can be landscape.)
          if (baseName(dir) == 'phoneScreenshots') {
            expect(
              png.height,
              greaterThan(png.width),
              reason: '$where upright',
            );
          }
          size ??= (png.width, png.height);
          expect(
            (png.width, png.height),
            size,
            reason: '$where is as big as the others',
          );
          // 8 bits per channel, colour type 2: RGB without alpha, and no
          // colour made see-through (tRNS).
          expect(png.bitDepth, 8, reason: where);
          expect(png.colourType, 2, reason: '$where: RGB, no alpha');
          expect(png.chunks, isNot(contains('tRNS')), reason: where);
        }
      }
    });
  });
}
