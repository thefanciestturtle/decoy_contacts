// What the app does while the contacts provider can't be reached (C14),
// against the device's real provider.
//
// These tests need the provider disabled (`pm disable-user`): then Android
// can't find it, and a query gets no cursor. Reading must then fail, not
// read "no contacts": the app would take an address book that looks empty
// for one in which its fakes are gone. tool/integration_test.sh sets that
// up and runs this file after the other tests.

import 'dart:convert';

import 'package:decoy_contacts/fake_contacts_core.dart';
import 'package:decoy_contacts/flutter_contacts_gateway.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_test.dart' show kCreate, kDelete, launchApp, tapAndWaitForResult;

const String kReadFailed = "Couldn't read your contacts. Try again.";

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> expectProviderGone() async {
    final Object? error = await const FlutterContactsGateway()
        .getAll()
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(error, isNotNull,
        reason: 'The contacts provider can be reached: these tests need it '
            'disabled; tool/integration_test.sh does that.');
  }

  testWidgets('reading the address book fails, as a whole or by contact IDs',
      (tester) async {
    for (final ids in <List<String>?>[null, ['1', '2']]) {
      final Object? error = await const FlutterContactsGateway()
          .getAll(ids: ids)
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<PlatformException>().having((e) => e.code, 'code',
          'read_failed'),
          reason: 'getAll(ids: $ids) should fail, not find no contacts');
      expect(error.toString(), contains('no cursor'));
    }
  });

  testWidgets('Create and Delete say so without asking, and the ledger is '
      'left as it was', (tester) async {
    await expectProviderGone();
    final prefs = await SharedPreferences.getInstance();
    await prefs.clear(); // the default settings
    addTearDown(prefs.clear);
    // A fake the app made earlier. A read that found no contacts would lose
    // it from the ledger for good.
    final ledger = Ledger({
      '7': const LedgerEntry(
          'Zoe Zen', '+447700900010', 'Zoe.Zen@example.com'),
    }).encode();
    await prefs.setString(kLedgerPrefsKey, ledger);
    await launchApp(tester);

    // (Without a count the status line shows nothing.)
    expect(await tapAndWaitForResult(tester, kCreate), kReadFailed);
    expect(await tapAndWaitForResult(tester, kDelete), kReadFailed);

    await prefs.reload();
    expect(jsonDecode(prefs.getString(kLedgerPrefsKey)!), jsonDecode(ledger));
  });
}
