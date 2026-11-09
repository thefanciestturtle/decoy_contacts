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
  static const Key keyStatus = Key("Status");

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
    // Contacts may have been changed in another app meanwhile. (Not after
    // only "inactive", e.g. for the notification shade or a system dialog.)
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) {
      _wasInBackground = true;
    }
    if (state == AppLifecycleState.resumed && _wasInBackground) {
      _wasInBackground = false;
      if (_settingsLoaded && !_isBusy) unawaited(_refreshStatus());
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
    unawaited(_refreshStatus());
  }

  bool _wasInBackground = false;

  /// The status line ([statusMessage]), or null to show none: no permission,
  /// or the address book couldn't be read yet.
  String? _status;

  /// Counts [_refreshStatus] calls, so only the latest one's answer is used.
  int _statusRequest = 0;

  /// Set when a Create or Delete starts, cleared once a count after it is
  /// shown: until then the line may show a count from before it.
  bool _statusOutdated = false;

  /// Updates the status line, if the contacts permission was already
  /// granted. Never asks for the permission. Runs at startup, after each
  /// Create or Delete tap, and when the app comes back to the foreground.
  ///
  /// If counting fails, the last count stays, since it may only be a
  /// passing problem; but not if a Create or Delete may have changed it
  /// since ([_statusOutdated]).
  Future<void> _refreshStatus() async {
    final int request = ++_statusRequest;
    String? status;
    var bFailed = false;
    try {
      if (await widget.contacts.hasPermission()) {
        status = statusMessage(
            await countFakeContacts(widget.contacts, widget.ledgerStore));
      }
    } catch (e) {
      log("_refreshStatus: error $e");
      bFailed = true;
    }
    // A Create or Delete that started meanwhile refreshes it again when done.
    if (!mounted || request != _statusRequest) return;
    if (bFailed && !_statusOutdated) return;
    setState(() {
      _status = status;
      if (!bFailed) _statusOutdated = false;
    });
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
  /// change while the dialog is open; it gets the preview so it can refuse
  /// (by returning null) to do more than the user agreed to. [name] is used
  /// in the log, [doing] in the message for an error in [action].
  Future<void> _runContactsAction<P, R>({
    required String name,
    required String doing,
    required Future<P> Function(Settings settings) preview,
    required String? Function(P preview) nothingToDo,
    required Confirmation Function(P preview) confirmation,
    required Future<R?> Function(Settings settings, P preview) action,
    required String Function(R result) describe,
  }) async {
    if (_isBusy) return;
    _statusRequest++; // a status count still running is out of date
    _statusOutdated = true;
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
      unawaited(_refreshStatus());
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
      // Nothing was changed yet, so don't say "creating" or "deleting".
      return finish(errorMessage("reading", e));
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

    final R? result;
    try {
      result = await action(settings, planned);
    } catch (e) {
      log("$name: error $e");
      return finish(errorMessage(doing, e));
    }
    finish(result == null ? kChangedMeanwhileMessage : describe(result));
  }

  Future<void> _createAllContacts() => _runContactsAction(
        name: "_createAllContacts",
        doing: "creating",
        preview: (settings) =>
            previewCreate(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (preview) =>
            preview.toCreate == 0 ? nothingToCreateMessage(preview) : null,
        confirmation: createConfirmation,
        action: (settings, preview) => createFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toCreate),
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
        action: (settings, preview) => deleteFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toDelete),
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
                  const SizedBox(height: 32),
                  // Always there, empty without a count, so the buttons
                  // don't move when it appears. (Not a live region: TalkBack
                  // would read it over the result message.)
                  Text(
                    _status ?? "",
                    key: keyStatus,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
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
