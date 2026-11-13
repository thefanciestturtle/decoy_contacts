import 'package:material_ui/material_ui.dart';

import 'app_info.dart';
import 'app_theme.dart';
import 'contact_actions.dart';
import 'contacts_gateway.dart';
import 'flutter_contacts_gateway.dart';
import 'home_page.dart';
import 'settings_store.dart';
import 'text_field_keys.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    this.contacts = const FlutterContactsGateway(),
    this.ledgerStore = const LedgerStore(),
    this.createChunkSize = kCreateChunkSize,
    this.deleteChunkSize = kDeleteChunkSize,
  });

  /// The address book; tests pass an in-memory one.
  final ContactsGateway contacts;

  /// Where the ledger is kept; tests can pass one that fails.
  final LedgerStore ledgerStore;

  /// How many contacts Create and Delete handle per call; tests use small
  /// ones.
  final int createChunkSize;
  final int deleteChunkSize;

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {

    return MaterialApp(
      title: kAppName,
      // Light or dark, as the system is set.
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      // On every screen, the arrow keys can leave a text field at its start
      // or end (a D-pad has no Tab).
      builder: (context, child) => ArrowsLeaveTextFields(child: child!),
      home: MyHomePage(
          title: kAppName,
          contacts: contacts,
          ledgerStore: ledgerStore,
          createChunkSize: createChunkSize,
          deleteChunkSize: deleteChunkSize),
    );
  }
}
