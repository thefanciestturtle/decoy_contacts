// The README, CHANGELOG.md and DEVELOPMENT.md: what they say that the app,
// the release builds or CI decide. Their links, and the paths they name,
// lead to files in the repository and to the README's own sections; the
// README names the oldest Android the release builds install on, each type
// of processor a release has an APK for (DEVELOPMENT.md too), the
// defaults, and the app's own labels; DEVELOPMENT.md's Flutter and JDK
// versions are where it says.
// (about_page_test.dart checks the privacy policy, release_signing_test.dart
// the key's fingerprint, app_identity_test.dart the README's title, and
// release_notes_test.dart CHANGELOG.md's entries.)

import 'dart:io';

import 'package:decoy_contacts/about_page.dart' show kSourceUrl;
import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/main.dart';
import 'package:decoy_contacts/result_messages.dart' show kManyFakeContacts;
import 'package:decoy_contacts/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'in_memory_contacts_gateway.dart';

/// The files these tests read.
const docs = ['README.md', 'CHANGELOG.md', 'DEVELOPMENT.md'];

/// The oldest API level a release can start from: release APKs have no v1
/// signature (SIGNING_OPTIONS in tool/release_lib.sh), and Android before
/// 7.0 (24) needs one.
const oldestPossibleSdk = 24;

/// The Android version of each API level a release could start from.
const androidVersions = {
  24: '7.0',
  25: '7.1',
  26: '8.0',
  27: '8.1',
  28: '9',
  29: '10',
  30: '11',
  31: '12',
  32: '12L',
  33: '13',
  34: '14',
  35: '15',
  36: '16',
  37: '17',
};

/// The value of `readonly NAME=VALUE` in tool/release_lib.sh.
String releaseLibValue(String name) {
  final matches = RegExp('^readonly $name=(.*)\$', multiLine: true)
      .allMatches(File('tool/release_lib.sh').readAsStringSync());
  expect(matches, hasLength(1), reason: 'one $name in release_lib.sh');
  return matches.single.group(1)!;
}

/// [n] with commas between thousands, as the README writes numbers.
String withCommas(int n) => n
    .toString()
    .replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (m) => ',');

/// The anchor GitHub gives a Markdown heading's text: lower case, spaces
/// as hyphens, other punctuation dropped.
String anchorOf(String heading) => heading
    .toLowerCase()
    .replaceAll(RegExp(r'[^\w\- ]'), '')
    .replaceAll(' ', '-');

/// The text of the section under heading [heading] (of any level) in
/// [text], up to the next heading of that level or higher.
String section(String text, String heading) {
  final match = RegExp('^(#+) ${RegExp.escape(heading)}\\s*\$', multiLine: true)
      .firstMatch(text);
  expect(match, isNotNull, reason: 'a "$heading" heading');
  final level = match!.group(1)!.length;
  final rest = text.substring(match.end);
  final next = RegExp('^#{1,$level} ', multiLine: true).firstMatch(rest);
  return next == null ? rest : rest.substring(0, next.start);
}

void main() {
  final readme = File('README.md').readAsStringSync();

  test('the README names the oldest Android a release installs on', () {
    // tool/release_lib.sh checks that every release APK has this
    // minSdkVersion.
    final minSdk = int.parse(releaseLibValue('RELEASE_MIN_SDK'));
    expect(minSdk, greaterThanOrEqualTo(oldestPossibleSdk),
        reason: 'release APKs have no v1 signature, which older Android needs');
    expect(androidVersions.keys, contains(minSdk));
    final named = RegExp(r'Android (\S+) or newer')
        .allMatches(readme)
        .map((m) => m.group(1))
        .toSet();
    expect(named, {androidVersions[minSdk]});
    expect(section(readme, 'Install'),
        contains('needs Android ${androidVersions[minSdk]} or newer'));
  });

  test('the README and DEVELOPMENT.md name each type of processor a release '
      'has an APK for', () {
    final abis = RegExp(r'^\((.*)\)$')
        .firstMatch(releaseLibValue('RELEASE_ABIS'))
        ?.group(1)
        ?.split(' ');
    expect(abis, isNotNull);
    expect(abis, isNotEmpty);
    for (final (doc, heading) in [
      ('README.md', 'Install'),
      ('DEVELOPMENT.md', 'Release builds'),
    ]) {
      final text = section(File(doc).readAsStringSync(), heading);
      for (final abi in abis!) {
        expect(text, contains('`$abi`'), reason: '$doc, $heading');
      }
      // And no others.
      final named = RegExp(r'`((?:arm|x86|mips|riscv)[\w-]*)`')
          .allMatches(text)
          .map((m) => m.group(1))
          .toSet();
      expect(named, abis.toSet(), reason: '$doc, $heading');
    }
  });

  test('what the README says about the defaults is true', () {
    // The names start with Z, the phone template, the email template, and
    // when the app warns about the lists.
    for (final name in [
      ...parseNames(kDefaultFirstNames),
      ...parseNames(kDefaultLastNames),
    ]) {
      expect(name, startsWith('Z'));
    }
    expect(readme, contains('names start with Z'));
    expect(readme, contains('The default, `$kDefaultPhoneTemplate`,'));
    expect(readme, contains('The default, `$kDefaultEmailTemplate`,'));
    // The intro and the Settings name the template's range and the
    // address's domain in words: if a default changes, change them too.
    expect(kDefaultPhoneTemplate, '+447700900nnn');
    expect('+44 7700 900000 to 900999'.allMatches(readme), hasLength(2));
    expect(kDefaultEmailTemplate, endsWith('@example.com'));
    expect('use example.com, a domain reserved for examples'.allMatches(readme),
        hasLength(1));
    expect('uses example.com, a domain reserved for examples'.allMatches(readme),
        hasLength(1));
    expect(readme,
        contains('would make more than ${withCommas(kManyFakeContacts)} contacts'));
  });

  testWidgets("the labels and the dialog the README quotes are the app's",
      (tester) async {
    // With the default settings, as the README's steps start.
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    await tester.pumpWidget(MyApp(contacts: InMemoryContactsGateway()));
    await tester.pumpAndSettle();

    void expectQuoted(String text) =>
        expect(readme, contains('"$text"'), reason: 'the README quotes it');

    for (final label in ['Create Fake Contacts', 'Delete Fake Contacts']) {
      expectQuoted(label);
      expect(
          find.ancestor(
              of: find.text(label),
              matching: find.bySubtype<ButtonStyleButton>()),
          findsOneWidget,
          reason: 'a button labelled "$label"');
    }
    for (final label in ['Last names', 'First names']) {
      expectQuoted(label);
      expect(find.text(label), findsOneWidget, reason: 'a field "$label"');
    }

    // "The app asks, for example, "Create 756 fake contacts?". Tap
    // "Create"." The number is the default lists'.
    final n = parseNames(kDefaultFirstNames).length *
        parseNames(kDefaultLastNames).length;
    await tester.tap(find.text('Create Fake Contacts'));
    await tester.pumpAndSettle();
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    final title = (dialog.title! as Text).data!;
    expect(title, 'Create $n fake contacts?');
    expectQuoted(title);
    expectQuoted('Create');
    expect(
        find.descendant(
            of: find.byType(AlertDialog),
            matching: find.widgetWithText(TextButton, 'Create')),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // The menu (⋮).
    expect(readme, contains('The menu (⋮)'));
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    for (final item in ['Reset to defaults', 'About']) {
      expectQuoted(item);
      expect(find.text(item), findsOneWidget, reason: 'a menu item "$item"');
    }
  });

  test('links to files in the repository point at files that exist', () {
    for (final doc in docs) {
      final text = File(doc).readAsStringSync();
      final targets = [
        for (final m in RegExp(r'\]\(([^)\s]+)\)').allMatches(text)) m.group(1)!,
        for (final m in RegExp(r'\ssrc="([^"]+)"').allMatches(text))
          m.group(1)!,
      ];
      expect(targets, isNotEmpty, reason: '$doc has links');
      for (final target in targets) {
        if (RegExp(r'^[a-z]+:').hasMatch(target) || target.startsWith('#')) {
          continue;
        }
        // From the linking file's folder.
        final path = File(doc)
            .parent
            .uri
            .resolve(Uri.decodeFull(target.split('#').first))
            .toFilePath();
        expect(
            FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound,
            isTrue,
            reason: '$doc links to $target');
      }
    }
  });

  test("links to the README's sections lead to a heading", () {
    // CHANGELOG.md's 2.0.0 entry links to "If you have Fake Contacts" with
    // the full address, as the GitHub release copies it.
    final anchors = {
      for (final m in RegExp(r'^#+ (.*?)\s*$', multiLine: true).allMatches(readme))
        anchorOf(m.group(1)!),
      'readme',
    };
    final links = RegExp(
        '${RegExp.escape('$kSourceUrl')}#([\\w-]+)|\\]\\(README\\.md#([\\w-]+)\\)');
    var count = 0;
    for (final doc in docs) {
      for (final m in links.allMatches(File(doc).readAsStringSync())) {
        count++;
        expect(anchors, contains(m.group(1) ?? m.group(2)), reason: doc);
      }
    }
    expect(count, greaterThan(0));
  });

  test('the files and folders named in code spans exist', () {
    // Paths in the repository, such as `tool/build_release.sh [TAG]` (its
    // first word); not those the build makes (build/, dist/), placeholders
    // or home folders.
    final repoPath = RegExp(
        r'^((tool|test|integration_test|lib|android|fastlane|\.github)/\S*'
        r'|[\w.-]+\.(md|yaml|yml|sh|dart))$');
    var count = 0;
    for (final doc in docs) {
      for (final m
          in RegExp(r'`([^`\n]+)`').allMatches(File(doc).readAsStringSync())) {
        final word = m.group(1)!.split(' ').first;
        if (!repoPath.hasMatch(word) || word.contains(RegExp(r'[<*]'))) continue;
        count++;
        expect(
            FileSystemEntity.typeSync(word) != FileSystemEntityType.notFound,
            isTrue,
            reason: '$doc names $word');
      }
    }
    expect(count, greaterThan(10));
  });

  test('the README links to the changelog and the development notes', () {
    expect(section(readme, 'Changes'), contains('](CHANGELOG.md)'));
    expect(section(readme, 'Development'), contains('](DEVELOPMENT.md)'));
  });

  test("links to this project on GitHub use the app's source address", () {
    // kSourceUrl, which About links to (app_identity_test.dart checks the
    // repository's name).
    final project = RegExp(r'https?://github\.com/thefanciestturtle/[^\s)>"]*');
    for (final doc in docs) {
      for (final m in project.allMatches(File(doc).readAsStringSync())) {
        final url = m.group(0)!;
        expect(url, matches(RegExp('^${RegExp.escape('$kSourceUrl')}([/#]|\$)')),
            reason: doc);
      }
    }
  });

  test("DEVELOPMENT.md's Flutter and JDK versions are where it says", () {
    // "`FLUTTER_VERSION` in `.github/workflows/dart.yml`", "`JAVA_VERSION`
    // there" (tool/check_lib.sh reads them from there too).
    final development = File('DEVELOPMENT.md').readAsStringSync();
    final workflow = File('.github/workflows/dart.yml').readAsStringSync();
    expect(development, contains('`.github/workflows/dart.yml`'));
    for (final name in ['FLUTTER_VERSION', 'JAVA_VERSION']) {
      expect(development, contains('`$name`'));
      expect(workflow, matches(RegExp('^  $name: \\S', multiLine: true)),
          reason: 'dart.yml sets $name');
    }
  });
}
