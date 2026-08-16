//import 'dart:convert';
import 'dart:developer';

import 'package:flutter/material.dart';
//import 'dart:math' hide log;
import 'package:shared_preferences/shared_preferences.dart';

//import 'dart:io';
import 'package:flutter_contacts/flutter_contacts.dart';

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
  var lastNames = [];
  var firstNames = [];
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
      sPhoneNumberTemplate = "+2134567nnnn";
      sEmailAddressTemplate = "FIRST.LAST@example.com";
      saveLastNames();
      saveFirstNames();
      savePhoneNumberTemplate();
      saveEmailAddressTemplate();
    } else {
      sListOfLastNames = sStoredLastNames;
      sListOfFirstNames = prefs.getString('sListOfFirstNames') ?? "";
      sPhoneNumberTemplate = prefs.getString('sPhoneNumberTemplate') ?? "";
      sEmailAddressTemplate = prefs.getString('sEmailAddressTemplate') ?? "";
    }

    // create the arrays of names
    lastNames = sListOfLastNames.split(",");
    firstNames = sListOfFirstNames.split(",");

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

  String generatePhoneNumber(String sLastName) {
    log("generatePhoneNumber: called, sPhoneNumberTemplate " + sPhoneNumberTemplate + ", sLastName " + sLastName);
    String sNumber = "";
    int nNext = 0; // next char to use in sLastName

    for (var i = 0; i < sPhoneNumberTemplate.length; i++) {
      //log("generatePhoneNumber: i " + i.toString() + ", sPhoneNumberTemplate[i] " + sPhoneNumberTemplate[i] + ", nNext " + nNext.toString());
      if (sPhoneNumberTemplate[i] != 'n') {
        sNumber += sPhoneNumberTemplate[i];
      } else {
        if (nNext >= sLastName.length)
          sNumber += "0";
        else {
          sNumber +=
          (String.fromCharCode(
              "0".codeUnitAt(0) + (sLastName.codeUnitAt(nNext) % 10)));
          nNext++;
        }
      }
    }

    log("generatePhoneNumber: returning, sNumber " + sNumber);
    return sNumber;
  }


  String generateEmailAddress(String sLastName, String sFirstName) {
    return sEmailAddressTemplate.replaceAll("FIRST", sFirstName).replaceAll("LAST", sLastName);
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
    String? sError;
    if (permission != PermissionStatus.granted) {
      log("_createAllContacts: no permission, status " + permission.toString());
    } else {
      try {
        List<Contact> newContacts = [];
        for (var i = 0; i < lastNames.length; i++) {
          for (var j = 0; j < firstNames.length; j++) {
            newContacts.add(Contact(
                name: Name(first: firstNames[j], last: lastNames[i]),
                phones: [Phone(number: generatePhoneNumber(lastNames[i]))],
                emails: [Email(address: generateEmailAddress(lastNames[i], firstNames[j]))]));
          }
        }
        log("_createAllContacts: about to call FlutterContacts.createAll for " + newContacts.length.toString() + " contact(s)");
        // if a Contact exists already, no error, another of same name is added
        List<String> ids = await FlutterContacts.createAll(newContacts);
        nCreated = ids.length;
      } catch (e) {
        log("_createAllContacts: error " + e.toString());
        sError = e.toString();
      }
    }
    log("_createAllContacts: about to return, nCreated " + nCreated.toString());

    if (!mounted) return;
    setState(() { _isBusy = false; });
    _showResultSnackBar(permission != PermissionStatus.granted
        ? "Permission to access contacts was denied."
        : sError != null
            ? "Error while creating contacts: " + sError
            : "Created " + nCreated.toString() + " fake contact(s).");
  }

  Future<void> _deleteAllContacts() async {
    if (_isBusy) return;
    setState(() { _isBusy = true; });

    log("_deleteAllContacts: about to call FlutterContacts.permissions.request");
    PermissionStatus permission = await FlutterContacts.permissions.request(PermissionType.readWrite);

    int nDeleted = 0;
    String? sError;
    if (permission != PermissionStatus.granted) {
      log("_deleteAllContacts: no permission, status " + permission.toString());
    } else {
      try {
        List<String> idsToDelete = [];
        for (var i = 0; i < lastNames.length; i++) {
          for (var j = 0; j < firstNames.length; j++) {
            String sDisplayName = firstNames[j] + " " + lastNames[i];
            log("_deleteAllContacts: about to call FlutterContacts.getAll(filter: name=" + sDisplayName + ")");
            List<Contact> matches = await FlutterContacts.getAll(filter: ContactFilter.name(sDisplayName));
            for (var c in matches) {
              // ContactFilter.name() does a partial match on Android, so only delete exact matches
              if (c.displayName == sDisplayName && c.id != null) {
                idsToDelete.add(c.id!);
              }
            }
          }
        }
        log("_deleteAllContacts: about to call FlutterContacts.deleteAll for " + idsToDelete.length.toString() + " contact(s)");
        await FlutterContacts.deleteAll(idsToDelete);
        nDeleted = idsToDelete.length;
      } catch (e) {
        log("_deleteAllContacts: error " + e.toString());
        sError = e.toString();
      }
    }
    log("_deleteAllContacts: about to return, nDeleted " + nDeleted.toString());

    if (!mounted) return;
    setState(() { _isBusy = false; });
    _showResultSnackBar(permission != PermissionStatus.granted
        ? "Permission to access contacts was denied."
        : sError != null
            ? "Error while deleting contacts: " + sError
            : "Deleted " + nDeleted.toString() + " fake contact(s).");
  }


  // this gets called every time a char gets changed in the field
  // wasteful to recalculate every time, but doesn't matter
  void _changedLastNames(String sNewValue){
    log("_changedLastNames: called, " + sNewValue);
    sListOfLastNames = sNewValue;
    lastNames = sListOfLastNames.split(",");
    //log("_changedLastNames: lastNames[0] == " + lastNames[0]);
    //log("_changedLastNames: lastNames.toString == " + lastNames.toString());

    saveLastNames();
  }


  // this gets called every time a char gets changed in the field
  // wasteful to recalculate and save every time
  void _changedFirstNames(String sNewValue){
    log("_changedFirstNames: called, " + sNewValue);
    sListOfFirstNames = sNewValue;
    firstNames = sListOfFirstNames.split(",");
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
