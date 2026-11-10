import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'contact_actions.dart';
import 'contacts_gateway.dart';
import 'input_checks.dart';
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
  static const Key keyPreview = Key("Preview");

  final TextEditingController lastNamesController = TextEditingController();
  final TextEditingController firstNamesController = TextEditingController();
  final TextEditingController phoneNumberTemplateController = TextEditingController();
  final TextEditingController emailAddressTemplateController = TextEditingController();

  /// The preview's text, and what TalkBack reads instead; null until the
  /// settings are loaded. Worked out once per change of the settings, also
  /// when code changes the fields, but not when only the cursor or the
  /// selection moves.
  final ValueNotifier<PreviewText?> _preview = ValueNotifier(null);
  Settings? _previewSettings;

  /// What the settings as typed allow: Create only with at least one last
  /// and one first name (the preview says why not), and the warnings shown
  /// under the template fields (see input_checks.dart).
  ///
  /// [createBlocked] is why Create can't be used (the same hint as the
  /// preview's), also given to TalkBack on the button; null if it can.
  ({String? createBlocked, String? phoneWarning, String? emailWarning})
      _checks = (createBlocked: null, phoneWarning: null, emailWarning: null);

  /// The email check for the current template. It remembers each name's
  /// result, so with a long name list a keystroke only checks new names.
  EmailTemplateCheck? _emailCheck;

  /// The texts the email warning in [_checks] was worked out from, so a
  /// keystroke in another field doesn't redo it.
  (String, String, String)? _emailCheckedFor;

  /// Called on any change to a text field, the cursor included.
  void _fieldsChanged() {
    if (!_settingsLoaded) return;
    final settings = _settings;
    if (settings == _previewSettings) return;
    _previewSettings = settings;
    final preview = previewSettings(settings);
    _preview.value = settingsPreviewText(preview);
    if (_emailCheck?.template != settings.emailTemplate) {
      _emailCheck = EmailTemplateCheck(settings.emailTemplate);
    }
    final emailInputs = (settings.emailTemplateText, settings.firstNamesText,
        settings.lastNamesText);
    final String? emailWarning = emailInputs == _emailCheckedFor
        ? _checks.emailWarning
        : _emailCheck!.warning(
            firstNames: settings.firstNames, lastNames: settings.lastNames);
    _emailCheckedFor = emailInputs;
    final checks = (
      createBlocked:
          preview.combinations > 0 ? null : enterNamesHint(preview),
      phoneWarning: phoneTemplateWarning(settings.phoneTemplate),
      emailWarning: emailWarning,
    );
    if (checks != _checks) {
      setState(() => _checks = checks);
      // A warning under a template field moves the preview down.
      _scheduleRevealPreview();
    }
  }

  // The text fields are the single source of truth for the settings. They
  // are disabled while Create or Delete runs, so the preview always shows
  // what the action is using. (Disabled, not just read-only: a read-only
  // field can still take the focus, and its keyboard would then open by
  // itself when the action ends; and TalkBack announces a disabled field
  // as disabled, while a read-only one silently ignores typing.)
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
    for (final controller in [
      lastNamesController,
      firstNamesController,
      phoneNumberTemplateController,
      emailAddressTemplateController,
    ]) {
      controller.addListener(_fieldsChanged);
    }
    // The preview may have grown.
    _preview.addListener(_scheduleRevealPreview);
    _phoneFocus.addListener(_scheduleRevealPreview);
    _emailFocus.addListener(_scheduleRevealPreview);
    // The email warning is a live region only while its field has the focus.
    _emailFocus.addListener(_focusChanged);
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
    _phoneFocus.dispose();
    _emailFocus.dispose();
    _preview.dispose();
    super.dispose();
  }

  double _lastBottomInset = 0;

  @override
  void didChangeMetrics() {
    // Like a text field does for its caret: only when the keyboard opens or
    // grows, not when it closes or shrinks (as on turning to landscape), so
    // the page doesn't jump back to the field after the user scrolled away
    // from it.
    if (!mounted) return;
    final double inset = View.of(context).viewInsets.bottom;
    if (inset > _lastBottomInset) _scheduleRevealPreview();
    _lastBottomInset = inset;
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
    _fieldsChanged();
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

  /// Set while a dialog asks the user ([_confirm]), and while the app's
  /// settings open for the user. No spinner then: the app is waiting for
  /// the user, not working.
  bool _waitingForUser = false;

  void _showResultSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Asks before going ahead. True only if the user taps the action button;
  /// Cancel, Back and tapping outside the dialog all count as no.
  Future<bool> _confirm(Confirmation confirmation) async {
    if (!mounted) return false;
    setState(() { _waitingForUser = true; });
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
    if (mounted) setState(() { _waitingForUser = false; });
    return bConfirmed ?? false;
  }

  /// The steps Create and Delete share: ignore taps while busy, save the
  /// settings, ask for permission, work out what [action] would do
  /// ([preview]), ask the user to confirm that, run [action], and show the
  /// result.
  ///
  /// If Android no longer asks for the permission, the dialog
  /// [permissionSettings] offers the app's settings instead; after it the
  /// user taps the button again.
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
    required Confirmation permissionSettings,
    required Future<P> Function(Settings settings) preview,
    required String? Function(Settings settings, P preview) nothingToDo,
    required Confirmation Function(P preview) confirmation,
    required Future<R?> Function(Settings settings, P preview) action,
    required String Function(R result) describe,
  }) async {
    if (_isBusy) return;
    // If a text field has the focus, close the keyboard, so the dialog, the
    // spinner and the result can be seen. (Otherwise the field gets the
    // focus back after the dialog, the keyboard opens again and the page
    // scrolls back up to the field.) Anything else keeps the focus; a
    // focused button still loses it, as it is disabled while busy (see
    // ROADMAP U7).
    final focus = FocusManager.instance.primaryFocus;
    if (_editableOf(focus) != null) focus!.unfocus();
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
        _waitingForUser = false;
      });
      if (message != null) _showResultSnackBar(message);
      unawaited(_refreshStatus());
    }

    log("$name: about to request permission");
    final PermissionAnswer permission;
    try {
      permission = await widget.contacts.requestPermission();
    } catch (e) {
      // E.g. the plugin's "another permission request is in progress".
      log("$name: error requesting permission $e");
      return finish(kPermissionRequestFailedMessage);
    }
    switch (permission) {
      case PermissionAnswer.granted:
        break;
      case PermissionAnswer.denied:
        return finish(kPermissionDeniedMessage);
      case PermissionAnswer.permanentlyDenied:
        if (!await _confirm(permissionSettings)) {
          log("$name: settings not opened");
          return finish(null);
        }
        if (!mounted) return;
        // The buttons stay disabled until the settings have been started,
        // so a quick second tap can't ask again; no spinner meanwhile.
        setState(() { _waitingForUser = true; });
        String? sFailed;
        try {
          await widget.contacts.openSettings();
        } catch (e) {
          log("$name: error opening settings $e");
          sFailed = kOpenSettingsFailedMessage;
        }
        // The status line is updated again when the user comes back.
        return finish(sFailed);
    }

    final P planned;
    try {
      planned = await preview(settings);
    } catch (e) {
      log("$name: error in preview $e");
      // Nothing was changed yet, so don't say "creating" or "deleting".
      return finish(errorMessage("reading", e));
    }
    final sNothingToDo = nothingToDo(settings, planned);
    if (sNothingToDo != null) return finish(sNothingToDo);

    if (!await _confirm(confirmation(planned))) {
      log("$name: cancelled");
      return finish(null);
    }
    if (!mounted) return;

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
        permissionSettings: permissionSettingsConfirmation("create"),
        preview: (settings) =>
            previewCreate(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (settings, preview) => preview.toCreate == 0
            ? nothingToCreateMessage(preview, previewSettings(settings))
            : null,
        confirmation: createConfirmation,
        action: (settings, preview) => createFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toCreate),
        describe: createdMessage,
      );

  Future<void> _deleteAllContacts() => _runContactsAction(
        name: "_deleteAllContacts",
        doing: "deleting",
        permissionSettings: permissionSettingsConfirmation("delete"),
        preview: (settings) =>
            previewDelete(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (_, preview) =>
            preview.toDelete == 0 ? nothingToDeleteMessage(preview) : null,
        confirmation: deleteConfirmation,
        action: (settings, preview) => deleteFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toDelete),
        describe: deletedMessage,
      );

  // While the phone or email template is edited, the preview under the
  // fields should stay above the keyboard: it shows what the template gives.
  final FocusNode _phoneFocus = FocusNode();
  final FocusNode _emailFocus = FocusNode();
  final GlobalKey _previewBox = GlobalKey();
  bool _revealScheduled = false;

  /// The text field that [focus] belongs to, if any.
  static EditableTextState? _editableOf(FocusNode? focus) =>
      focus?.context?.findAncestorStateOfType<EditableTextState>();

  /// Calls [_revealPreview] after the next frame, once the preview and the
  /// keyboard have their new size, if a template field has the focus.
  void _scheduleRevealPreview() {
    if (_revealScheduled || !(_phoneFocus.hasFocus || _emailFocus.hasFocus)) {
      return;
    }
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      _revealPreview();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Scrolls so that the caret of the template field being edited (with
  /// the margin the field keeps clear around it) and the preview below
  /// are in view; if both don't fit, the caret and as much of the preview
  /// as fits. Jumps rather than animates, so it can't be undone by the
  /// field's own animated scroll to its caret: whichever runs first, the
  /// other then finds the caret already in view.
  void _revealPreview() {
    if (!mounted) return;
    final focus = _phoneFocus.hasFocus
        ? _phoneFocus
        : (_emailFocus.hasFocus ? _emailFocus : null);
    final editable = _editableOf(focus);
    final previewContext = _previewBox.currentContext;
    final preview = previewContext?.findRenderObject();
    if (editable == null || previewContext == null || preview is! RenderBox) {
      return;
    }
    final selection = editable.textEditingValue.selection;
    // (Not Scrollable.maybeOf, which would make the preview depend on it.)
    final scrollable = previewContext.findAncestorStateOfType<ScrollableState>();
    final RenderEditable field = editable.renderEditable;
    if (!selection.isValid || scrollable == null || !field.attached ||
        !preview.attached) {
      return;
    }
    // The same margins the field keeps around its caret.
    final EdgeInsets padding = editable.widget.scrollPadding;
    final Rect caret = field.getLocalRectForCaret(selection.extent);
    final double top = caret.top - padding.top;
    final double previewBottom = field
        .globalToLocal(preview.localToGlobal(Offset(0, preview.size.height)))
        .dy;
    // Taller than the view, the caret might not be the part shown.
    final double bottom = math.min(previewBottom + padding.bottom,
        top + scrollable.position.viewportDimension);
    if (bottom <= caret.bottom) return;
    field.showOnScreen(
        rect: Rect.fromLTRB(caret.left, top, caret.right, bottom));
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  /// [warning], if any, is shown under the field like a helper text, but
  /// never cut off. With [bLive], TalkBack reads it out when it appears or
  /// changes (a live region, as Flutter gives error texts; helper texts
  /// have none). The email warning is live only while its field has the
  /// focus: it names the name being typed in a name field, and would be
  /// read out on every keystroke there. (Becoming live as the field gets
  /// the focus may read it once more then.)
  InputDecoration _fieldDecoration(String sLabel,
      {String? warning, bool enabled = true, bool bLive = false}) {
    final theme = Theme.of(context);
    return InputDecoration(
      labelText: sLabel,
      helper: warning == null
          ? null
          : Semantics(
              liveRegion: bLive,
              // Material 3's helper text style, which a helper widget
              // doesn't get by itself.
              child: Text(
                warning,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: enabled
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface.withValues(alpha: 0.38)),
              ),
            ),
      focusedBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.red, width: 5.0),
      ),
      enabledBorder: const OutlineInputBorder(
        borderSide: BorderSide(color: Colors.greenAccent, width: 5.0),
      ),
      // The same look, greyed, while disabled (before the settings load and
      // during Create or Delete); without it the fields would switch to a
      // plain underline on every tap.
      disabledBorder: OutlineInputBorder(
        borderSide: BorderSide(color: Colors.grey.shade400, width: 5.0),
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
                  // Also out of reach of the focus while disabled: with a D-pad
                  // (directional navigation) a disabled TextField can still
                  // take the focus, and its keyboard would open by itself when
                  // the action ends.
                  ExcludeFocus(
                    excluding: !bCanAct,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        TextField(
                          key: keyLastNames,
                          controller: lastNamesController,
                          onChanged: _settingsChanged,
                          enabled: bCanAct,
                          minLines: 1,
                          maxLines: 4,
                          decoration: _fieldDecoration('Last names'),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          key: keyFirstNames,
                          controller: firstNamesController,
                          onChanged: _settingsChanged,
                          enabled: bCanAct,
                          minLines: 1,
                          maxLines: 4,
                          decoration: _fieldDecoration('First names'),
                        ),
                        const SizedBox(height: 30),
                        TextField(
                          key: keyPhoneNumberTemplate,
                          controller: phoneNumberTemplateController,
                          focusNode: _phoneFocus,
                          onChanged: _settingsChanged,
                          enabled: bCanAct,
                          // Not TextInputType.phone: a dial pad has no n.
                          keyboardType: TextInputType.text,
                          autocorrect: false,
                          enableSuggestions: false,
                          // Always read out as it changes: only typing in
                          // this field changes it.
                          decoration: _fieldDecoration('Phone number template',
                              warning: _checks.phoneWarning,
                              enabled: bCanAct,
                              bLive: true),
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          key: keyEmailAddressTemplate,
                          controller: emailAddressTemplateController,
                          focusNode: _emailFocus,
                          onChanged: _settingsChanged,
                          enabled: bCanAct,
                          keyboardType: TextInputType.emailAddress,
                          autocorrect: false,
                          // Suggestions stay on: without them Android gets a
                          // keyboard with no @ key.
                          decoration: _fieldDecoration('Email address template',
                              warning: _checks.emailWarning,
                              enabled: bCanAct,
                              bLive: _emailFocus.hasFocus),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Follows every keystroke. (Not a live region: TalkBack
                  // would read it out after each one.)
                  KeyedSubtree(
                    key: _previewBox,
                    child: ValueListenableBuilder(
                      valueListenable: _preview,
                      builder: (context, preview, _) => preview == null
                          ? const SizedBox.shrink()
                          : Semantics(
                              container: true,
                              // The phone number digit by digit.
                              attributedLabel: AttributedString(preview.spoken,
                                  attributes: [
                                    if (preview.spokenPhoneNumber case (final start, final end))
                                      SpellOutStringAttribute(
                                          range: TextRange(start: start, end: end)),
                                  ]),
                              child: ExcludeSemantics(
                                child: Text(
                                  preview.text,
                                  key: keyPreview,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                                ),
                              ),
                            ),
                    ),
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
                      onPressed: bCanAct && _checks.createBlocked == null
                          ? () => _createAllContacts()
                          : null,
                      // While it can't be used, TalkBack also says why.
                      // (Inside the button, so it joins the button's node.)
                      child: Semantics(
                        hint: _checks.createBlocked,
                        child: const Text("Create Fake Contacts"),
                      ),
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
                      child: ((_isBusy && !_waitingForUser) || !_settingsLoaded)
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
