import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_contacts_core.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {

    return MaterialApp(
      title: 'Fake Contacts',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: MyHomePage(title: 'Fake Contacts'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  MyHomePage({Key? key, required this.title}) : super(key: key);

  final String title;

  @override
  _MyHomePageState createState() => _MyHomePageState();
}


const String kDefaultLastNames = "Zen,Zaragoza,Zabinski,Zimmermann,Zapata,Zona,Zidane,Zeiss,Zimmer,Zaal,Zaman,Zambrano,Zanetti,Zangari,Zappa,Zavala,Zawisza,Zeegers,Zelenka,Zellweger,Zeni,Zhang,Zhao,Zheng,Zhou,Ziegler,Zima";
const String kDefaultFirstNames = "Zoe,Zach,Zbigniew,Zaire,Zero,Zakai,Zamir,Zan,Zanna,Zareen,Zeb,Zeki,Zelda,Zella,Zeno,Zephyr,Zhen,Zhi,Zhong,Zhu,Ziba,Ziggy,Zion,Zola,Zolyan,Zora,Zsazsa,Zuzana";

/// How long to wait after the last keystroke before saving the settings.
const Duration kSaveDelay = Duration(milliseconds: 500);


class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {

  Key keyLastNames = Key("LastNames");
  Key keyFirstNames = Key("FirstNames");
  Key keyPhoneNumberTemplate = Key("PhoneNumberTemplate");
  Key keyEmailAddressTemplate = Key("EmailAddressTemplate");

  final TextEditingController lastNamesController = TextEditingController();
  final TextEditingController firstNamesController = TextEditingController();
  final TextEditingController phoneNumberTemplateController = TextEditingController();
  final TextEditingController emailAddressTemplateController = TextEditingController();

  // The text fields are the single source of truth for the settings.
  List<String> get lastNames => parseNames(lastNamesController.text);
  List<String> get firstNames => parseNames(firstNamesController.text);
  String get sPhoneNumberTemplate => phoneNumberTemplateController.text.trim();
  String get sEmailAddressTemplate => emailAddressTemplateController.text.trim();

  bool _settingsLoaded = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveSettingsNow();
    lastNamesController.dispose();
    firstNamesController.dispose();
    phoneNumberTemplateController.dispose();
    emailAddressTemplateController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Don't lose an edit made just before the app is backgrounded or killed.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      _saveSettingsNow();
    }
  }

  /// Reads the settings once at startup, filling in defaults on first run.
  Future<void> _loadSettings() async {
    log("_loadSettings: called");
    final prefs = await SharedPreferences.getInstance();
    final String? sStoredLastNames = prefs.getString('sListOfLastNames');
    bool bNeedsSave = false;
    String sPhone;
    if (sStoredLastNames == null) {
      lastNamesController.text = kDefaultLastNames;
      firstNamesController.text = kDefaultFirstNames;
      sPhone = kDefaultPhoneTemplate;
      emailAddressTemplateController.text = kDefaultEmailTemplate;
      bNeedsSave = true;
    } else {
      lastNamesController.text = sStoredLastNames;
      firstNamesController.text = prefs.getString('sListOfFirstNames') ?? "";
      sPhone = prefs.getString('sPhoneNumberTemplate') ?? "";
      emailAddressTemplateController.text = prefs.getString('sEmailAddressTemplate') ?? "";
    }
    if (sPhone == kLegacyDefaultPhoneTemplate) {
      // old default was in Algeria's real country code (+213)
      sPhone = kDefaultPhoneTemplate;
      bNeedsSave = true;
    }
    phoneNumberTemplateController.text = sPhone;
    if (bNeedsSave) await _saveSettingsNow();
    if (!mounted) return;
    setState(() { _settingsLoaded = true; });
  }

  /// Called on every keystroke; saves once typing pauses.
  void _settingsChanged(String _) {
    _saveTimer?.cancel();
    _saveTimer = Timer(kSaveDelay, _saveSettingsNow);
  }

  Future<void> _saveSettingsNow() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    if (!_settingsLoaded && lastNamesController.text.isEmpty) return; // nothing loaded yet
    log("_saveSettingsNow: called");
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("sListOfLastNames", lastNamesController.text);
    await prefs.setString("sListOfFirstNames", firstNamesController.text);
    await prefs.setString("sPhoneNumberTemplate", phoneNumberTemplateController.text);
    await prefs.setString("sEmailAddressTemplate", emailAddressTemplateController.text);
  }

  Future<Ledger> _loadLedger() async {
    final prefs = await SharedPreferences.getInstance();
    return Ledger.decode(prefs.getString(kLedgerPrefsKey));
  }

  Future<void> _saveLedger(Ledger ledger) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kLedgerPrefsKey, ledger.encode());
  }

  /// Contact ID -> raw contact IDs for the whole address book (Android only).
  Future<AddressBook> _snapshotAddressBook({List<String>? onlyContactIds}) async {
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.identifiers},
      filter: onlyContactIds == null ? null : ContactFilter.ids(onlyContactIds),
    );
    return _toAddressBook(contacts);
  }

  AddressBook _toAddressBook(List<Contact> contacts) {
    return {
      for (final c in contacts)
        if (c.id != null)
          c.id!: [
            for (final r in c.android?.identifiers?.rawContacts ?? const <RawContact>[])
              if (r.rawContactId != null) r.rawContactId!,
          ],
    };
  }

  bool _isBusy = false;

  void _showResultSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _createAllContacts() async {
    if (_isBusy) return;
    setState(() { _isBusy = true; });
    unawaited(_saveSettingsNow());

    log("_createAllContacts: about to call FlutterContacts.permissions.request");
    PermissionStatus permission = await FlutterContacts.permissions.request(PermissionType.readWrite);

    int nCreated = 0;
    int nAlreadyExisted = 0;
    int nUntracked = 0;
    String? sError;
    if (permission != PermissionStatus.granted) {
      log("_createAllContacts: no permission, status " + permission.toString());
    } else {
      try {
        final everyone = await FlutterContacts.getAll(properties: {
          ContactProperty.identifiers,
          ContactProperty.name,
          ContactProperty.phone,
          ContactProperty.email,
        });
        final before = _toAddressBook(everyone);
        final existingFingerprints = {
          for (final c in everyone)
            ...fingerprintsOf(
                c.displayName ?? "",
                [for (final p in c.phones) p.number],
                [for (final e in c.emails) e.address]),
        };
        final ledger = (await _loadLedger()).prunedTo(allRawIds(before));
        final wanted = allCombinations(firstNames, lastNames);
        final toCreate = namesToCreate(wanted, ledger, before,
            existingFingerprints: existingFingerprints,
            fingerprintOf: (n) => contactFingerprint(
                n.displayName,
                sPhoneNumberTemplate.isEmpty ? "" : generatePhoneNumber(sPhoneNumberTemplate, n.last),
                sEmailAddressTemplate.isEmpty ? "" : generateEmailAddress(sEmailAddressTemplate, n.first, n.last)));
        nAlreadyExisted = wanted.length - toCreate.length;

        if (toCreate.isNotEmpty) {
          final newContacts = [
            for (final n in toCreate)
              Contact(
                  name: Name(first: n.first, last: n.last),
                  phones: [
                    if (sPhoneNumberTemplate.isNotEmpty)
                      Phone(number: generatePhoneNumber(sPhoneNumberTemplate, n.last))
                  ],
                  emails: [
                    if (sEmailAddressTemplate.isNotEmpty)
                      Email(address: generateEmailAddress(sEmailAddressTemplate, n.first, n.last))
                  ]),
          ];
          log("_createAllContacts: about to call FlutterContacts.createAll for " + newContacts.length.toString() + " contact(s)");
          final ids = await FlutterContacts.createAll(newContacts);
          final after = await _snapshotAddressBook(onlyContactIds: ids);
          final created = newlyCreatedRawIds(
              created: toCreate, createdContactIds: ids, before: before, after: after);
          ledger.rawIdToName.addAll(created);
          nCreated = ids.length;
          nUntracked = nCreated - created.length;
        }
        await _saveLedger(ledger);
      } catch (e) {
        log("_createAllContacts: error " + e.toString());
        sError = e.toString();
      }
    }
    log("_createAllContacts: about to return, nCreated " + nCreated.toString());

    if (!mounted) return;
    setState(() { _isBusy = false; });
    String sMessage;
    if (permission != PermissionStatus.granted) {
      sMessage = "Permission to access contacts was denied.";
    } else if (sError != null) {
      sMessage = "Error while creating contacts: " + sError;
    } else {
      sMessage = "Created " + nCreated.toString() + " fake contact(s).";
      if (nAlreadyExisted > 0) sMessage += " " + nAlreadyExisted.toString() + " already existed.";
      if (nUntracked > 0) {
        sMessage += " Warning: " + nUntracked.toString() +
            " could not be recorded and must be deleted by hand.";
      }
    }
    _showResultSnackBar(sMessage);
  }

  Future<void> _deleteAllContacts() async {
    if (_isBusy) return;
    setState(() { _isBusy = true; });
    unawaited(_saveSettingsNow());

    log("_deleteAllContacts: about to call FlutterContacts.permissions.request");
    PermissionStatus permission = await FlutterContacts.permissions.request(PermissionType.readWrite);

    int nDeleted = 0;
    int nSkippedMerged = 0;
    String? sError;
    if (permission != PermissionStatus.granted) {
      log("_deleteAllContacts: no permission, status " + permission.toString());
    } else {
      try {
        // Only contacts recorded in the ledger at creation time are deleted, never
        // anything matched by name, so real contacts with the same name are safe.
        final book = await _snapshotAddressBook();
        final ledger = (await _loadLedger()).prunedTo(allRawIds(book));
        final plan = planDelete(ledger, book);
        log("_deleteAllContacts: about to call FlutterContacts.deleteAll for " + plan.contactIdsToDelete.length.toString() + " contact(s)");
        await FlutterContacts.deleteAll(plan.contactIdsToDelete);
        await _saveLedger(plan.remaining);
        nDeleted = plan.rawContactsDeleted;
        nSkippedMerged = plan.skippedMerged;
      } catch (e) {
        log("_deleteAllContacts: error " + e.toString());
        sError = e.toString();
      }
    }
    log("_deleteAllContacts: about to return, nDeleted " + nDeleted.toString());

    if (!mounted) return;
    setState(() { _isBusy = false; });
    String sMessage;
    if (permission != PermissionStatus.granted) {
      sMessage = "Permission to access contacts was denied.";
    } else if (sError != null) {
      sMessage = "Error while deleting contacts: " + sError;
    } else {
      sMessage = "Deleted " + nDeleted.toString() + " fake contact(s).";
      if (nSkippedMerged > 0) {
        sMessage += " " + nSkippedMerged.toString() +
            " were merged with other contacts and were left alone.";
      }
    }
    _showResultSnackBar(sMessage);
  }

  InputDecoration _fieldDecoration(String sLabel) {
    return InputDecoration(
      labelText: sLabel,
      focusedBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.red, width: 5.0),
      ),
      enabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool bCanAct = _settingsLoaded && !_isBusy;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextField(
                    key: keyLastNames,
                    controller: lastNamesController,
                    onChanged: _settingsChanged,
                    enabled: _settingsLoaded,
                    minLines: 1,
                    maxLines: 4,
                    decoration: _fieldDecoration('Last names'),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: keyFirstNames,
                    controller: firstNamesController,
                    onChanged: _settingsChanged,
                    enabled: _settingsLoaded,
                    minLines: 1,
                    maxLines: 4,
                    decoration: _fieldDecoration('First names'),
                  ),
                  const SizedBox(height: 30),
                  TextField(
                    key: keyPhoneNumberTemplate,
                    controller: phoneNumberTemplateController,
                    onChanged: _settingsChanged,
                    enabled: _settingsLoaded,
                    keyboardType: TextInputType.phone,
                    decoration: _fieldDecoration('Phone number template'),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    key: keyEmailAddressTemplate,
                    controller: emailAddressTemplateController,
                    onChanged: _settingsChanged,
                    enabled: _settingsLoaded,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    decoration: _fieldDecoration('Email address template'),
                  ),
                  const SizedBox(height: 40),
                  Center(
                    child: ElevatedButton(
                      onPressed: bCanAct ? () => _createAllContacts() : null,
                      child: Text("Create Fake Contacts"),
                    ),
                  ),
                  const SizedBox(height: 30),
                  Center(
                    child: FilledButton(
                      onPressed: bCanAct ? () => _deleteAllContacts() : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.pink,
                        foregroundColor: Colors.white,
                      ),
                      child: Text("Delete Fake Contacts"),
                    ),
                  ),
                  // Always reserve the spinner's space so the layout doesn't jump.
                  SizedBox(
                    height: 72,
                    child: Center(
                      child: (_isBusy || !_settingsLoaded)
                          ? const CircularProgressIndicator()
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
