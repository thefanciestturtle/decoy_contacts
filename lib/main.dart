import 'package:flutter/material.dart';

import 'contacts_gateway.dart';
import 'flutter_contacts_gateway.dart';
import 'home_page.dart';
import 'settings_store.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.contacts = const FlutterContactsGateway(),
    this.ledgerStore = const LedgerStore(),
  });

  /// The address book; tests pass an in-memory one.
  final ContactsGateway contacts;

  /// Where the ledger is kept; tests can pass one that fails.
  final LedgerStore ledgerStore;

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {

    return MaterialApp(
      title: 'Fake Contacts',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: MyHomePage(
          title: 'Fake Contacts', contacts: contacts, ledgerStore: ledgerStore),
    );
  }
}
