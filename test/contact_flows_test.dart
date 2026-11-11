// Full Create and Delete flows, through the UI, against an in-memory address
// book.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:fake_contacts/about_page.dart' show AboutPage, kAppVersion;
import 'package:fake_contacts/app_log.dart';
import 'package:fake_contacts/app_theme.dart' show FocusRing, RenderFocusRing;
import 'package:fake_contacts/contact_actions.dart'
    show kCreateChunkSize, kDeleteChunkSize;
import 'package:fake_contacts/contacts_gateway.dart';
import 'package:fake_contacts/fake_contacts_core.dart';
import 'package:fake_contacts/home_page.dart' show kSaveDelay;
import 'package:fake_contacts/input_checks.dart' show phoneTemplateWarning;
import 'package:fake_contacts/main.dart';
import 'package:fake_contacts/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'failing_ledger_store.dart';
import 'in_memory_contacts_gateway.dart';
import 'talkback_announcements.dart';

/// 2 last names x 2 first names = these 4 fakes.
const Map<String, Object> kSettings = {
  'sListOfLastNames': 'Zen, Zima',
  'sListOfFirstNames': 'Zoe, Zach',
  'sPhoneNumberTemplate': kDefaultPhoneTemplate,
  'sEmailAddressTemplate': kDefaultEmailTemplate,
};
const List<String> kFakeNames = ['Zoe Zen', 'Zach Zen', 'Zoe Zima', 'Zach Zima'];

const String kCreateButton = 'Create Fake Contacts';
const String kDeleteButton = 'Delete Fake Contacts';

const String kDenied = 'Permission to access contacts was denied.';
const String kOneMerged =
    ' 1 was merged with another contact and was left alone.';
const String kOneChanged =
    " 1 no longer matches what this app created (edited, or the app's"
    " records came from another phone) and was left alone.";
String someChanged(int n) =>
    " $n no longer match what this app created (edited, or the app's records"
    " came from another phone) and were left alone.";
const String kReadFailed = "Couldn't read your contacts. Try again.";
const String kCreateFailed = "Couldn't create fake contacts. Try again.";
const String kDeleteFailed = "Couldn't delete fake contacts. Try again.";
const String kCreateBody = 'They are added to the contacts on this phone.';
const String kDeleteBody = 'Only contacts this app created are deleted.';

/// The entry a fake with this name gets under [kSettings].
LedgerEntry fakeEntry(String first, String last) =>
    entryFor(FakeName(first, last), kDefaultPhoneTemplate, kDefaultEmailTemplate);

void setPrefs({Map<String, Object> ledger = const {}}) {
  SharedPreferences.setMockInitialValues({
    ...kSettings,
    if (ledger.isNotEmpty) kLedgerPrefsKey: jsonEncode(ledger),
  });
}

Future<void> pumpApp(WidgetTester tester, ContactsGateway contacts,
    {LedgerStore ledgerStore = const LedgerStore(),
    int createChunkSize = kCreateChunkSize,
    int deleteChunkSize = kDeleteChunkSize}) async {
  // Tall enough that both buttons are on screen.
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  // Unmount the app while the test still runs: an edit that wasn't saved
  // yet (say, the test failed) is saved on dispose, and must not land in
  // the next test's settings.
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  await tester.pumpWidget(MyApp(
      contacts: contacts,
      ledgerStore: ledgerStore,
      createChunkSize: createChunkSize,
      deleteChunkSize: deleteChunkSize));
  await tester.pumpAndSettle();
}

/// Taps Create, expects the dialog that asks to go ahead, and confirms.
Future<void> tapCreate(WidgetTester tester) =>
    tapAndAnswer(tester, kCreateButton, 'Create');

/// Taps Delete, expects the dialog that asks to go ahead, and confirms.
Future<void> tapDelete(WidgetTester tester) =>
    tapAndAnswer(tester, kDeleteButton, 'Delete');

/// Taps [button], expects a dialog, and taps [answer] in it.
Future<void> tapAndAnswer(
    WidgetTester tester, String button, String answer) async {
  await tapAndOpenDialog(tester, button);
  await tester.tap(dialogButton(answer));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing);
}

/// Taps [button] and expects the dialog that asks to go ahead.
Future<void> tapAndOpenDialog(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget,
      reason: '"$button" should ask before going ahead');
}

/// Taps [button] and expects a result without a dialog, e.g. when there is
/// nothing to do or the permission is denied.
Future<void> tapExpectingNoDialog(WidgetTester tester, String button) async {
  await tester.tap(find.text(button));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsNothing,
      reason: '"$button" should not ask here');
}

Finder dialogButton(String label) => find.descendant(
    of: find.byType(AlertDialog), matching: find.widgetWithText(TextButton, label));

/// The title and text of the open dialog.
({String title, String body}) dialogText(WidgetTester tester) {
  final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
  return (
    title: (dialog.title! as Text).data!,
    body: (dialog.content! as Text).data!,
  );
}

/// The result under the buttons, if any.
final Finder resultFinder = find.byKey(const Key('Result'));

/// Pumps 10 ms at a time until the dialog has gone (within 1 s), calling
/// [check] before each pump.
Future<void> untilDialogGone(WidgetTester tester, void Function() check) async {
  for (var i = 0; find.byType(AlertDialog).evaluate().isNotEmpty; i++) {
    expect(i, lessThan(100), reason: 'the dialog should be gone within 1 s');
    check();
    await tester.pump(const Duration(milliseconds: 10));
  }
}

/// Pumps until the dialog has gone, checking meanwhile that no result
/// shows: it would come back with the page, in the update in which the
/// dialog goes, and TalkBack would skip it (see LiveRegionAnnouncements).
Future<void> noResultUntilDialogGone(WidgetTester tester) => untilDialogGone(
    tester, () => expect(resultFinder, findsNothing));

/// The text of the result under the buttons; fails if there is none.
String resultText(WidgetTester tester) =>
    tester.widget<Text>(resultFinder).data!;

/// Whether the result is marked as a failure (an error icon, in the error
/// colour); fails if there is no result.
bool resultIsError(WidgetTester tester) {
  final text = tester.widget<Text>(resultFinder);
  final icon = find.byIcon(Icons.error_outline);
  final colors = Theme.of(tester.element(resultFinder)).colorScheme;
  final bIcon = icon.evaluate().isNotEmpty;
  // The icon and the colour go together.
  expect(text.style?.color == colors.error, bIcon,
      reason: 'error colour without the icon, or the other way round');
  if (bIcon) expect(tester.widget<Icon>(icon).color, colors.error);
  return bIcon;
}

Future<String?> storedLedgerJson() async =>
    (await SharedPreferences.getInstance()).getString(kLedgerPrefsKey);

Future<Ledger> storedLedger() async => Ledger.decode(await storedLedgerJson());

/// The fakes of an unfinished Create saved with the ledger, if any.
Future<PendingCreate?> storedPending() async =>
    Ledger.decodeWithPending(await storedLedgerJson()).pending;

/// The status line's text, or null if it is empty.
String? statusText(WidgetTester tester) {
  final text = tester.widget<Text>(find.byKey(const Key('Status'))).data!;
  return text.isEmpty ? null : text;
}

/// The app goes to the background and comes back.
Future<void> leaveAndReturn(WidgetTester tester) async {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
  await tester.pumpAndSettle();
}

bool buttonsEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('Create'))).enabled &&
    tester.widget<OutlinedButton>(find.byKey(const Key('Delete'))).enabled;

/// Answers the permission request only when [answer] is completed.
class _SlowPermission extends InMemoryContactsGateway {
  final Completer<PermissionAnswer> answer = Completer();

  @override
  Future<PermissionAnswer> requestPermission() {
    permissionRequests++;
    return answer.future;
  }
}

/// Opening the settings finishes only when [opened] is completed.
class _SlowSettings extends InMemoryContactsGateway {
  final Completer<void> opened = Completer();

  @override
  Future<void> openSettings() async {
    await super.openSettings();
    await opened.future;
  }
}

/// Asking for the permission throws, as the plugin does while another
/// request is open, until [fail] is cleared.
class _FailingPermission extends InMemoryContactsGateway {
  bool fail = true;

  @override
  Future<PermissionAnswer> requestPermission() {
    if (fail) {
      permissionRequests++;
      throw Exception('Another permission request is in progress');
    }
    return super.requestPermission();
  }
}

/// The first time the address book is read, the answer waits until
/// [firstRead] is completed; later reads answer at once.
class _SlowFirstRead extends InMemoryContactsGateway {
  final Completer<void> firstRead = Completer();
  var _reads = 0;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final found = await super.getAll(ids: ids); // as it was when asked
    if (_reads++ == 0) await firstRead.future;
    return found;
  }
}

/// Reading the address book fails once something has been deleted.
class _FailsAfterDelete extends InMemoryContactsGateway {
  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) {
    if (deleteAllCalls.isNotEmpty) throw Exception('busy syncing');
    return super.getAll(ids: ids);
  }
}

/// The first read of the address book after something was deleted waits
/// until [held] is completed.
class _HoldsReadAfterDelete extends InMemoryContactsGateway {
  final Completer<void> held = Completer();
  var _holding = false;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    if (deleteAllCalls.isEmpty || _holding) return super.getAll(ids: ids);
    _holding = true;
    final found = await super.getAll(ids: ids);
    await held.future;
    return found;
  }
}

/// When creating or deleting fails, reading the address book fails too,
/// until [getAllError] is cleared.
class _ReadsFailAfterError extends InMemoryContactsGateway {
  @override
  Future<List<String>> createAll(List<NewContact> contacts) async {
    try {
      return await super.createAll(contacts);
    } catch (_) {
      getAllError = Exception('provider gone');
      rethrow;
    }
  }

  @override
  Future<void> deleteAll(List<String> contactIds) async {
    try {
      return await super.deleteAll(contactIds);
    } catch (_) {
      getAllError = Exception('provider gone');
      rethrow;
    }
  }
}

/// While [empty] is set, the address book reads as empty, as when the
/// contacts provider is missing.
class _ReadsEmpty extends InMemoryContactsGateway {
  bool empty = false;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async =>
      empty ? [] : await super.getAll(ids: ids);
}

/// Looking up the new contacts after creating them fails; reading them all
/// works.
class _LookupFails extends InMemoryContactsGateway {
  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) {
    if (ids != null) throw Exception('lookup failed');
    return super.getAll(ids: ids);
  }
}

/// Can't find the first new contact when looking them up after creating
/// them (as when Android links it with another contact meanwhile, which
/// changes its contact ID); with [hideEverywhere], not in any read.
class _LosesFirstNewContact extends InMemoryContactsGateway {
  bool hideEverywhere = false;
  String? _lost;

  @override
  Future<List<StoredContact>> getAll({List<String>? ids}) async {
    final found = await super.getAll(ids: ids);
    if (ids != null) _lost ??= ids.first;
    if (ids == null && !hideEverywhere) return found;
    return found.where((c) => c.id != _lost).toList();
  }
}

/// The focus rings shown, in global coordinates.
List<(Rect, OutlinedBorder)> rings(WidgetTester tester) => [
      for (final ring
          in tester.renderObjectList<RenderFocusRing>(find.byType(FocusRing)))
        if (ring.ringRect case final Rect rect)
          (
            MatrixUtils.transformRect(ring.getTransformTo(null), rect),
            ring.shape!,
          ),
    ];

/// Expects one focus ring on screen, 5 dp outside [button] as drawn
/// (its Material) all round: not around the taller tap target.
void expectRingAround(WidgetTester tester, Finder button) {
  final shown = rings(tester);
  expect(shown, hasLength(1));
  final drawn = tester.getRect(
      find.descendant(of: button, matching: find.byType(Material)).first);
  expect(drawn.height, lessThan(tester.getSize(button).height),
      reason: 'the tap target is taller than the button');
  final (rect, shape) = shown.single;
  expect(rect, drawn.inflate(FocusRing.outset));
  expect(shape, isA<StadiumBorder>());
  expect(shape.side.width, 3);
  expect(shape.side.color,
      Theme.of(tester.element(button)).colorScheme.secondary);
}

/// The app bar's menu button (⋮).
final Finder menu = find.byKey(const Key('Menu'));

/// Whether the keyboard focus is on the menu button.
bool menuFocused(WidgetTester tester) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final button = tester.element(menu);
  var bFound = false;
  focused.visitAncestorElements((e) => !(bFound = e == button));
  return bFound;
}

/// Expects one focus ring on screen, just inside the edge of [item].
void expectRingInside(WidgetTester tester, Finder item) {
  final shown = rings(tester);
  expect(shown, hasLength(1));
  final (rect, shape) = shown.single;
  expect(rect, tester.getRect(item));
  expect(shape, isA<RoundedRectangleBorder>());
  expect(shape.side.width, 3);
  expect(shape.side.color,
      Theme.of(tester.element(item)).colorScheme.secondary);
}

FocusNode focusOf(WidgetTester tester, String key) =>
    Focus.of(tester.element(find.descendant(
        of: find.byKey(Key(key)), matching: find.byType(Text))));

/// The label of the button with the keyboard focus, or null if none
/// has it.
String? focusedButton() {
  final focus = FocusManager.instance.primaryFocus;
  final button = focus is FocusScopeNode
      ? null
      : focus?.context?.findAncestorWidgetOfExactType<TextButton>() ??
          focus?.context?.findAncestorWidgetOfExactType<FilledButton>() ??
          focus?.context?.findAncestorWidgetOfExactType<OutlinedButton>();
  final child = button?.child;
  return child is Text ? child.data : (child is Semantics
      ? (child.child as Text?)?.data
      : null);
}

void main() {
  late InMemoryContactsGateway book;

  /// What logError wrote, instead of Android's log.
  late List<String> logged;

  setUp(() {
    setPrefs();
    book = InMemoryContactsGateway();
    logged = [];
    final previous = errorLogSink;
    errorLogSink = logged.add;
    addTearDown(() => errorLogSink = previous);
  });

  group('Create', () {
    testWidgets('creates every combination and records each in the ledger',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(book.displayNames, unorderedEquals(kFakeNames));
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zen');
      expect(zoe.phones, [fakeEntry('Zoe', 'Zen').phone]);
      expect(zoe.emails, ['Zoe.Zen@example.com']);

      final ledger = await storedLedger();
      expect(ledger.length, 4);
      for (final c in book.all) {
        final entry = ledger.entries[c.rawContactIds.single]!;
        final names = c.displayName.split(' ');
        expect(entry, fakeEntry(names[0], names[1]));
      }
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('a second Create adds no duplicates', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerAfterFirst = await storedLedgerJson();

      await tapExpectingNoDialog(tester, kCreateButton);

      expect(resultText(tester), 'Nothing to create. 4 fake contacts already exist.');
      expect(book.all, hasLength(4));
      expect(book.createAllCalls, hasLength(1));
      expect(await storedLedgerJson(), ledgerAfterFirst);
    });

    testWidgets('Create after editing the names adds only the new ones',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      await tester.enterText(find.byKey(const Key('FirstNames')), 'Zoe, Zach, Zelda');
      await tapCreate(tester);

      expect(resultText(tester), 'Created 2 fake contacts. 4 already existed.');
      expect(book.displayNames,
          unorderedEquals([...kFakeNames, 'Zelda Zen', 'Zelda Zima']));
      expect((await storedLedger()).length, 6);
    });

    testWidgets('skips a contact identical to a fake even if the ledger is lost',
        (tester) async {
      final e = fakeEntry('Zoe', 'Zen');
      final existing = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 3 fake contacts. 1 already existed.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(1));
      // Not tracked, so Delete will never touch it.
      final ledger = await storedLedger();
      expect(ledger.length, 3);
      expect(ledger.entries.containsKey(book.rawIdsOf(existing).single), isFalse);
    });

    testWidgets('a real contact with a fake\'s name but other details is kept '
        'out of the ledger', (tester) async {
      final real = book.add('Zoe Zen', phones: ['+1 555 0100']);
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.length, 4);
      expect(ledger.entries.containsKey(book.rawIdsOf(real).single), isFalse);
    });

    testWidgets('a fake merged into an existing contact is recorded, but only '
        'its own raw contact', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      book.mergeInto = (c) => c.first == 'Zoe' && c.last == 'Zen' ? alice : null;
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      final raws = book.rawIdsOf(alice);
      expect(raws, hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.length, 4);
      expect(ledger.entries.containsKey(raws[0]), isFalse); // Alice's own
      expect(ledger.entries[raws[1]], fakeEntry('Zoe', 'Zen'));
    });

    testWidgets('a new contact not found under its contact ID is found by '
        'its details (U8)', (tester) async {
      final lossy = _LosesFirstNewContact();
      await pumpApp(tester, lossy);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect((await storedLedger()).length, 4);
    });

    testWidgets("warns about created contacts it couldn't record",
        (tester) async {
      // Hidden from every read, so not even its details find it.
      final lossy = _LosesFirstNewContact()..hideEverywhere = true;
      await pumpApp(tester, lossy);
      await tapCreate(tester);

      expect(resultText(tester),
          'Created 4 fake contacts. Warning: 1 could not be recorded and '
          'must be deleted by hand.');
      expect(lossy.all, hasLength(4));
      expect((await storedLedger()).length, 3);
    });

    testWidgets('permission denied: nothing is read or created', (tester) async {
      book.permission = PermissionAnswer.denied;
      await pumpApp(tester, book);
      await tapExpectingNoDialog(tester, kCreateButton);

      expect(resultText(tester), kDenied);
      expect(book.permissionRequests, 1);
      expect(book.getAllCalls, 0);
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while creating is shown and nothing is recorded',
        (tester) async {
      book.createAllError = Exception('disk full');
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), kCreateFailed);
      expect(book.all, isEmpty);
      expect((await storedLedger()).isEmpty, isTrue);
      // None found; they stay pending in case the read was wrong.
      expect((await storedPending())!.entries, hasLength(4));
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while reading the address book is shown',
        (tester) async {
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);
      await tapExpectingNoDialog(tester, kCreateButton);

      // It happened before anything was created, and the message says so.
      expect(resultText(tester), kReadFailed);
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
    });

    testWidgets('taps while busy are ignored', (tester) async {
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      expect(buttonsEnabled(tester), isFalse);
      await tester.tap(find.text(kCreateButton), warnIfMissed: false);
      await tester.tap(find.text(kDeleteButton), warnIfMissed: false);
      await tester.pump();

      slow.answer.complete(PermissionAnswer.granted);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(slow.permissionRequests, 1);
      expect(slow.createAllCalls, hasLength(1));
      expect(slow.deleteAllCalls, isEmpty);
      expect(resultText(tester), 'Created 4 fake contacts.');
    });
  });

  group('Delete', () {
    testWidgets('removes the fakes and leaves real contacts alone',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      book.add('Zoe Zen', phones: ['+1 555 0100'], emails: ['zoe@real.test']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      expect(book.all, hasLength(6));

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
      expect(book.all.firstWhere((c) => c.displayName == 'Zoe Zen').phones,
          ['+1 555 0100']);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    testWidgets('a second Delete finds nothing to delete', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapDelete(tester);
      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(resultText(tester), 'No fake contacts to delete.');
      expect(book.all, isEmpty);
    });

    testWidgets('leaves a fake that was merged with a real contact',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zach = book.idOf('Zach Zen');
      final zachRaw = book.rawIdsOf(zach).single;
      book.merge(into: alice, from: zach);

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(book.displayNames, ['Alice Example']);
      expect(book.rawIdsOf(alice), hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.entries.keys, [zachRaw]);
    });

    testWidgets('leaves a fake that Android merged into a real contact '
        'when it was created', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      book.mergeInto = (c) => c.first == 'Zoe' && c.last == 'Zen' ? alice : null;
      await pumpApp(tester, book);
      await tapCreate(tester);

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(book.displayNames, ['Alice Example']);
      expect(book.rawIdsOf(alice), hasLength(2));
    });

    testWidgets('leaves a fake that was edited since', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zoe = book.idOf('Zoe Zen');
      book.setPhones(zoe, ['+1 555 0199']);

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(book.displayNames, ['Zoe Zen']);
      expect((await storedLedger()).entries.keys, book.rawIdsOf(zoe));
    });

    testWidgets('forgets fakes the user already deleted by hand',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]);

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.');
      expect(book.all, isEmpty);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    group('ledger that no longer matches (S1)', () {
      testWidgets('a ledger from another phone deletes nothing',
          (tester) async {
        // The ledger's raw IDs belong to real contacts on this phone.
        final alice = book.add('Alice Example', phones: ['+1 555 0101']);
        final bob = book.add('Bob Example', emails: ['bob@real.test']);
        final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
        setPrefs(ledger: {
          book.rawIdsOf(alice).single: fakeEntry('Zoe', 'Zen').toJson(),
          book.rawIdsOf(bob).single: fakeEntry('Zach', 'Zen').toJson(),
          book.rawIdsOf(zoe).single: fakeEntry('Zoe', 'Zen').toJson(),
        });
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(resultText(tester), 'No fake contacts to delete.${someChanged(3)}');
        expect(book.displayNames,
            unorderedEquals(['Alice Example', 'Bob Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, isEmpty);
        expect((await storedLedger()).length, 3);
      });

      testWidgets('old name-only entries pointing at real contacts delete '
          'nothing', (tester) async {
        final alice = book.add('Alice Example', phones: ['+1 555 0101']);
        final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
        setPrefs(ledger: {
          book.rawIdsOf(alice).single: 'Zoe Zen',
          book.rawIdsOf(zoe).single: 'Zoe Zen',
        });
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(resultText(tester), 'No fake contacts to delete.${someChanged(2)}');
        expect(book.displayNames, unorderedEquals(['Alice Example', 'Zoe Zen']));
        expect(book.deleteAllCalls, isEmpty);
        // Saved with the details they were checked against, even though
        // nothing was deleted.
        expect((await storedLedger()).entries.values,
            everyElement(fakeEntry('Zoe', 'Zen')));
      });

      testWidgets('once checked, name-only entries stay checked against the '
          'same details', (tester) async {
        final zoe = book.add('Zoe Zen',
            phones: ['+15550100'], emails: ['zoe@real.test']);
        setPrefs(ledger: {book.rawIdsOf(zoe).single: 'Zoe Zen'});
        await pumpApp(tester, book);
        await tapExpectingNoDialog(tester, kDeleteButton);
        expect(resultText(tester), 'No fake contacts to delete.$kOneChanged');

        // Templates that happen to give exactly the real contact's details.
        await tester.enterText(
            find.byKey(const Key('PhoneNumberTemplate')), '+15550100');
        await tester.enterText(
            find.byKey(const Key('EmailAddressTemplate')), 'zoe@real.test');
        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(resultText(tester), 'No fake contacts to delete.$kOneChanged');
        expect(book.all.map((c) => c.id), [zoe]);
        expect(book.deleteAllCalls, isEmpty);
      });

      testWidgets('old name-only entries for real fakes are still deleted',
          (tester) async {
        // Fakes made by an older version, which recorded only the name.
        final ledger = <String, Object>{};
        for (final (first, last) in [('Zoe', 'Zen'), ('Zach', 'Zima')]) {
          final e = fakeEntry(first, last);
          final id = book.add(e.name, phones: [e.phone!], emails: [e.email!]);
          ledger[book.rawIdsOf(id).single] = e.name;
        }
        final alice = book.add('Alice Example');
        setPrefs(ledger: ledger);
        await pumpApp(tester, book);

        await tapDelete(tester);

        expect(resultText(tester), 'Deleted 2 fake contacts.');
        expect(book.all.map((c) => c.id), [alice]);
      });

      testWidgets('entries for raw IDs that no longer exist are dropped',
          (tester) async {
        final alice = book.add('Alice Example');
        final gone = book.unusedRawId();
        setPrefs(ledger: {gone: fakeEntry('Zoe', 'Zen').toJson()});
        await pumpApp(tester, book);

        await tapExpectingNoDialog(tester, kDeleteButton);

        expect(resultText(tester), 'No fake contacts to delete.');
        expect(book.all.map((c) => c.id), [alice]);
        // Only a Create or Delete that runs drops it; asking doesn't.
        expect((await storedLedger()).entries.keys, [gone]);
        await tapAndAnswer(tester, kCreateButton, 'Cancel');
        expect((await storedLedger()).entries.keys, [gone]);
        await tapCreate(tester);
        expect((await storedLedger()).entries.keys, isNot(contains(gone)));
      });
    });

    testWidgets('permission denied: nothing is read or deleted',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.permission = PermissionAnswer.denied;
      final readsBefore = book.getAllCalls;

      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(resultText(tester), kDenied);
      expect(book.getAllCalls, readsBefore);
      expect(book.deleteAllCalls, isEmpty);
      expect(book.all, hasLength(4));
      expect(await storedLedgerJson(), ledgerBefore);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('an error while deleting is shown and the ledger is kept',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.deleteAllError = Exception('provider gone');

      await tapDelete(tester);

      expect(resultText(tester), kDeleteFailed);
      expect(book.all, hasLength(4));
      expect(await storedLedgerJson(), ledgerBefore);
      expect(buttonsEnabled(tester), isTrue);

      // Once the error is gone, Delete still works.
      book.deleteAllError = null;
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(book.all, isEmpty);
    });
  });

  group('errors (U6)', () {
    /// What the plugin reports when the contacts provider can't write.
    final kStorageFull = PlatformException(
        code: 'flutter_contacts_error',
        message: 'Failed to handle createAll: database or disk is full'
            ' (code 13 SQLITE_FULL)');

    const kStoppedCreating = 'Created 2 of 4 fake contacts, then something'
        ' went wrong. Try again to create the rest.';
    const kStoppedDeleting = 'Deleted 2 of 4 fake contacts, then something'
        ' went wrong. Try again to delete the rest.';

    testWidgets('a Create that stops partway records what it created, and '
        'trying again creates the rest', (tester) async {
      book.createAllError = Exception('provider gone');
      book.createAllStopsAfter = 2;
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), kStoppedCreating);
      expect(book.all, hasLength(2));
      final ledger = await storedLedger();
      expect(ledger.entries.keys,
          unorderedEquals([for (final c in book.all) ...c.rawContactIds]));
      expect(statusText(tester), '2 fake contacts on this phone.');
      expect(buttonsEnabled(tester), isTrue);

      book.createAllError = null;
      await tapCreate(tester);
      expect(resultText(tester), 'Created 2 fake contacts. 2 already existed.');
      expect(book.displayNames, unorderedEquals(kFakeNames));

      // All four are recorded, so Delete removes them all.
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(book.all, isEmpty);
    });

    testWidgets('a fake merged into a real contact before it stopped is '
        'recorded, and Delete leaves it alone', (tester) async {
      final alice = book.add('Zoe Zen', phones: ['+1 555 0101']);
      book.mergeInto = (c) => c.first == 'Zoe' && c.last == 'Zen' ? alice : null;
      book.createAllError = Exception('provider gone');
      book.createAllStopsAfter = 2;
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(resultText(tester), kStoppedCreating);
      expect((await storedLedger()).length, 2);

      book.createAllError = null;
      await tapCreate(tester);
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(book.rawIdsOf(alice), hasLength(2));
    });

    testWidgets("if what a failed Create did can't be read, it says to try "
        'again, and trying again records them', (tester) async {
      final failing = _ReadsFailAfterError();
      failing.createAllError = Exception('provider gone');
      failing.createAllStopsAfter = 2;
      await pumpApp(tester, failing);
      await tapCreate(tester);

      expect(resultText(tester),
          "Couldn't finish creating fake contacts. Try again.");
      expect(failing.all, hasLength(2));
      // Not recorded yet, but still pending.
      expect((await storedLedger()).isEmpty, isTrue);
      expect((await storedPending())!.entries, hasLength(4));
      expect(buttonsEnabled(tester), isTrue);

      // Trying again records the two, and creates the rest.
      failing.createAllError = null;
      failing.getAllError = null;
      await tapCreate(tester);
      expect(resultText(tester), 'Created 2 fake contacts. 2 already existed.');
      expect((await storedLedger()).length, 4);
      expect(await storedPending(), isNull);
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(failing.all, isEmpty);
    });

    testWidgets('a Create that created everything before failing says so',
        (tester) async {
      final failing = _LookupFails();
      await pumpApp(tester, failing);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect((await storedLedger()).length, 4);
      expect(logged.single, contains('lookup failed'));

      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(failing.all, isEmpty);
    });

    testWidgets('a Delete that stops partway says how many it deleted, and '
        'trying again deletes the rest', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      book.deleteAllError = Exception('provider gone');
      book.deleteAllStopsAfter = 2;

      await tapDelete(tester);
      expect(resultText(tester), kStoppedDeleting);
      expect(book.all, hasLength(2));
      expect(statusText(tester), '2 fake contacts on this phone.');
      // The ledger is left as it was: entries for the deleted ones do no
      // harm.
      expect(await storedLedgerJson(), ledgerBefore);

      book.deleteAllError = null;
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 2 fake contacts?');
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();
      expect(resultText(tester), 'Deleted 2 fake contacts.');
      expect(book.all, isEmpty);
      expect((await storedLedger()).isEmpty, isTrue);
    });

    testWidgets('a failed Create keeps the ledger even if the address book '
        'reads as empty', (tester) async {
      // With the contacts provider missing, reads find nothing rather than
      // failing, so nothing must be dropped for not being found.
      final broken = _ReadsEmpty();
      await pumpApp(tester, broken);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();

      broken.empty = true;
      broken.createAllError = Exception('Unknown authority');
      await tapCreate(tester);
      expect(resultText(tester), kCreateFailed);
      expect((await storedLedger()).entries,
          Ledger.decode(ledgerBefore).entries);

      broken.empty = false;
      broken.createAllError = null;
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
    });

    testWidgets("if what a failed Delete did can't be read, it says so",
        (tester) async {
      final failing = _ReadsFailAfterError();
      await pumpApp(tester, failing);
      await tapCreate(tester);
      final ledgerBefore = await storedLedgerJson();
      failing.deleteAllError = Exception('provider gone');
      failing.deleteAllStopsAfter = 2;

      await tapDelete(tester);
      expect(resultText(tester),
          "Couldn't finish deleting fake contacts. Try again.");
      expect(failing.all, hasLength(2));
      expect(await storedLedgerJson(), ledgerBefore);
      expect(buttonsEnabled(tester), isTrue);

      // The ledger still lists the deleted ones, which does no harm.
      failing.deleteAllError = null;
      failing.getAllError = null;
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 2 fake contacts?');
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();
      expect(resultText(tester), 'Deleted 2 fake contacts.');
      expect(failing.all, isEmpty);
    });

    testWidgets('with the storage full, it says so instead of "Try again"',
        (tester) async {
      book.createAllError = kStorageFull;
      book.createAllStopsAfter = 2;
      await pumpApp(tester, book);
      await tapCreate(tester);
      expect(resultText(tester),
          'Created 2 of 4 fake contacts before your phone ran out of storage.');
      expect((await storedLedger()).length, 2);

      book.createAllStopsAfter = null;
      await tapCreate(tester);
      expect(resultText(tester),
          "Couldn't create fake contacts: your phone's storage is full.");

      book.deleteAllError = kStorageFull;
      await tapDelete(tester);
      expect(resultText(tester),
          "Couldn't delete fake contacts: your phone's storage is full.");
      expect(book.all, hasLength(2));
    });

    testWidgets("found, but the ledger couldn't be saved: it says the storage "
        'is full, and Delete can remove them (U8)', (tester) async {
      // The storage is full: the ledger is kept in memory but not written.
      book.createAllError = kStorageFull;
      book.createAllStopsAfter = 2;
      // The ledger is saved before the call, but not after it.
      await pumpApp(tester, book,
          ledgerStore: FailingLedgerStore(2, succeeding: 1));
      await tapCreate(tester);

      expect(resultText(tester),
          'Created 2 of 4 fake contacts before your phone ran out of storage.');
      expect(statusText(tester), '2 fake contacts on this phone.');

      book.createAllError = null;
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 2 fake contacts.');
      expect(book.all, isEmpty);
    });

    testWidgets('the log keeps the details the message leaves out',
        (tester) async {
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);
      logged.clear(); // the status line's count failed too
      await tapExpectingNoDialog(tester, kCreateButton);

      expect(resultText(tester), kReadFailed);
      expect(logged.single, contains('_createAllContacts, preview'));
      expect(logged.single, contains('Exception: no provider'));
      // With the stack trace.
      expect(logged.single, contains('previewCreate'));
    });

    testWidgets('the log keeps what stopped a Create partway, and where',
        (tester) async {
      book.createAllError = Exception('provider gone');
      book.createAllStopsAfter = 2;
      await pumpApp(tester, book);
      await tapCreate(tester);

      expect(logged.single,
          startsWith('Fake Contacts: _createAllContacts, stopped after 2 of 4:'
              ' Exception: provider gone\n'));
      expect(logged.single, contains('InMemoryContactsGateway.createAll'));
    });

    testWidgets('a failed status count is logged but not shown',
        (tester) async {
      setPrefs(ledger: {'1': fakeEntry('Zoe', 'Zen').toJson()}); // so it reads
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);

      expect(statusText(tester), isNull);
      expect(resultFinder, findsNothing);
      expect(logged.single, contains('_refreshStatus'));
      expect(logged.single, contains('Exception: no provider'));
    });
  });

  group('asks before acting (U1)', () {
    /// Checks that nothing at all happened.
    Future<void> expectUntouched(WidgetTester tester,
        {required int contacts, String? ledgerJson}) async {
      expect(find.byType(AlertDialog), findsNothing);
      expect(resultFinder, findsNothing);
      expect(book.all, hasLength(contacts));
      expect(await storedLedgerJson(), ledgerJson);
      expect(buttonsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    testWidgets('Create says how many it will add; Cancel adds none',
        (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);

      expect(dialogText(tester),
          (title: 'Create 4 fake contacts?', body: kCreateBody));
      // Nothing is created before the answer, and there's no spinner.
      expect(book.createAllCalls, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(buttonsEnabled(tester), isFalse);

      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 0);
      expect(book.createAllCalls, isEmpty);
    });

    testWidgets('tapping outside the dialog cancels', (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 0);
    });

    testWidgets('Back cancels', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledger = await storedLedgerJson();
      await tapAndOpenDialog(tester, kDeleteButton);
      // The result of Create doesn't linger under the dialog.
      expect(resultFinder, findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 4, ledgerJson: ledger);
      expect(book.deleteAllCalls, isEmpty);
      // Still works afterwards.
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
    });

    testWidgets('Create counts only the new ones', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tester.enterText(find.byKey(const Key('FirstNames')), 'Zoe, Zach, Zelda');

      await tapAndOpenDialog(tester, kCreateButton);

      expect(dialogText(tester), (
        title: 'Create 2 fake contacts?',
        body: '4 already exist and will be skipped. $kCreateBody',
      ));
    });

    testWidgets('with an empty name list, Create is disabled and the preview '
        'says why (U4)', (tester) async {
      await pumpApp(tester, book);
      bool createEnabled() =>
          tester.widget<FilledButton>(find.byKey(const Key('Create'))).enabled;
      bool deleteEnabled() =>
          tester.widget<OutlinedButton>(find.byKey(const Key('Delete'))).enabled;
      String preview() =>
          tester.widget<Text>(find.byKey(const Key('Preview'))).data!;
      expect(createEnabled(), isTrue);

      for (final (key, text, hint) in [
        ('LastNames', ' , ', 'Enter at least one last name.'),
        ('FirstNames', '', 'Enter at least one last name and one first name.'),
        ('LastNames', 'Zen', 'Enter at least one first name.'),
      ]) {
        await tester.enterText(find.byKey(Key(key)), text);
        await tester.pump();
        expect(createEnabled(), isFalse, reason: '$key "$text"');
        expect(preview(), endsWith('\n$hint'));
        // Delete doesn't need names.
        expect(deleteEnabled(), isTrue);
      }

      await tester.tap(find.text(kCreateButton), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(resultFinder, findsNothing);
      expect(book.permissionRequests, 0);

      await tester.enterText(find.byKey(const Key('FirstNames')), 'Zoe');
      await tester.pump();
      expect(createEnabled(), isTrue);
      await tapCreate(tester);
      expect(book.displayNames, ['Zoe Zen']);
    });

    testWidgets('Delete says how many it will delete; Cancel deletes none',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledger = await storedLedgerJson();

      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester),
          (title: 'Delete 4 fake contacts?', body: kDeleteBody));
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      await expectUntouched(tester, contacts: 5, ledgerJson: ledger);
      expect(book.deleteAllCalls, isEmpty);
    });

    testWidgets('Delete says which ones it will leave alone', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zach Zen'));
      book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);

      await tapAndOpenDialog(tester, kDeleteButton);

      expect(dialogText(tester), (
        title: 'Delete 2 fake contacts?',
        body: '$kDeleteBody 1 was merged with another contact and will be '
            "left alone. 1 no longer matches what this app created (edited, "
            "or the app's records came from another phone) and will be left "
            'alone.',
      ));
    });

    testWidgets('a fake edited while the dialog is open is not deleted',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 4 fake contacts?');

      final zoe = book.idOf('Zoe Zen');
      book.setPhones(zoe, ['+1 555 0199']);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(book.displayNames, ['Zoe Zen']);
      expect(book.all.single.phones, ['+1 555 0199']);
    });

    testWidgets('Create while the dialog is open checks again for duplicates',
        (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');

      // Meanwhile one of them appears, e.g. from a sync.
      final e = fakeEntry('Zoe', 'Zen');
      book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(resultText(tester), 'Created 3 fake contacts. 1 already existed.');
      expect(book.displayNames.where((n) => n == 'Zoe Zen'), hasLength(1));
    });

    testWidgets('Create does no more than the dialog said', (tester) async {
      // Identical to a fake, so Create asks about only 3.
      final e = fakeEntry('Zoe', 'Zen');
      final copy = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 3 fake contacts?');

      // Meanwhile it goes away, so there would now be 4 to create.
      await book.deleteAll([copy]);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(resultText(tester),
          'Your contacts changed meanwhile, so nothing was done. Try again.');
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
      expect(buttonsEnabled(tester), isTrue);
      // Asking again gives the new count.
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');
    });

    testWidgets('Delete does no more than the dialog said', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final zoe = book.idOf('Zoe Zen');
      final phone = book.all.firstWhere((c) => c.id == zoe).phones;
      book.setPhones(zoe, ['+1 555 0199']);
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 3 fake contacts?');

      // Meanwhile the edit is undone, so all 4 would now be deleted.
      book.setPhones(zoe, phone);
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(resultText(tester),
          'Your contacts changed meanwhile, so nothing was done. Try again.');
      expect(book.deleteAllCalls, isEmpty);
      expect(book.all, hasLength(4));
      expect((await storedLedger()).length, 4);
    });

    testWidgets('an error while deleting after confirming is shown',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tapAndOpenDialog(tester, kDeleteButton);
      book.getAllError = Exception('provider gone');

      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();

      expect(resultText(tester), kDeleteFailed);
      expect(book.deleteAllCalls, isEmpty);
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('Delete with nothing to delete says why instead of asking',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      for (final name in ['Zach Zen', 'Zoe Zima', 'Zach Zima']) {
        await book.deleteAll([book.idOf(name)]);
      }
      book.merge(into: alice, from: book.idOf('Zoe Zen'));

      await tapExpectingNoDialog(tester, kDeleteButton);

      expect(resultText(tester), 'No fake contacts to delete.$kOneMerged');
      expect(book.deleteAllCalls, hasLength(3)); // only the ones above
    });
  });

  group('status line (U3)', () {
    /// Adds fakes made by this app (as [fakeEntry] gives them) and returns
    /// a ledger that records them.
    Map<String, Object> addFakes(List<(String, String)> names) => {
          for (final (first, last) in names)
            book.rawIdsOf(book.add('$first $last',
                    phones: [fakeEntry(first, last).phone!],
                    emails: [fakeEntry(first, last).email!])).single:
                fakeEntry(first, last).toJson(),
        };

    testWidgets('shows the count at startup without asking for permission',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      setPrefs(ledger: addFakes([('Zoe', 'Zen'), ('Zach', 'Zima')]));
      final ledger = await storedLedgerJson();
      await pumpApp(tester, book);

      expect(statusText(tester), '2 fake contacts on this phone.');
      expect(book.permissionChecks, greaterThan(0));
      expect(book.permissionRequests, 0);
      expect(await storedLedgerJson(), ledger);
    });

    testWidgets('one, and none', (tester) async {
      setPrefs(ledger: addFakes([('Zoe', 'Zen')]));
      await pumpApp(tester, book);
      expect(statusText(tester), '1 fake contact on this phone.');

      await tapDelete(tester);

      expect(statusText(tester), 'No fake contacts on this phone.');
    });

    testWidgets('without the permission there is none, and it is not asked '
        'for', (tester) async {
      book.alreadyGranted = false;
      await pumpApp(tester, book);

      expect(statusText(tester), isNull);
      expect(book.permissionRequests, 0);
      expect(book.getAllCalls, 0);

      // Granted when the user taps Create.
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('follows Create, Cancel and Delete', (tester) async {
      await pumpApp(tester, book);
      expect(statusText(tester), 'No fake contacts on this phone.');

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // One is deleted by hand while the dialog is open; Cancel still
      // updates the count.
      await tapAndOpenDialog(tester, kDeleteButton);
      await book.deleteAll([book.idOf('Zoe Zen')]);
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();
      expect(statusText(tester), '3 fake contacts on this phone.');

      await tapDelete(tester);
      expect(statusText(tester), 'No fake contacts on this phone.');
    });

    testWidgets('the buttons stay put when it appears', (tester) async {
      book.alreadyGranted = false;
      await pumpApp(tester, book);
      final before = tester.getCenter(find.text(kDeleteButton));

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      expect(tester.getCenter(find.text(kDeleteButton)), before);
    });

    testWidgets('counts neither fakes merged into other contacts nor ones '
        'that no longer match', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zach Zen'));
      book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);

      await leaveAndReturn(tester);

      expect(statusText(tester), '2 fake contacts on this phone.');
    });

    testWidgets('a ledger entry landing on part of a real contact is not '
        'counted (S1)', (tester) async {
      // A real contact made of two raw contacts (e.g. two accounts); a
      // ledger from another phone names one of them.
      final bob = book.add('Bob Example', phones: ['+1 555 0102']);
      book.merge(into: bob, from: book.add('Bob Example'));
      setPrefs(ledger: {
        book.rawIdsOf(bob).first: fakeEntry('Zoe', 'Zen').toJson(),
      });
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
    });

    testWidgets('with an empty ledger the address book is not read',
        (tester) async {
      book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts on this phone.');
      expect(book.getAllCalls, 0);
    });

    testWidgets('a fake merged into a real contact: none to delete, but not '
        '"none on this phone"', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      book.merge(into: alice, from: book.idOf('Zoe Zen'));

      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(statusText(tester), 'No fake contacts this app can delete.');
    });

    testWidgets('a ledger pointing at real contacts counts none (S1)',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      final zoe = book.add('Zoe Zen', phones: ['+1 555 0100']);
      setPrefs(ledger: {
        book.rawIdsOf(alice).single: fakeEntry('Zoe', 'Zen').toJson(),
        book.rawIdsOf(zoe).single: 'Zoe Zen',
      });
      final ledger = await storedLedgerJson();
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
      // Counting changes nothing, not even old name-only entries.
      expect(await storedLedgerJson(), ledger);
    });

    testWidgets('updates when the app comes back to the foreground',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]); // by hand, in another app

      await leaveAndReturn(tester);

      expect(statusText(tester), '3 fake contacts on this phone.');
    });

    testWidgets('only after the app was in the background, not after the '
        'notification shade', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await book.deleteAll([book.idOf('Zoe Zen')]);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(statusText(tester), '4 fake contacts on this phone.');

      await leaveAndReturn(tester);
      expect(statusText(tester), '3 fake contacts on this phone.');
    });

    testWidgets('a failed update right after an action shows no count',
        (tester) async {
      final failing = _FailsAfterDelete();
      await pumpApp(tester, failing);
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // One is edited, so it stays in the ledger and the count after Delete
      // has to read the address book. Delete works; that read fails.
      failing.setPhones(failing.idOf('Zoe Zen'), ['+1 555 0199']);
      await tapDelete(tester);

      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(failing.displayNames, ['Zoe Zen']);
      expect(statusText(tester), isNull);
    });

    testWidgets('a failed update that overtakes the one after an action '
        'shows no count either', (tester) async {
      final holding = _HoldsReadAfterDelete();
      await pumpApp(tester, holding);
      await tapCreate(tester);
      holding.setPhones(holding.idOf('Zoe Zen'), ['+1 555 0199']);
      await tapDelete(tester); // its count afterwards is now waiting
      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneChanged');
      expect(statusText(tester), '4 fake contacts on this phone.');

      // The user leaves and comes back; that count fails.
      holding.getAllError = Exception('busy syncing');
      await leaveAndReturn(tester);
      expect(statusText(tester), isNull);

      // The count from after Delete arrives last and is out of date.
      holding.held.complete();
      await tester.pumpAndSettle();
      expect(statusText(tester), isNull);
    });

    testWidgets('old name-only entries are not counted, whatever the '
        'templates say', (tester) async {
      // A fake from an older version, which recorded only the name. Its
      // details match the current settings, so Delete would delete it.
      final e = fakeEntry('Zoe', 'Zen');
      final zoe = book.add('Zoe Zen', phones: [e.phone!], emails: [e.email!]);
      setPrefs(ledger: {book.rawIdsOf(zoe).single: 'Zoe Zen'});
      await pumpApp(tester, book);

      expect(statusText(tester), 'No fake contacts this app can delete.');
      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 1 fake contact?');
    });

    testWidgets('a failed update keeps the last count', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);

      book.getAllError = Exception('busy syncing');
      await leaveAndReturn(tester);

      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('disappears if the permission is taken away', (tester) async {
      await pumpApp(tester, book);
      expect(statusText(tester), isNotNull);

      book.alreadyGranted = false; // in the system settings
      await leaveAndReturn(tester);

      expect(statusText(tester), isNull);
    });

    testWidgets('an error while counting shows none, and the app still works',
        (tester) async {
      setPrefs(ledger: addFakes([('Zoe', 'Zen')])); // so it reads
      book.getAllError = Exception('no provider');
      await pumpApp(tester, book);
      expect(tester.takeException(), isNull);
      expect(statusText(tester), isNull);

      book.getAllError = null;
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('a count that was still running when Create started is not '
        'shown', (tester) async {
      final slow = _SlowFirstRead();
      book = slow;
      setPrefs(ledger: addFakes([('Zoe', 'Zen')])); // so it reads
      await pumpApp(tester, slow); // the startup count is waiting
      expect(statusText(tester), isNull);

      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');

      // The startup count answers last, from before Create.
      slow.firstRead.complete();
      await tester.pumpAndSettle();
      expect(statusText(tester), '4 fake contacts on this phone.');
    });
  });
  group('preview under the fields (U2)', () {
    String? previewText(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('Preview'))).data;

    testWidgets('its count is what Create asks about, and its example is a '
        'contact Create makes', (tester) async {
      await pumpApp(tester, book);
      expect(previewText(tester),
          '2 last names × 2 first names = 4 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');

      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 4 fake contacts?');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zen');
      expect(zoe.phones, ['+447700900010']);
      expect(zoe.emails, ['Zoe.Zen@example.com']);
    });

    testWidgets('an edit shows up in the next Create', (tester) async {
      await pumpApp(tester, book);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zhao');
      await tester.enterText(
          find.byKey(const Key('PhoneNumberTemplate')), '+447700900nnn ');
      await tester.enterText(
          find.byKey(const Key('EmailAddressTemplate')), 'LAST@example.org');
      await tester.pump();
      expect(previewText(tester),
          '1 last name × 2 first names = 2 fake contacts.\n'
          'For example: Zoe Zhao · +447700900047 · Zhao@example.org');

      // Straight away, before the edit is saved.
      await tapAndOpenDialog(tester, kCreateButton);
      expect(dialogText(tester).title, 'Create 2 fake contacts?');
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      final zoe = book.all.firstWhere((c) => c.displayName == 'Zoe Zhao');
      expect(zoe.phones, ['+447700900047']);
      expect(zoe.emails, ['Zhao@example.org']);
    });

    testWidgets('it is about the settings, not about the phone: Create, '
        'Cancel and Delete leave it as it was', (tester) async {
      await pumpApp(tester, book);
      final before = previewText(tester);

      await tapAndAnswer(tester, kCreateButton, 'Cancel');
      expect(previewText(tester), before);
      await tapCreate(tester);
      expect(previewText(tester), before);
      expect(statusText(tester), '4 fake contacts on this phone.');
      await tapDelete(tester);
      expect(previewText(tester), before);
    });

    testWidgets('Create and Delete close the keyboard, and the field '
        'doesn\'t take the focus back after the dialog', (tester) async {
      await pumpApp(tester, book);
      bool fieldFocused() => tester
          .widgetList<EditableText>(find.byType(EditableText))
          .any((e) => e.focusNode.hasFocus);

      for (final (button, answer) in [
        (kCreateButton, 'Cancel'),
        (kCreateButton, 'Create'),
        (kDeleteButton, 'Delete'),
      ]) {
        await tester.tap(find.byKey(const Key('EmailAddressTemplate')));
        await tester.pump();
        expect(fieldFocused(), isTrue);
        expect(tester.testTextInput.isVisible, isTrue);

        await tapAndOpenDialog(tester, button);
        await tester.tap(dialogButton(answer));
        await tester.pumpAndSettle();
        expect(fieldFocused(), isFalse, reason: '$button, $answer');
        expect(tester.testTextInput.isVisible, isFalse,
            reason: '$button, $answer');
        await tester.pumpAndSettle(const Duration(seconds: 5));
      }
      expect(book.all, isEmpty);
    });

    testWidgets('the fields are disabled while Create runs, so it always '
        'shows what Create is using', (tester) async {
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      const keys = ['LastNames', 'FirstNames', 'PhoneNumberTemplate',
          'EmailAddressTemplate'];
      List<bool> enabled() => [
            for (final k in keys)
              tester.widget<TextField>(find.byKey(Key(k))).enabled ?? true,
          ];
      expect(enabled(), everyElement(isTrue));
      final buttonAt = tester.getTopLeft(find.text(kDeleteButton));

      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      expect(enabled(), everyElement(isFalse), reason: 'asking for permission');
      // So it can't take the focus, and no keyboard opens by itself later.
      await tester.tap(find.byKey(const Key('EmailAddressTemplate')),
          warnIfMissed: false);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
      slow.answer.complete(PermissionAnswer.granted);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(enabled(), everyElement(isFalse), reason: 'dialog open');
      // Nothing moves behind the dialog.
      expect(tester.getTopLeft(find.text(kDeleteButton)), buttonAt);
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(enabled(), everyElement(isTrue));
      expect(slow.all, hasLength(4));
      expect(tester.testTextInput.isVisible, isFalse);
      expect(FocusManager.instance.primaryFocus?.context?.widget,
          isNot(isA<EditableText>()));
    });

    testWidgets('with a D-pad too, a field can\'t take the focus while '
        'Create runs', (tester) async {
      final slow = _SlowPermission();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Directional navigation, as with a D-pad or on Android TV, where a
      // disabled TextField can still take the focus.
      await tester.pumpWidget(MediaQuery(
          data: const MediaQueryData(navigationMode: NavigationMode.directional),
          child: MyApp(contacts: slow)));
      await tester.pumpAndSettle();
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      final email = tester
          .widget<EditableText>(find.descendant(
              of: find.byKey(const Key('EmailAddressTemplate')),
              matching: find.byType(EditableText)))
          .focusNode;

      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      email.requestFocus();
      await tester.pump();
      expect(email.hasFocus, isFalse);

      slow.answer.complete(PermissionAnswer.granted);
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      expect(slow.all, hasLength(4));
      expect(email.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('an error or a refused permission leaves it as it was',
        (tester) async {
      await pumpApp(tester, book);
      final before = previewText(tester);

      book.getAllError = Exception('no provider');
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), kReadFailed);
      expect(previewText(tester), before);

      book.getAllError = null;
      book.permission = PermissionAnswer.denied;
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), kDenied);
      expect(previewText(tester), before);
    });
  });

  group('permission permanently denied (U5)', () {
    const kTitle = 'Contacts access is off';
    String body(String verb) =>
        'To $verb fake contacts, this app needs access to your contacts.'
        ' In Settings, tap Permissions and allow Contacts.';

    setUp(() => book.permission = PermissionAnswer.permanentlyDenied);

    /// Checks that the dialog is gone and nothing else happened.
    void expectDone(WidgetTester tester) {
      expect(find.byType(AlertDialog), findsNothing);
      expect(resultFinder, findsNothing);
      expect(buttonsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    }

    testWidgets('Create offers the settings and opens them; nothing is read '
        'or created', (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);

      expect(dialogText(tester), (title: kTitle, body: body('create')));
      expect(dialogButton('Cancel'), findsOneWidget);
      // The app waits for the user: no spinner, and nothing else to tap.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(buttonsEnabled(tester), isFalse);
      expect(book.openSettingsCalls, 0);

      await tester.tap(dialogButton('Open settings'));
      await tester.pumpAndSettle();

      expect(book.openSettingsCalls, 1);
      expectDone(tester);
      expect(book.permissionRequests, 1);
      expect(book.getAllCalls, 0);
      expect(book.createAllCalls, isEmpty);
      expect(await storedLedgerJson(), isNull);
    });

    testWidgets('Delete offers them too; Cancel opens nothing',
        (tester) async {
      book.permission = PermissionAnswer.granted;
      await pumpApp(tester, book);
      await tapCreate(tester);
      final ledger = await storedLedgerJson();
      // Turned off in the system settings, after "Don't allow" twice.
      book.permission = PermissionAnswer.permanentlyDenied;
      book.alreadyGranted = false;
      final reads = book.getAllCalls;

      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester), (title: kTitle, body: body('delete')));
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();

      expectDone(tester);
      expect(book.openSettingsCalls, 0);
      expect(book.getAllCalls, reads);
      expect(book.deleteAllCalls, isEmpty);
      expect(book.all, hasLength(4));
      expect(await storedLedgerJson(), ledger);
    });

    testWidgets('Back and tapping outside the dialog open nothing either',
        (tester) async {
      await pumpApp(tester, book);
      for (final (how, dismiss) in [
        ('Back', () => tester.binding.handlePopRoute()),
        ('outside', () => tester.tapAt(const Offset(10, 10))),
      ]) {
        await tapAndOpenDialog(tester, kCreateButton);
        await dismiss();
        await tester.pumpAndSettle();
        expectDone(tester);
        expect(book.openSettingsCalls, 0, reason: how);
      }
      expect(book.permissionRequests, 2);
    });

    testWidgets('after allowing it in the settings, the status line shows '
        'and Create works', (tester) async {
      await pumpApp(tester, book);
      expect(statusText(tester), isNull);
      await tapAndAnswer(tester, kCreateButton, 'Open settings');

      // Allowed in the system settings, then back to the app.
      book.permission = PermissionAnswer.granted;
      book.alreadyGranted = true;
      await leaveAndReturn(tester);

      expect(statusText(tester), 'No fake contacts on this phone.');
      await tapCreate(tester);
      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(statusText(tester), '4 fake contacts on this phone.');
    });

    testWidgets('if the settings can\'t be opened, it says so',
        (tester) async {
      book.openSettingsError = Exception('no activity');
      await pumpApp(tester, book);

      await tapAndAnswer(tester, kCreateButton, 'Open settings');

      expect(book.openSettingsCalls, 1);
      expect(resultText(tester), "Couldn't open Settings.");
      expect(buttonsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('no spinner while the settings open: the app is going to '
        'the background, not working', (tester) async {
      final slow = _SlowSettings()
        ..permission = PermissionAnswer.permanentlyDenied;
      await pumpApp(tester, slow);
      await tapAndOpenDialog(tester, kCreateButton);
      await tester.tap(dialogButton('Open settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(slow.openSettingsCalls, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Until the settings are in front, a second tap can't ask again.
      expect(buttonsEnabled(tester), isFalse);
      slow.opened.complete();
      await tester.pumpAndSettle();
      expectDone(tester);
    });

    testWidgets('if asking fails, it says so, and the app still works',
        (tester) async {
      final failing = _FailingPermission();
      await pumpApp(tester, failing);

      await tapExpectingNoDialog(tester, kCreateButton);

      expect(resultText(tester),
          "Couldn't ask for permission to access contacts. Try again.");
      expect(buttonsEnabled(tester), isTrue);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(failing.getAllCalls, 0);
      failing.fail = false;
      await tapCreate(tester);
      expect(resultText(tester), 'Created 4 fake contacts.');
    });

    testWidgets('a plain denial (Android may still ask) gets the message, '
        'not the dialog', (tester) async {
      book.permission = PermissionAnswer.denied;
      await pumpApp(tester, book);
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), kDenied);
      expect(book.openSettingsCalls, 0);
    });
  });

  group('progress for big batches (U8)', () {
    /// Each create or delete call waits for its gate, the last one in
    /// [gates], to be opened.
    late List<Completer<void>> gates;

    Future<void> hold(int _) {
      final gate = Completer<void>();
      gates.add(gate);
      return gate.future;
    }

    /// Opens the gate of the call that is waiting, and lets the app go on to
    /// the next one (or the end).
    Future<void> release(WidgetTester tester) async {
      gates.last.complete();
      await tester.pumpAndSettle();
    }

    setUp(() => gates = []);

    String? progressText(WidgetTester tester) {
      final found = find.byKey(const Key('Progress'));
      return found.evaluate().isEmpty ? null : tester.widget<Text>(found).data;
    }

    double? barValue(WidgetTester tester) => tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
        .value;

    /// Stop, only while it can be seen: its space is always reserved.
    Finder stopButton(String label) =>
        find.widgetWithText(OutlinedButton, label).hitTestable();


    testWidgets('Create shows how far it got, with Stop, instead of the '
        'spinner', (tester) async {
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      final deleteAt = tester.getTopLeft(find.text(kDeleteButton));
      await tapCreate(tester);

      expect(progressText(tester), 'Created 0 of 4');
      expect(barValue(tester), 0);
      expect(stopButton('Stop'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(buttonsEnabled(tester), isFalse);
      // Only what is below the buttons moves.
      expect(tester.getTopLeft(find.text(kDeleteButton)), deleteAt);

      for (var i = 1; i <= 3; i++) {
        await release(tester);
        expect(progressText(tester), 'Created $i of 4');
        expect(barValue(tester), i / 4);
      }
      await release(tester);

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(resultIsError(tester), isFalse);
      expect(progressText(tester), isNull);
      expect(stopButton('Stop'), findsNothing);
      expect(buttonsEnabled(tester), isTrue);
      expect(statusText(tester), '4 fake contacts on this phone.');
      expect((await storedLedger()).length, 4);
    });

    testWidgets("TalkBack reads the count, without the bar's bare number, and "
        "isn't told of every change", (tester) async {
      final handle = tester.ensureSemantics();
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      await tapCreate(tester);
      await release(tester);

      final node = tester.getSemantics(find.byKey(const Key('Progress')));
      expect(node.label, 'Created 1 of 4');
      expect(node.value, isEmpty);
      expect(node.flagsCollection.isLiveRegion, isFalse);
      // No node anywhere reads the bar's number.
      final values = <String>[];
      bool collect(SemanticsNode n) {
        values.add(n.value);
        n.visitChildren(collect);
        return true;
      }
      collect(tester
          .renderObject(find.byType(Scaffold))
          .owner!
          .semanticsOwner!
          .rootSemanticsNode!);
      expect(values, isNot(contains('25')));
      // Stop is a button of its own.
      expect(
          tester.getSemantics(find.widgetWithText(OutlinedButton, 'Stop')),
          isSemantics(label: 'Stop', isButton: true, hasTapAction: true));
      for (var i = 0; i < 3; i++) {
        await release(tester);
      }
      handle.dispose();
    });

    testWidgets('one chunk only: the spinner, no progress', (tester) async {
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 4);
      await tapAndOpenDialog(tester, kCreateButton);
      await tester.tap(dialogButton('Create'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(progressText(tester), isNull);
      expect(stopButton('Stop'), findsNothing);
      await release(tester);
      expect(resultText(tester), 'Created 4 fake contacts.');
    });

    testWidgets('Stop: stops after the chunk it is on and says how far it '
        'got; trying again creates the rest', (tester) async {
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      await tapCreate(tester);
      await release(tester);
      expect(progressText(tester), 'Created 1 of 4');

      await tester.tap(stopButton('Stop'));
      await tester.pump();
      // It waits for the chunk it is on.
      expect(stopButton('Stopping…'), findsOneWidget);
      expect(
          tester.widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Stopping…')).enabled,
          isFalse);
      expect(resultFinder, findsNothing);
      await release(tester);

      expect(resultText(tester),
          'Stopped after creating 2 of 4 fake contacts.');
      // The user's choice, not a failure.
      expect(resultIsError(tester), isFalse);
      expect(book.createAllCalls, hasLength(2));
      expect(book.all, hasLength(2));
      expect((await storedLedger()).length, 2);
      expect(statusText(tester), '2 fake contacts on this phone.');
      expect(buttonsEnabled(tester), isTrue);

      book.beforeCreateAll = null;
      await tapCreate(tester);
      expect(resultText(tester), 'Created 2 fake contacts. 2 already existed.');
      expect(book.displayNames, unorderedEquals(kFakeNames));
    });

    testWidgets("Back stops it rather than closing the app; when it isn't "
        'busy, Back closes the app', (tester) async {
      final pops = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') pops.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      await tapCreate(tester);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(pops, isEmpty);
      expect(stopButton('Stopping…'), findsOneWidget);
      await release(tester);

      expect(resultText(tester),
          'Stopped after creating 1 of 4 fake contacts.');
      expect(book.createAllCalls, hasLength(1));
      expect((await storedLedger()).length, 1);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(pops, hasLength(1));
    });

    testWidgets("Back while it is busy without progress does nothing, and "
        "doesn't stop it", (tester) async {
      final pops = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop') pops.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      // Back before the dialog (here, while asking for the permission)
      // doesn't count either.
      final slow = _SlowPermission()..beforeCreateAll = hold;
      await pumpApp(tester, slow, createChunkSize: 2);
      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      slow.answer.complete(PermissionAnswer.granted);
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();
      expect(progressText(tester), 'Created 0 of 4');
      await release(tester);
      await release(tester);

      expect(pops, isEmpty);
      expect(resultText(tester), 'Created 4 fake contacts.');
    });

    testWidgets('Delete shows its progress too, and can be stopped',
        (tester) async {
      await pumpApp(tester, book, deleteChunkSize: 1);
      await tapCreate(tester);
      book.beforeDeleteAll = hold;
      await tapDelete(tester);

      expect(progressText(tester), 'Deleted 0 of 4');
      await release(tester);
      expect(progressText(tester), 'Deleted 1 of 4');
      expect(barValue(tester), 0.25);
      await tester.tap(stopButton('Stop'));
      await tester.pump();
      await release(tester);

      expect(resultText(tester),
          'Stopped after deleting 2 of 4 fake contacts.');
      expect(resultIsError(tester), isFalse);
      expect(book.all, hasLength(2));
      expect(statusText(tester), '2 fake contacts on this phone.');
      // The ones it didn't get to are still recorded.
      expect((await storedLedger()).entries.keys,
          unorderedEquals([for (final c in book.all) ...c.rawContactIds]));

      book.beforeDeleteAll = null;
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 2 fake contacts.');
      expect(resultIsError(tester), isFalse);
      expect(book.all, isEmpty);
    });

    testWidgets('a chunk that fails partway: how far it got, and the '
        'ledger holds what was created', (tester) async {
      book.beforeCreateAll = (call) async {
        if (call == 1) {
          book.createAllError = Exception('provider gone');
          book.createAllStopsAfter = 1;
        }
      };
      await pumpApp(tester, book, createChunkSize: 2);
      await tapCreate(tester);

      expect(resultText(tester), 'Created 3 of 4 fake contacts, then'
          ' something went wrong. Try again to create the rest.');
      expect(resultIsError(tester), isTrue);
      expect(progressText(tester), isNull);
      expect(buttonsEnabled(tester), isTrue);
      expect((await storedLedger()).entries.keys,
          unorderedEquals([for (final c in book.all) ...c.rawContactIds]));
      // The one not found stays pending, in case the read was wrong.
      expect((await storedPending())!.entries, hasLength(1));
      expect(statusText(tester), '3 fake contacts on this phone.');
    });

    testWidgets('the app killed during a Create: after a restart, the count '
        'and Delete include what it made', (tester) async {
      final real = book.add('Alice Example', phones: ['+1 555 0101']);
      // The second call creates its contacts, then the app is gone.
      book.afterCreateAll =
          (call) => call == 1 ? Completer<void>().future : Future.value();
      await pumpApp(tester, book, createChunkSize: 2);
      await tapCreate(tester);
      expect(progressText(tester), 'Created 2 of 4');
      expect(book.all, hasLength(5));

      // A new start of the app.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      book.afterCreateAll = null;
      await pumpApp(tester, book);
      expect(statusText(tester), '4 fake contacts on this phone.');

      await tapAndOpenDialog(tester, kDeleteButton);
      expect(dialogText(tester).title, 'Delete 4 fake contacts?');
      await tester.tap(dialogButton('Delete'));
      await tester.pumpAndSettle();
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(book.all.map((c) => c.id), [real]);
      expect((await storedLedger()).isEmpty, isTrue);
      expect(await storedPending(), isNull);
    });

    testWidgets("the app's screen closed during a Create: it stops after the "
        'chunk it is on, with the ledger right', (tester) async {
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      await tapCreate(tester);
      await release(tester);
      expect(progressText(tester), 'Created 1 of 4');

      await tester.pumpWidget(const SizedBox.shrink());
      gates.last.complete();
      await tester.pumpAndSettle();

      expect(book.createAllCalls, hasLength(2));
      expect(book.all, hasLength(2));
      expect((await storedLedger()).entries.keys,
          unorderedEquals([for (final c in book.all) ...c.rawContactIds]));
      expect(await storedPending(), isNull);
    });

    testWidgets('a result that comes while the app is in the background is '
        'shown when it is back', (tester) async {
      book.beforeCreateAll = hold;
      await pumpApp(tester, book, createChunkSize: 1);
      await tapCreate(tester);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      // It goes on in the background.
      for (var i = 0; i < 4; i++) {
        await release(tester);
      }
      expect(book.all, hasLength(4));
      expect(resultFinder, findsNothing);

      // Not after only "inactive" (e.g. the notification shade): it would
      // be in sight then.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(resultFinder, findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(statusText(tester), '4 fake contacts on this phone.');
    });
  });

  testWidgets("the dialog's Delete is in the error colour, as the Delete "
      'button is; Create and Cancel are not (U7)', (tester) async {
    await pumpApp(tester, book);
    final colors =
        Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    Color? colorOf(String label) => tester
        .widget<TextButton>(dialogButton(label))
        .style
        ?.foregroundColor
        ?.resolve({});

    await tapAndOpenDialog(tester, kCreateButton);
    expect(colorOf('Create'), isNot(colors.error));
    expect(colorOf('Cancel'), isNot(colors.error));
    await tester.tap(dialogButton('Create'));
    await tester.pumpAndSettle();

    await tapAndOpenDialog(tester, kDeleteButton);
    expect(colorOf('Delete'), colors.error);
    expect(colorOf('Cancel'), isNot(colors.error));
    // The text as drawn.
    expect(
        tester
            .widget<RichText>(find.descendant(
                of: dialogButton('Delete'), matching: find.byType(RichText)))
            .text
            .style
            ?.color,
        colors.error);
    await tester.tap(dialogButton('Cancel'));
    await tester.pumpAndSettle();
  });

  group('results under the buttons (U7)', () {
    testWidgets('plain text; failures with an error icon, in the error colour',
        (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);

      await tapCreate(tester);
      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(resultIsError(tester), isFalse);

      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), startsWith('Nothing to create.'));
      expect(resultIsError(tester), isFalse);

      book.merge(into: alice, from: book.idOf('Zach Zen'));
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 3 fake contacts.$kOneMerged');
      expect(resultIsError(tester), isFalse, reason: 'left alone');

      book.createAllError = Exception('provider gone');
      await tapCreate(tester);
      expect(resultText(tester), kCreateFailed);
      expect(resultIsError(tester), isTrue);

      book.createAllError = null;
      book.getAllError = Exception('no provider');
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), kReadFailed);
      expect(resultIsError(tester), isTrue);

      book.getAllError = null;
      book.permission = PermissionAnswer.denied;
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(resultText(tester), kDenied);
      expect(resultIsError(tester), isFalse, reason: 'the user said no');
    });

    testWidgets('a result stays until the next Create or Delete starts, and '
        'moves and covers nothing', (tester) async {
      final alice = book.add('Alice Example', phones: ['+1 555 0101']);
      await pumpApp(tester, book);
      await tapCreate(tester);
      // A long one.
      book.merge(into: alice, from: book.idOf('Zach Zen'));
      book.setPhones(book.idOf('Zoe Zen'), ['+1 555 0199']);
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 2 fake contacts.$kOneMerged$kOneChanged');

      final createAt = tester.getRect(find.text(kCreateButton));
      final deleteAt = tester.getRect(find.text(kDeleteButton));

      // Long after a snack bar would have gone.
      await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(resultText(tester), startsWith('Deleted 2 fake contacts.'));
      // Under the buttons, which can be tapped.
      expect(tester.getRect(resultFinder).top,
          greaterThan(tester.getRect(find.byKey(const Key('Delete'))).bottom));
      for (final label in [kCreateButton, kDeleteButton]) {
        expect(find.text(label).hitTestable(), findsOneWidget);
      }
      // Editing the settings leaves it alone.
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zelda');
      await tester.pumpAndSettle(kSaveDelay);
      expect(resultFinder, findsOneWidget);

      // Gone as soon as the next one starts, also if that is cancelled; the
      // buttons don't move when it goes.
      await tapAndOpenDialog(tester, kCreateButton);
      expect(resultFinder, findsNothing);
      expect(tester.getRect(find.text(kCreateButton)), createAt);
      expect(tester.getRect(find.text(kDeleteButton)), deleteAt);
      await tester.tap(dialogButton('Cancel'));
      await tester.pumpAndSettle();
      expect(resultFinder, findsNothing);
    });

    testWidgets("a failure's icon is as high as a line of its text, also "
        "with Android's nonlinear scaling of large fonts", (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(textScaler: const _NonlinearScaler()),
          child: MyApp(contacts: book)));
      await tester.pumpAndSettle();
      addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
      book.getAllError = Exception('no provider');
      await tapExpectingNoDialog(tester, kCreateButton);

      final icon = tester.widget<Icon>(find.byIcon(Icons.error_outline));
      final line = tester
          .renderObject<RenderParagraph>(resultFinder)
          .getFullHeightForCaret(const TextPosition(offset: 0));
      // bodyLarge: 16 at a line height of 1.5; the scaler doubles 16.
      expect(icon.size, 48);
      expect(icon.size, closeTo(line, 0.5));
    });

    testWidgets('TalkBack reads each result out: one live region, there even '
        'while empty, so a result that repeats is read again', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, book);
      final region = find.byWidgetPredicate((w) =>
          w is Semantics && w.container && w.properties.liveRegion == true);
      expect(region, findsOneWidget);
      SemanticsNode node() => tester.getSemantics(region);
      expect(node().label, isEmpty);
      expect(node().flagsCollection.isLiveRegion, isTrue);
      final id = node().id;

      await tapExpectingNoDialog(tester, kDeleteButton);
      expect(node().label, 'No fake contacts to delete.');

      // Again: empty for a frame, then the same text, on the same node.
      // (TalkBack reads out a live region when its text changes; a new
      // node isn't read out.)
      await tester.tap(find.text(kDeleteButton));
      await tester.pump();
      expect(node().label, isEmpty);
      await tester.pumpAndSettle();
      expect(node().label, 'No fake contacts to delete.');
      expect(node().id, id);

      // A failure's icon isn't read out: the text says it.
      book.getAllError = Exception('no provider');
      await tapExpectingNoDialog(tester, kDeleteButton);
      expect(resultIsError(tester), isTrue);
      expect(node().label, kReadFailed);
      expect(node().id, id);
      handle.dispose();
    });
  });

  group('focus after Create and Delete (U7)', () {
    /// Settles, checking in every update TalkBack gets that a result never
    /// shows before an earlier update gave the button with [key] the focus
    /// back (TalkBack reads out the newly focused button, which would cut
    /// short a result read out before it or with it).
    Future<void> settleFocusFirst(WidgetTester tester, String key) async {
      final handle = tester.ensureSemantics();
      final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
      final label = key == 'Create' ? kCreateButton : kDeleteButton;
      final problems = <String>[];
      // The update before this one: its result, and whether it had the
      // button focused.
      String? previousResult;
      var bFocusedBefore = false;
      void check() {
        String? result;
        var bFocused = false;
        bool visit(SemanticsNode node) {
          final flags = node.flagsCollection;
          if (flags.isLiveRegion && node.label.isNotEmpty) result = node.label;
          if (node.label == label && flags.isFocused == Tristate.isTrue) {
            bFocused = true;
          }
          node.visitChildren(visit);
          return true;
        }

        visit(owner.rootSemanticsNode!);
        // A new result needs the focus in the update before (in the same
        // one, Android may announce the result first, then the focus), and
        // still in its own.
        if (result != null &&
            previousResult == null &&
            !(bFocusedBefore && bFocused)) {
          problems.add(result!);
        }
        previousResult = result;
        bFocusedBefore = bFocused;
      }

      owner.addListener(check);
      await tester.pumpAndSettle();
      owner.removeListener(check);
      handle.dispose();
      expect(problems, isEmpty,
          reason: 'result shown before the focus was back on $key');
    }

    /// Gives the button with [key] the keyboard focus, and presses Enter.
    Future<void> pressWithKeyboard(WidgetTester tester, String key) async {
      focusOf(tester, key).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settleFocusFirst(tester, key);
    }

    testWidgets('with a keyboard, the button pressed has the focus again '
        'after the result, Cancel, a failure, or no dialog', (tester) async {
      await pumpApp(tester, book);
      for (final (key, answer, setUp, result) in [
        ('Create', 'Create', () {}, 'Created 4 fake contacts.'),
        ('Delete', 'Cancel', () {}, null),
        ('Create', null, () {}, 'Nothing to create. 4 fake contacts already exist.'),
        ('Delete', 'Delete', () => book.deleteAllError = Exception('busy'),
            kDeleteFailed),
        ('Create', null, () {
          book.deleteAllError = null;
          book.permission = PermissionAnswer.denied;
        }, kDenied),
      ]) {
        setUp();
        await pressWithKeyboard(tester, key);
        if (answer != null) {
          expect(find.byType(AlertDialog), findsOneWidget, reason: key);
          // While busy, the button is disabled and has lost the focus.
          expect(focusOf(tester, key).hasFocus, isFalse, reason: key);
          await tester.tap(dialogButton(answer));
          await settleFocusFirst(tester, key);
        }
        expect(result == null ? resultFinder : find.text(result),
            result == null ? findsNothing : findsOneWidget, reason: key);
        expect(focusOf(tester, key).hasPrimaryFocus, isTrue,
            reason: '$key, $answer');
      }
    });

    testWidgets('all by keyboard: Tab to the button, Enter, Tab to the '
        "dialog's button, Enter; then Tab goes on from the button",
        (tester) async {
      await pumpApp(tester, book);
      final create = focusOf(tester, 'Create');
      for (var i = 0; i < 10 && !create.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(create.hasPrimaryFocus, isTrue);
      expectRingAround(tester, find.byKey(const Key('Create')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      for (var i = 0; i < 4 && focusedButton() != 'Cancel'; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      // Cancel comes first.
      expect(focusedButton(), 'Cancel');
      expectRingAround(tester, dialogButton('Cancel'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusedButton(), 'Create');
      expectRingAround(tester, dialogButton('Create'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(create.hasPrimaryFocus, isTrue);
      expectRingAround(tester, find.byKey(const Key('Create')));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusOf(tester, 'Delete').hasPrimaryFocus, isTrue);
      expectRingAround(tester, find.byKey(const Key('Delete')));
    });

    testWidgets('with a D-pad, the place is kept too', (tester) async {
      // (Flutter on Android reports the usual navigation mode with a D-pad
      // too; only the keys differ.)
      await pumpApp(tester, book);

      focusOf(tester, 'Delete').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(focusOf(tester, 'Create').hasPrimaryFocus, isTrue);
      // The D-pad's centre button.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      await tester.tap(dialogButton('Create'));
      await tester.pumpAndSettle();

      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(focusOf(tester, 'Create').hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(focusOf(tester, 'Delete').hasPrimaryFocus, isTrue);
    });

    testWidgets('a tap on the screen gives the button no focus, and shows '
        'no focus ring', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(focusedButton(), isNull);
      expect(rings(tester), isEmpty);

      // Focused by code after a tap (the screen in touch mode): no ring.
      focusOf(tester, 'Create').requestFocus();
      await tester.pumpAndSettle();
      expect(focusedButton(), 'Create Fake Contacts');
      expect(rings(tester), isEmpty);
      // Once a key is pressed, it shows.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusedButton(), 'Delete Fake Contacts');
      expectRingAround(tester, find.byKey(const Key('Delete')));
    });

    group('with progress', () {
      late List<Completer<void>> gates;
      Future<void> hold(int _) {
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      }

      setUp(() => gates = []);

      Finder stop(String label) => find.widgetWithText(OutlinedButton, label);

      testWidgets('Stop pressed with the keyboard: the focus goes to the '
          'button that ran once it has stopped', (tester) async {
        book.beforeCreateAll = hold;
        await pumpApp(tester, book, createChunkSize: 1);
        // Started by a tap, so only pressing Stop calls for the focus.
        await tapCreate(tester);
        expect(find.byKey(const Key('Progress')), findsOneWidget);

        Focus.of(tester.element(find.descendant(
                of: stop('Stop'), matching: find.byType(Text))))
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        // Disabled while it stops, so it has lost the focus.
        expect(stop('Stopping…'), findsOneWidget);
        expect(focusedButton(), isNull);
        gates.last.complete();
        await tester.pumpAndSettle();

        expect(resultText(tester), 'Stopped after creating 1 of 4 fake contacts.');
        expect(focusOf(tester, 'Create').hasPrimaryFocus, isTrue);
      });

      testWidgets('Stop focused when it ends (and goes away): the focus goes '
          'to the button that ran', (tester) async {
        book.beforeDeleteAll = hold;
        await pumpApp(tester, book, deleteChunkSize: 1);
        await tapCreate(tester);
        // Started by a tap, then the keyboard is used.
        await tapDelete(tester);
        Focus.of(tester.element(find.descendant(
                of: stop('Stop'), matching: find.byType(Text))))
            .requestFocus();
        await tester.pump();
        for (var i = 0; i < 4; i++) {
          gates.last.complete();
          await tester.pumpAndSettle();
        }

        expect(resultText(tester), 'Deleted 4 fake contacts.');
        expect(focusOf(tester, 'Delete').hasPrimaryFocus, isTrue);
      });
    });
  });

  group('TalkBack hears results after a dialog (U13)', () {
    testWidgets('a quick Create and Delete: the result shows once the '
        'dialog has gone, and is read out', (tester) async {
      await pumpApp(tester, book);
      final heard = LiveRegionAnnouncements(tester);
      await tester.pump();
      for (final (button, answer, result) in [
        (kCreateButton, 'Create', 'Created 4 fake contacts.'),
        (kDeleteButton, 'Delete', 'Deleted 4 fake contacts.'),
      ]) {
        await tapAndOpenDialog(tester, button);
        await tester.tap(dialogButton(answer));
        await tester.pump();
        await tester.pump();
        // Done already; the dialog is closing.
        expect(book.all, hasLength(answer == 'Create' ? 4 : 0),
            reason: button);
        await noResultUntilDialogGone(tester);
        await tester.pumpAndSettle();
        expect(resultText(tester), result);
      }
      expect(heard.texts, ['Created 4 fake contacts.', 'Deleted 4 fake contacts.']);
      expect(heard.missed, isEmpty);
      heard.dispose();
    });

    testWidgets("also after the dialog that offers the settings, if they "
        "can't be opened", (tester) async {
      book.permission = PermissionAnswer.permanentlyDenied;
      book.openSettingsError = Exception('no activity');
      await pumpApp(tester, book);
      final heard = LiveRegionAnnouncements(tester);
      await tester.pump();
      await tapAndOpenDialog(tester, kCreateButton);
      await tester.tap(dialogButton('Open settings'));
      await tester.pump();
      await noResultUntilDialogGone(tester);
      await tester.pumpAndSettle();
      expect(book.openSettingsCalls, 1);
      expect(heard.texts, ["Couldn't open Settings."]);
      expect(heard.missed, isEmpty);
      heard.dispose();
    });

    testWidgets('a result without a dialog is read out too', (tester) async {
      await pumpApp(tester, book);
      final heard = LiveRegionAnnouncements(tester);
      await tester.pump();
      await tapExpectingNoDialog(tester, kDeleteButton);
      book.permission = PermissionAnswer.denied;
      await tapExpectingNoDialog(tester, kCreateButton);
      expect(heard.texts, [
        'No fake contacts to delete.',
        kDenied,
      ]);
      expect(heard.missed, isEmpty);
      heard.dispose();
    });

    testWidgets('no spinner while only the dialog is closing, after Cancel '
        'or a quick Create', (tester) async {
      await pumpApp(tester, book);
      for (final answer in ['Cancel', 'Create']) {
        await tapAndOpenDialog(tester, kCreateButton);
        await tester.tap(dialogButton(answer));
        await tester.pump();
        await tester.pump();
        expect(find.byType(AlertDialog), findsOneWidget, reason: answer);
        await untilDialogGone(
            tester,
            () => expect(find.byType(CircularProgressIndicator), findsNothing,
                reason: answer));
        await tester.pumpAndSettle();
        expect(buttonsEnabled(tester), isTrue, reason: answer);
      }
      expect(resultText(tester), 'Created 4 fake contacts.');
    });

    testWidgets('busy until the dialog has gone: taps meanwhile do '
        'nothing, then the result shows', (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      await tester.tap(dialogButton('Create'));
      await tester.pump();
      await tester.pump();
      expect(book.all, hasLength(4));
      expect(find.byType(AlertDialog), findsOneWidget);
      // While the dialog closes, taps reach the page, but do nothing.
      expect(buttonsEnabled(tester), isFalse);
      expect(tester.widget<PopupMenuButton<Object?>>(menu).enabled, isFalse);
      await tester.tap(find.text(kDeleteButton), warnIfMissed: false);
      await tester.pump();
      await noResultUntilDialogGone(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(book.all, hasLength(4));
      expect(resultText(tester), 'Created 4 fake contacts.');
      expect(buttonsEnabled(tester), isTrue);
    });

    testWidgets('a result whose dialog is still closing when the app goes '
        'out of sight shows when it is back', (tester) async {
      await pumpApp(tester, book);
      await tapAndOpenDialog(tester, kCreateButton);
      await tester.tap(dialogButton('Create'));
      await tester.pump();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump(const Duration(seconds: 1));
      expect(resultFinder, findsNothing);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(resultText(tester), 'Created 4 fake contacts.');
    });
  });

  group('reset to defaults (U9)', () {
    final Finder resetItem = find.byKey(const Key('Reset'));
    const String kReset = 'Names and templates reset to the defaults.';
    const kFieldKeys = [
      'LastNames',
      'FirstNames',
      'PhoneNumberTemplate',
      'EmailAddressTemplate',
    ];
    const kDefaults = [
      kDefaultLastNames,
      kDefaultFirstNames,
      kDefaultPhoneTemplate,
      kDefaultEmailTemplate,
    ];

    /// The four fields' text, in order.
    List<String> fields(WidgetTester tester) => [
          for (final key in kFieldKeys)
            tester.widget<TextField>(find.byKey(Key(key))).controller!.text,
        ];

    /// The four settings as stored, in the same order.
    Future<List<String?>> stored() async {
      final prefs = await SharedPreferences.getInstance();
      return [for (final key in kSettings.keys) prefs.getString(key)];
    }

    String preview(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('Preview'))).data!;

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(resetItem, findsOneWidget);
    }

    bool itemEnabled(WidgetTester tester) =>
        tester.widget<PopupMenuItem<Object?>>(resetItem).enabled;

    bool menuEnabled(WidgetTester tester) =>
        tester.widget<PopupMenuButton<Object?>>(menu).enabled;

    /// Opens the menu, taps Reset to defaults, and expects the dialog.
    Future<void> openResetDialog(WidgetTester tester) async {
      await openMenu(tester);
      await tester.tap(resetItem);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    }

    testWidgets('puts the name lists and templates back and saves them at '
        'once; the ledger, the status line and the address book are left '
        'alone, and Delete still removes what was created', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      expect(statusText(tester), '4 fake contacts on this phone.');
      final ledger = await storedLedgerJson();
      // All four differ from the defaults (the names already do); the
      // phone template with a warning, still to be saved.
      await tester.enterText(
          find.byKey(const Key('EmailAddressTemplate')), 'FIRST@example.org');
      await tester.enterText(
          find.byKey(const Key('PhoneNumberTemplate')), '+44 abc');
      await tester.pump();
      for (final (i, text) in fields(tester).indexed) {
        expect(text, isNot(kDefaults[i]));
      }
      final warning = phoneTemplateWarning('+44 abc')!;
      expect(find.text(warning), findsOneWidget);
      final (reads, asks, checks) =
          (book.getAllCalls, book.permissionRequests, book.permissionChecks);

      await openMenu(tester);
      expect(itemEnabled(tester), isTrue);
      await tester.tap(resetItem);
      await tester.pumpAndSettle();
      expect(dialogText(tester), (
        title: 'Reset to defaults?',
        body: 'The name lists and templates go back to the defaults. Fake'
            ' contacts already created are kept, and Delete can still remove'
            ' them.',
      ));
      expect(dialogButton('Cancel'), findsOneWidget);
      // Not in the error colour: no contacts are deleted.
      expect(
          tester.widget<TextButton>(dialogButton('Reset')).style?.foregroundColor,
          isNull);
      await tester.tap(dialogButton('Reset'));
      await tester.pump();
      // Saved at once, not once typing would have paused.
      expect(await stored(), kDefaults);

      await tester.pumpAndSettle();
      expect(fields(tester), kDefaults);
      expect(preview(tester),
          '27 last names × 28 first names = 756 fake contacts.\n'
          'For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com');
      expect(find.text(warning), findsNothing);
      expect(resultText(tester), kReset);
      expect(resultIsError(tester), isFalse);
      expect(statusText(tester), '4 fake contacts on this phone.');
      expect(await storedLedgerJson(), ledger);
      expect(
          (book.getAllCalls, book.permissionRequests, book.permissionChecks),
          (reads, asks, checks),
          reason: 'neither the address book nor the permission is touched');
      // Nothing saved later undoes it.
      await tester.pump(kSaveDelay * 2);
      expect(await stored(), kDefaults);

      // The fakes made with the old settings are still deleted.
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');
      expect(book.displayNames, isEmpty);
    });

    testWidgets('Cancel, Back and tapping outside the dialog change nothing',
        (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zelda');
      await tester.pump(kSaveDelay);
      final before = fields(tester);
      final saved = await stored();
      expect(saved.first, 'Zelda');

      for (final dismiss in ['Cancel', 'Back', 'outside']) {
        await openResetDialog(tester);
        switch (dismiss) {
          case 'Cancel':
            await tester.tap(dialogButton('Cancel'));
          case 'Back':
            await tester.binding.handlePopRoute();
          default:
            await tester.tapAt(const Offset(10, 10));
        }
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing, reason: dismiss);
        expect(fields(tester), before, reason: dismiss);
        expect(await stored(), saved, reason: dismiss);
        // The last result stays.
        expect(resultText(tester), 'Created 4 fake contacts.', reason: dismiss);
      }
    });

    testWidgets('the item is greyed while the fields hold the defaults, and '
        'the menu button while Create or Delete runs', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      expect(fields(tester), kDefaults);

      await openMenu(tester);
      expect(itemEnabled(tester), isFalse);
      await tester.tap(resetItem, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.binding.handlePopRoute(); // closes the menu
      await tester.pumpAndSettle();
      expect(resetItem, findsNothing);

      // Any change counts, even one that makes the same contacts.
      final email = find.byKey(const Key('EmailAddressTemplate'));
      await tester.enterText(email, '$kDefaultEmailTemplate ');
      await openMenu(tester);
      expect(itemEnabled(tester), isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.enterText(email, kDefaultEmailTemplate);
      await openMenu(tester);
      expect(itemEnabled(tester), isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Busy (here, waiting for the permission): the button is disabled.
      expect(menuEnabled(tester), isTrue);
      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      expect(menuEnabled(tester), isFalse);
      await tester.tap(menu, warnIfMissed: false);
      await tester.pump();
      expect(resetItem, findsNothing);
      slow.answer.complete(PermissionAnswer.denied);
      await tester.pumpAndSettle();
      expect(menuEnabled(tester), isTrue);
    });

    testWidgets("a text field being edited loses the focus as the menu "
        "opens; after Reset its keyboard doesn't come back, after Cancel it "
        "does", (tester) async {
      await pumpApp(tester, book);
      for (final answer in ['Cancel', 'Reset']) {
        await tester.tap(find.byKey(const Key('FirstNames')));
        await tester.pump();
        expect(tester.testTextInput.isVisible, isTrue);
        await openMenu(tester);
        expect(tester.testTextInput.isVisible, isFalse);
        await tester.tap(resetItem);
        await tester.pumpAndSettle();
        await tester.tap(dialogButton(answer));
        await tester.pumpAndSettle();
        final bBack = answer == 'Cancel';
        expect(tester.testTextInput.isVisible, bBack, reason: answer);
        expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<TextField>()
                ?.key,
            bBack ? const Key('FirstNames') : null,
            reason: answer);
        if (bBack) {
          FocusManager.instance.primaryFocus!.unfocus();
          await tester.pump();
        }
      }
      expect(resultText(tester), kReset);
    });

    testWidgets('closing the menu without a choice gives the field its focus '
        'and keyboard back', (tester) async {
      await pumpApp(tester, book);
      final field = find.byKey(const Key('FirstNames'));
      for (final close in ['Back', 'outside']) {
        await tester.tap(field);
        await tester.pump();
        await openMenu(tester);
        expect(tester.testTextInput.isVisible, isFalse);
        if (close == 'Back') {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tapAt(const Offset(10, 500));
        }
        await tester.pumpAndSettle();
        expect(resetItem, findsNothing);
        expect(tester.testTextInput.isVisible, isTrue, reason: close);
        expect(
            FocusManager.instance.primaryFocus?.context
                ?.findAncestorWidgetOfExactType<TextField>()
                ?.key,
            const Key('FirstNames'),
            reason: close);
        FocusManager.instance.primaryFocus!.unfocus();
        await tester.pump();
      }
      // Without a field focused before, nothing gets the focus.
      await openMenu(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    group('TalkBack (U13)', () {
      /// Changes a field, then resets it, up to the tap on Reset.
      Future<void> editAndReset(WidgetTester tester) async {
        await tester.enterText(
            find.byKey(const Key('LastNames')), 'Zelda');
        await openResetDialog(tester);
        await tester.tap(dialogButton('Reset'));
        await tester.pump();
      }

      testWidgets('the last result goes at once; the message comes once the '
          'dialog has gone, and is read out, also when it repeats',
          (tester) async {
        await pumpApp(tester, book);
        final heard = LiveRegionAnnouncements(tester);
        await tester.pump();
        await tapCreate(tester);
        expect(heard.texts, ['Created 4 fake contacts.']);

        for (var i = 0; i < 2; i++) {
          await editAndReset(tester);
          // The fields and the last result at once.
          expect(fields(tester), kDefaults);
          expect(resultFinder, findsNothing);
          // The message not while the dialog is still closing.
          await noResultUntilDialogGone(tester);
          await tester.pumpAndSettle();
          expect(resultText(tester), kReset);
        }
        expect(heard.texts, ['Created 4 fake contacts.', kReset, kReset]);
        expect(heard.missed, isEmpty);
        heard.dispose();
      });

      testWidgets('fields edited before the message shows: no message, even '
          'if they are back at the defaults', (tester) async {
        await pumpApp(tester, book);
        for (final edits in [
          ['Zelda'],
          ['Zelda', kDefaultFirstNames],
        ]) {
          final edit = edits.join(', then ');
          await editAndReset(tester);
          // (While the dialog closes.)
          expect(find.byType(AlertDialog), findsOneWidget);
          for (final text in edits) {
            await tester.enterText(find.byKey(const Key('FirstNames')), text);
          }
          expect(fields(tester)[1],
              edits.length == 2 ? kDefaultFirstNames : 'Zelda');
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(resultFinder, findsNothing, reason: edit);
        }
      });

      testWidgets('a message whose dialog is still closing when the app '
          'goes out of sight shows when it is back', (tester) async {
        await pumpApp(tester, book);
        await editAndReset(tester);
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(resultFinder, findsNothing);
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await tester.pumpAndSettle();
        expect(resultText(tester), kReset);
      });

      testWidgets('a Create started before the message shows keeps its own '
          'result', (tester) async {
        await pumpApp(tester, book);
        await editAndReset(tester);
        // While the dialog closes, taps reach the page.
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text(kCreateButton));
        await tester.pumpAndSettle();
        expect(dialogText(tester).title, 'Create 756 fake contacts?');
        expect(resultFinder, findsNothing);
        await tester.tap(dialogButton('Create'));
        await tester.pumpAndSettle();
        expect(resultText(tester), 'Created 756 fake contacts.');
      });
    });

    testWidgets('the message goes once the fields are edited again; other '
        'results stay', (tester) async {
      await pumpApp(tester, book);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zelda');
      await openResetDialog(tester);
      await tester.tap(dialogButton('Reset'));
      await tester.pumpAndSettle();
      expect(resultText(tester), kReset);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zelda');
      await tester.pump();
      expect(resultFinder, findsNothing);

      await tapCreate(tester);
      await tester.enterText(find.byKey(const Key('LastNames')), 'Zora');
      await tester.pump();
      expect(resultText(tester), 'Created 28 fake contacts.');
    });

    testWidgets('all by keyboard: the menu button comes first; Enter, Down, '
        'Enter, Tab to Reset, Enter; the focus is back on the menu button',
        (tester) async {
      await pumpApp(tester, book);
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.tab);
      expect(menuFocused(tester), isTrue);
      expectRingAround(tester, menu);
      // All of it on screen, not cut off at the edge.
      final (ring, _) = rings(tester).single;
      expect(ring.right, lessThanOrEqualTo(tester.view.physicalSize.width /
          tester.view.devicePixelRatio));
      await press(LogicalKeyboardKey.enter);
      expect(resetItem, findsOneWidget);
      // (Flutter's menu opens with no item focused.)
      await press(LogicalKeyboardKey.arrowDown);
      expectRingInside(tester, resetItem);
      await press(LogicalKeyboardKey.enter);
      expect(find.byType(AlertDialog), findsOneWidget);
      for (var i = 0; i < 4 && focusedButton() != 'Reset'; i++) {
        await press(LogicalKeyboardKey.tab);
      }
      expect(focusedButton(), 'Reset');
      expectRingAround(tester, dialogButton('Reset'));
      await press(LogicalKeyboardKey.enter);

      expect(fields(tester), kDefaults);
      expect(resultText(tester), kReset);
      expect(menuFocused(tester), isTrue);
      expectRingAround(tester, menu);
    });

    testWidgets('with a D-pad too', (tester) async {
      await pumpApp(tester, book);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(menuFocused(tester), isTrue);
      // The D-pad's centre button, and its arrows.
      for (final key in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowRight,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(focusedButton(), 'Reset');
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(resultText(tester), kReset);
      expect(menuFocused(tester), isTrue);
    });

    testWidgets('TalkBack hears "More options", and a greyed item as '
        'disabled', (tester) async {
      final handle = tester.ensureSemantics();
      SharedPreferences.setMockInitialValues({});
      final slow = _SlowPermission();
      await pumpApp(tester, slow);
      final button = find.byTooltip('More options');
      // (Its name comes from the tooltip.)
      expect(tester.getSemantics(button),
          isSemantics(tooltip: 'More options', isButton: true,
              hasEnabledState: true, isEnabled: true, hasTapAction: true));
      await openMenu(tester);
      expect(tester.getSemantics(find.text('Reset to defaults')),
          isSemantics(label: 'Reset to defaults', isButton: true,
              hasEnabledState: true, isEnabled: false, hasTapAction: false));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      await tester.tap(find.text(kCreateButton));
      await tester.pump();
      expect(tester.getSemantics(button),
          isSemantics(tooltip: 'More options', hasEnabledState: true,
              isEnabled: false, hasTapAction: false));
      slow.answer.complete(PermissionAnswer.denied);
      await tester.pumpAndSettle();
      handle.dispose();
    });
  });

  group('About (U9)', () {
    final Finder aboutItem = find.byKey(const Key('About'));

    Future<void> openAbout(WidgetTester tester) async {
      await tester.tap(menu);
      await tester.pumpAndSettle();
      await tester.tap(aboutItem);
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
    }

    testWidgets('opens from the menu, also while the fields hold the '
        'defaults; Back returns to the page as it was, the result still '
        'there', (tester) async {
      await pumpApp(tester, book);
      await tapCreate(tester);
      final result = resultText(tester);
      final settings = await SharedPreferences.getInstance();
      final before = {for (final key in kSettings.keys) key: settings.get(key)};

      await openAbout(tester);
      expect(find.text('Version $kAppVersion'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsNothing);
      expect(resultText(tester), result);
      expect({for (final key in kSettings.keys) key: settings.get(key)},
          before);
      // Create and Delete still work.
      await tapDelete(tester);
      expect(resultText(tester), 'Deleted 4 fake contacts.');

      // With the defaults, Reset is greyed, but not About.
      // (After the app is gone: it saves its settings as it goes.)
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      SharedPreferences.setMockInitialValues({});
      await pumpApp(tester, book);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(
          tester.widget<PopupMenuItem<Object?>>(find.byKey(const Key('Reset')))
              .enabled,
          isFalse);
      expect(tester.widget<PopupMenuItem<Object?>>(aboutItem).enabled, isTrue);
      await tester.tap(aboutItem);
      await tester.pumpAndSettle();
      expect(find.byType(AboutPage), findsOneWidget);
    });

    testWidgets("a text field being edited doesn't get the focus back "
        "afterwards: its keyboard stays closed", (tester) async {
      await pumpApp(tester, book);
      await tester.tap(find.byKey(const Key('FirstNames')));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      await openAbout(tester);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<TextField>(),
          isNull);
    });

    testWidgets('all by keyboard: Down twice to About, with its ring; Enter; '
        'Back by Tab and Enter; the focus is back on the menu button',
        (tester) async {
      await pumpApp(tester, book);
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.tab);
      expect(menuFocused(tester), isTrue);
      await press(LogicalKeyboardKey.enter);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown);
      expectRingInside(tester, aboutItem);
      await press(LogicalKeyboardKey.enter);
      expect(find.byType(AboutPage), findsOneWidget);
      await press(LogicalKeyboardKey.tab);
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<BackButton>(),
          isNotNull);
      await press(LogicalKeyboardKey.enter);
      expect(find.byType(AboutPage), findsNothing);
      expect(menuFocused(tester), isTrue);
      expectRingAround(tester, menu);
    });

    testWidgets('TalkBack hears the item as "About"', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpApp(tester, book);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(tester.getSemantics(find.text('About')),
          isSemantics(label: 'About', isButton: true, hasEnabledState: true,
              isEnabled: true, hasTapAction: true));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      handle.dispose();
    });
  });
}

/// Scales small text more than large text, as Android 14 and later do with
/// a large font size.
class _NonlinearScaler extends TextScaler {
  const _NonlinearScaler();

  @override
  double scale(double fontSize) => fontSize < 20 ? fontSize * 2 : fontSize * 1.5;

  @override
  double get textScaleFactor => 2;

  @override
  TextScaler clamp({double minScaleFactor = 0, double maxScaleFactor = double.infinity}) => this;
}
