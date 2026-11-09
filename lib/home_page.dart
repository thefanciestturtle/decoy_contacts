import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';

import 'contact_actions.dart';
import 'contacts_gateway.dart';
import 'result_messages.dart';
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

  /// Set from a tap on Create or Delete until its result is shown (or it's
  /// cancelled). The buttons are disabled meanwhile.
  bool _isBusy = false;

  /// Set while the dialog asking to go ahead is open. No spinner then: the
  /// app is waiting for the user, not working.
  bool _isConfirming = false;

  void _showResultSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Asks before going ahead. True only if the user taps the action button;
  /// Cancel, Back and tapping outside the dialog all count as no.
  Future<bool> _confirm(Confirmation confirmation) async {
    final bool? bConfirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        // Long text at a large font size scrolls instead of being cut off.
        scrollable: true,
        title: Text(confirmation.title),
        content: Text(confirmation.body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmation.action),
          ),
        ],
      ),
    );
    return bConfirmed ?? false;
  }

  /// The steps Create and Delete share: ignore taps while busy, save the
  /// settings, ask for permission, work out what [action] would do
  /// ([preview]), ask the user to confirm that, run [action], and show the
  /// result.
  ///
  /// [nothingToDo] gives the message to show instead of the dialog when the
  /// preview finds nothing to do, else null. [action] works everything out
  /// again rather than trusting the preview, since the address book can
  /// change while the dialog is open. [name] is used in the log, [doing] in
  /// the error message.
  Future<void> _runContactsAction<P, R>({
    required String name,
    required String doing,
    required Future<P> Function(Settings settings) preview,
    required String? Function(P preview) nothingToDo,
    required Confirmation Function(P preview) confirmation,
    required Future<R> Function(Settings settings) action,
    required String Function(R result) describe,
  }) async {
    if (_isBusy) return;
    setState(() { _isBusy = true; });
    // An earlier result shouldn't linger under the dialog.
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    unawaited(_saveSettingsNow());
    final settings = _settings;

    void finish(String? message) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _isConfirming = false;
      });
      if (message != null) _showResultSnackBar(message);
    }

    log("$name: about to request permission");
    if (!await widget.contacts.requestPermission()) {
      return finish(kPermissionDeniedMessage);
    }

    final P planned;
    try {
      planned = await preview(settings);
    } catch (e) {
      log("$name: error in preview $e");
      return finish(errorMessage(doing, e));
    }
    final sNothingToDo = nothingToDo(planned);
    if (sNothingToDo != null) return finish(sNothingToDo);

    if (!mounted) return;
    setState(() { _isConfirming = true; });
    if (!await _confirm(confirmation(planned))) {
      log("$name: cancelled");
      return finish(null);
    }
    if (!mounted) return;
    setState(() { _isConfirming = false; });

    final R result;
    try {
      result = await action(settings);
    } catch (e) {
      log("$name: error $e");
      return finish(errorMessage(doing, e));
    }
    finish(describe(result));
  }

  Future<void> _createAllContacts() => _runContactsAction(
        name: "_createAllContacts",
        doing: "creating",
        preview: (settings) =>
            previewCreate(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (preview) =>
            preview.toCreate == 0 ? nothingToCreateMessage(preview) : null,
        confirmation: createConfirmation,
        action: (settings) =>
            createFakeContacts(widget.contacts, widget.ledgerStore, settings),
        describe: createdMessage,
      );

  Future<void> _deleteAllContacts() => _runContactsAction(
        name: "_deleteAllContacts",
        doing: "deleting",
        preview: (settings) =>
            previewDelete(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (preview) =>
            preview.toDelete == 0 ? nothingToDeleteMessage(preview) : null,
        confirmation: deleteConfirmation,
        action: (settings) =>
            deleteFakeContacts(widget.contacts, widget.ledgerStore, settings),
        describe: deletedMessage,
      );

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
                      child: ((_isBusy && !_isConfirming) || !_settingsLoaded)
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
