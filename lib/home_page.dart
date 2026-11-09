import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import 'contact_actions.dart';
import 'contacts_gateway.dart';
import 'settings_store.dart';

/// How long to wait after the last keystroke before saving the settings.
const Duration kSaveDelay = Duration(milliseconds: 500);

class MyHomePage extends StatefulWidget {
  const MyHomePage({
    super.key,
    required this.title,
    required this.contacts,
    this.settingsStore = const SettingsStore(),
    this.ledgerStore = const LedgerStore(),
  });

  final String title;
  final ContactsGateway contacts;
  final SettingsStore settingsStore;
  final LedgerStore ledgerStore;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {

  static const Key keyLastNames = Key("LastNames");
  static const Key keyFirstNames = Key("FirstNames");
  static const Key keyPhoneNumberTemplate = Key("PhoneNumberTemplate");
  static const Key keyEmailAddressTemplate = Key("EmailAddressTemplate");

  final TextEditingController lastNamesController = TextEditingController();
  final TextEditingController firstNamesController = TextEditingController();
  final TextEditingController phoneNumberTemplateController = TextEditingController();
  final TextEditingController emailAddressTemplateController = TextEditingController();

  // The text fields are the single source of truth for the settings.
  Settings get _settings => Settings(
        lastNamesText: lastNamesController.text,
        firstNamesText: firstNamesController.text,
        phoneTemplateText: phoneNumberTemplateController.text,
        emailTemplateText: emailAddressTemplateController.text,
      );

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

  /// Reads the settings once at startup (the store fills in defaults on
  /// first run).
  Future<void> _loadSettings() async {
    final settings = await widget.settingsStore.load();
    if (!mounted) return;
    lastNamesController.text = settings.lastNamesText;
    firstNamesController.text = settings.firstNamesText;
    phoneNumberTemplateController.text = settings.phoneTemplateText;
    emailAddressTemplateController.text = settings.emailTemplateText;
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
    if (!_settingsLoaded) return; // nothing loaded yet
    await widget.settingsStore.save(_settings);
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
    final settings = _settings;

    log("_createAllContacts: about to request permission");
    final bool bGranted = await widget.contacts.requestPermission();

    CreateResult? result;
    String? sError;
    if (bGranted) {
      try {
        result = await createFakeContacts(widget.contacts, widget.ledgerStore, settings);
      } catch (e) {
        log("_createAllContacts: error $e");
        sError = e.toString();
      }
    }

    if (!mounted) return;
    setState(() { _isBusy = false; });
    String sMessage;
    if (!bGranted) {
      sMessage = "Permission to access contacts was denied.";
    } else if (sError != null) {
      sMessage = "Error while creating contacts: $sError";
    } else {
      sMessage = "Created ${result!.created} fake contact(s).";
      if (result.alreadyExisted > 0) sMessage += " ${result.alreadyExisted} already existed.";
      if (result.untracked > 0) {
        sMessage += " Warning: ${result.untracked}"
            " could not be recorded and must be deleted by hand.";
      }
    }
    _showResultSnackBar(sMessage);
  }

  Future<void> _deleteAllContacts() async {
    if (_isBusy) return;
    setState(() { _isBusy = true; });
    unawaited(_saveSettingsNow());
    final settings = _settings;

    log("_deleteAllContacts: about to request permission");
    final bool bGranted = await widget.contacts.requestPermission();

    DeleteResult? result;
    String? sError;
    if (bGranted) {
      try {
        result = await deleteFakeContacts(widget.contacts, widget.ledgerStore, settings);
      } catch (e) {
        log("_deleteAllContacts: error $e");
        sError = e.toString();
      }
    }

    if (!mounted) return;
    setState(() { _isBusy = false; });
    String sMessage;
    if (!bGranted) {
      sMessage = "Permission to access contacts was denied.";
    } else if (sError != null) {
      sMessage = "Error while deleting contacts: $sError";
    } else {
      sMessage = "Deleted ${result!.deleted} fake contact(s).";
      if (result.skippedMerged > 0) {
        sMessage += " ${result.skippedMerged}"
            " were merged with other contacts and were left alone.";
      }
      if (result.skippedChanged > 0) {
        sMessage += " ${result.skippedChanged}"
            " no longer match what this app created (edited, or the app's records"
            " came from another phone) and were left alone.";
      }
    }
    _showResultSnackBar(sMessage);
  }

  InputDecoration _fieldDecoration(String sLabel) {
    return InputDecoration(
      labelText: sLabel,
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.red, width: 5.0),
      ),
      enabledBorder: const OutlineInputBorder(
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
                      child: const Text("Create Fake Contacts"),
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
                      child: const Text("Delete Fake Contacts"),
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
