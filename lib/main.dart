//import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
//import 'dart:math' hide log;
import 'package:shared_preferences/shared_preferences.dart';

//import 'dart:io';
import 'package:flutter_contacts/flutter_contacts.dart';

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
        primarySwatch: Colors.blue,
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



class _MyHomePageState extends State<MyHomePage> {

  String sListOfLastNames = "";
  String sListOfFirstNames = "";
  List<String> lastNames = [];
  List<String> firstNames = [];
  String sPhoneNumberTemplate = "";
  String sEmailAddressTemplate = "";

  Key keyLastNames = Key("LastNames");
  Key keyFirstNames = Key("FirstNames");
  Key keyPhoneNumberTemplate = Key("PhoneNumberTemplate");
  Key keyEmailAddressTemplate = Key("EmailAddressTemplate");

  TextEditingController lastNamesController = TextEditingController();
  TextEditingController firstNamesController = TextEditingController();
  TextEditingController phoneNumberTemplateController = TextEditingController();
  TextEditingController emailAddressTemplateController = TextEditingController();


  Future<void> getStoredSettings() async {
    log("getStoredSettings: called");
    SharedPreferences prefs;

    prefs = await SharedPreferences.getInstance();
    final String? sStoredLastNames = prefs.getString('sListOfLastNames');
    //log("getStoredSettings: retrieved last names " + (sStoredLastNames ?? "null"));
    if (sStoredLastNames == null) {
      sListOfLastNames = "Zen,Zaragoza,Zabinski,Zimmermann,Zapata,Zona,Zidane,Zeiss,Zimmer,Zaal,Zaman,Zambrano,Zanetti,Zangari,Zappa,Zavala,Zawisza,Zeegers,Zelenka,Zellweger,Zeni,Zhang,Zhao,Zheng,Zhou,Ziegler,Zima";
      sListOfFirstNames = "Zoe,Zach,Zbigniew,Zaire,Zero,Zakai,Zamir,Zan,Zanna,Zareen,Zeb,Zeki,Zelda,Zella,Zeno,Zephyr,Zhen,Zhi,Zhong,Zhu,Ziba,Ziggy,Zion,Zola,Zolyan,Zora,Zsazsa,Zuzana";
      sPhoneNumberTemplate = kDefaultPhoneTemplate;
      sEmailAddressTemplate = kDefaultEmailTemplate;
      saveLastNames();
      saveFirstNames();
      savePhoneNumberTemplate();
      saveEmailAddressTemplate();
    } else {
      sListOfLastNames = sStoredLastNames;
      sListOfFirstNames = prefs.getString('sListOfFirstNames') ?? "";
      sPhoneNumberTemplate = prefs.getString('sPhoneNumberTemplate') ?? "";
      sEmailAddressTemplate = prefs.getString('sEmailAddressTemplate') ?? "";
      if (sPhoneNumberTemplate == kLegacyDefaultPhoneTemplate) {
        // old default was in Algeria's real country code (+213)
        sPhoneNumberTemplate = kDefaultPhoneTemplate;
        savePhoneNumberTemplate();
      }
    }

    // create the arrays of names
    lastNames = parseNames(sListOfLastNames);
    firstNames = parseNames(sListOfFirstNames);

    lastNamesController.text = sListOfLastNames;
    // this gets called for every keypress in the field, but no info about what's happening
    //lastNamesController.addListener(() {
    //  log("lastNamesController.Listener: called");
    //});
    firstNamesController.text = sListOfFirstNames;
    phoneNumberTemplateController.text = sPhoneNumberTemplate;
    emailAddressTemplateController.text = sEmailAddressTemplate;
  }

  void saveLastNames() async {
    log("saveLastNames: called");

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    log("saveLastNames: sListOfLastNames " + sListOfLastNames);
    await prefs.setString("sListOfLastNames", sListOfLastNames);
  }

  void saveFirstNames() async {
    log("saveFirstNames: called");

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("sListOfFirstNames", sListOfFirstNames);
  }

  void savePhoneNumberTemplate() async {
    log("savePhoneNumberTemplate: called");

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("sPhoneNumberTemplate", sPhoneNumberTemplate);
  }

  void saveEmailAddressTemplate() async {
    log("saveEmailAddressTemplate: called");

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString("sEmailAddressTemplate", sEmailAddressTemplate);
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


  // this gets called every time a char gets changed in the field
  // wasteful to recalculate every time, but doesn't matter
  void _changedLastNames(String sNewValue){
    log("_changedLastNames: called, " + sNewValue);
    sListOfLastNames = sNewValue;
    lastNames = parseNames(sListOfLastNames);
    //log("_changedLastNames: lastNames[0] == " + lastNames[0]);
    //log("_changedLastNames: lastNames.toString == " + lastNames.toString());

    saveLastNames();
  }


  // this gets called every time a char gets changed in the field
  // wasteful to recalculate and save every time
  void _changedFirstNames(String sNewValue){
    log("_changedFirstNames: called, " + sNewValue);
    sListOfFirstNames = sNewValue;
    firstNames = parseNames(sListOfFirstNames);
    //log("_changedFirstNames: firstNames[0] == " + firstNames[0]);
    //log("_changedFirstNames: firstNames.toString == " + firstNames.toString());

    saveFirstNames();
  }

  // this gets called every time a char gets changed in the field
  void _changedPhoneNumberTemplate(String sNewValue){
    log("_changedPhoneNumberTemplate: called, " + sNewValue);
    sPhoneNumberTemplate = sNewValue;

    savePhoneNumberTemplate();
  }

  // this gets called every time a char gets changed in the field
  void _changedEmailAddressTemplate(String sNewValue){
    log("_changedEmailAddressTemplate: called, " + sNewValue);
    sEmailAddressTemplate = sNewValue;

    saveEmailAddressTemplate();
  }

  @override
  Widget build(BuildContext context) {

    getStoredSettings();  // need to wait for it, but can't !!!
    //Future.wait(getStoredSettings());   // illegal ?
    //final int number = waitFor<int>(getStoredSettings());

    return Scaffold(
      appBar: AppBar(
        // Here we take the value from the MyHomePage object that was created by
        // the App.build method, and use it to set our appbar title.
        title: Text(widget.title),
      ),
      body: Center(
        // Center is a layout widget. It takes a single child and positions it
        // in the middle of the parent.
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            TextFormField(
              key: keyLastNames,    // want to set value using this key, but can't
              onChanged: _changedLastNames,
              controller: lastNamesController,
              maxLines: 1,
              decoration: new InputDecoration(
                labelText: 'Last names',
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.red, width: 5.0),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
                ),
              ),
            ),
            SizedBox(
              width: 10,
              height:20,
            ),
            TextFormField(
              key: keyFirstNames,
              onChanged: _changedFirstNames,
              controller: firstNamesController,
              maxLines: 1,
              decoration: new InputDecoration(
                labelText: 'First names',
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.red, width: 5.0),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
                ),
              ),
            ),
            SizedBox(
              width: 10,
              height:30,
            ),
            TextFormField(
              key: keyPhoneNumberTemplate,
              onChanged: _changedPhoneNumberTemplate,
              controller: phoneNumberTemplateController,
              maxLines: 1,
              decoration: new InputDecoration(
                labelText: 'Phone number template',
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.red, width: 5.0),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
                ),
              ),
            ),
            SizedBox(
              width: 10,
              height:20,
            ),
            TextFormField(
              key: keyEmailAddressTemplate,
              onChanged: _changedEmailAddressTemplate,
              maxLines: 1,
              controller: emailAddressTemplateController,
              decoration: new InputDecoration(
                labelText: 'Email address template',
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.red, width: 5.0),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
                ),
              ),
            ),
            SizedBox(
              width: 10,
              height:40,
            ),
            ElevatedButton(
              onPressed: _isBusy ? null : () => _createAllContacts(),
              child: Text("Create Fake Contacts"),
            ),
            SizedBox(
              width: 10,
              height:30,
            ),
            ElevatedButton(
              onPressed: _isBusy ? null : () => _deleteAllContacts(),
              child: Text("Delete Fake Contacts"),
              style: ButtonStyle(backgroundColor: WidgetStateProperty.all<Color>(Colors.pink) ),
            ),
            SizedBox(
              width: 10,
              height:20,
            ),
            if (_isBusy)
              CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
