import 'dart:async';
import 'dart:developer';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'app_log.dart';
import 'app_theme.dart';
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
    this.createChunkSize = kCreateChunkSize,
    this.deleteChunkSize = kDeleteChunkSize,
  });

  final String title;
  final ContactsGateway contacts;
  final SettingsStore settingsStore;
  final LedgerStore ledgerStore;

  /// How many contacts Create and Delete handle per call (tests use small
  /// ones, to see progress with only a few contacts).
  final int createChunkSize;
  final int deleteChunkSize;

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
  static const Key keyProgress = Key("Progress");
  static const Key keyResult = Key("Result");
  static const Key keyCreate = Key("Create");
  static const Key keyDelete = Key("Delete");

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
    // If the app's code still runs (its screen was closed, but the app not
    // killed), a running Create or Delete stops after the chunk it is on,
    // with its ledger saved.
    _stopRequested = true;
    WidgetsBinding.instance.removeObserver(this);
    _saveSettingsNow();
    lastNamesController.dispose();
    firstNamesController.dispose();
    phoneNumberTemplateController.dispose();
    emailAddressTemplateController.dispose();
    _phoneFocus.dispose();
    _emailFocus.dispose();
    _createFocus.dispose();
    _deleteFocus.dispose();
    _stopFocus.dispose();
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
      _inBackground = true;
    }
    if (state == AppLifecycleState.resumed) {
      final bWasInBackground = _inBackground;
      _inBackground = false;
      final held = _heldMessage;
      _heldMessage = null;
      if (held != null) _showResult(held);
      if (bWasInBackground && _settingsLoaded && !_isBusy) {
        unawaited(_refreshStatus());
      }
    }
  }

  /// Whether the app is out of sight (hidden or paused, not only inactive)
  /// since it was last in front.
  bool _inBackground = false;

  /// A result that came while the app was out of sight, shown once it is
  /// back: TalkBack reads it out then (it doesn't while the app is out of
  /// sight), and it is scrolled into view.
  ResultMessage? _heldMessage;

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
    } catch (e, st) {
      // Nothing is shown: the user didn't ask for it.
      logError("_refreshStatus", e, st);
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
  /// cancelled). The buttons are disabled meanwhile, so they lose the
  /// keyboard focus; see [_refocus].
  bool _isBusy = false;

  /// Set while one of the app's dialogs asks the user ([_confirm]), and
  /// while the app's settings open for the user. No spinner then: the app
  /// is waiting for the user, not working. (Android's own permission
  /// dialog still has the spinner behind it.)
  bool _waitingForUser = false;

  /// Set while a Create or Delete of more than one chunk runs: how far it
  /// got. It then shows a progress bar and Stop instead of the spinner.
  ({bool creating, int done, int total})? _progress;

  /// Set by Stop, or Back, while a Create or Delete runs: it stops after the
  /// chunk it is on.
  bool _stopRequested = false;

  final GlobalKey _progressBox = GlobalKey();
  final GlobalKey _resultBox = GlobalKey();

  /// A [ProgressCallback] that shows the progress of a Create
  /// ([creating]) or Delete.
  ProgressCallback _showProgress({required bool creating}) =>
      (int done, int total) {
        if (!mounted) return;
        final bFirst = _progress == null;
        setState(() {
          _progress = (creating: creating, done: done, total: total);
        });
        if (bFirst) _revealAfterFrame(_progressBox);
      };

  /// After the next frame, scrolls what [box] holds into view, if it is
  /// below (or above) the edge, as on a small screen: all of it if it fits,
  /// else as much as fits from its top (Flutter's way with a box taller
  /// than the view).
  void _revealAfterFrame(GlobalKey box) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = box.currentContext;
      final render = context?.findRenderObject();
      if (context == null || !context.mounted || render is! RenderBox ||
          !render.attached) {
        return;
      }
      render.showOnScreen(duration: const Duration(milliseconds: 200));
    });
  }

  // The buttons' focus nodes, to give the keyboard focus back (see
  // [_refocus]).
  final FocusNode _createFocus = FocusNode(debugLabel: "Create");
  final FocusNode _deleteFocus = FocusNode(debugLabel: "Delete");
  final FocusNode _stopFocus = FocusNode(debugLabel: "Stop");

  /// The button of the Create or Delete that is running.
  FocusNode? _actionButton;

  /// The button to give the keyboard focus back to when the running Create
  /// or Delete ends, if any: Create or Delete, whichever had the focus when
  /// it was tapped (a keyboard, D-pad or Switch Access user; a tap on the
  /// screen doesn't focus a button), or the one that is running if Stop had
  /// it. They are disabled meanwhile, so they lose the focus, and nothing
  /// else gives it back. (TalkBack's focus is given back by Flutter itself
  /// after a dialog.)
  FocusNode? _refocus;

  void _requestStop() {
    if (_progress == null || _stopRequested) return;
    log("stop requested");
    // Stop is disabled once tapped, so it loses the focus too.
    if (_stopFocus.hasPrimaryFocus) _refocus = _actionButton;
    setState(() { _stopRequested = true; });
  }

  /// The result of the last Create or Delete, or why it didn't run; shown
  /// under the buttons until the next one starts. Null for none.
  ResultMessage? _result;

  void _showResult(ResultMessage message) {
    if (!mounted) return;
    if (_inBackground) {
      _heldMessage = message;
      return;
    }
    setState(() { _result = message; });
    _revealAfterFrame(_resultBox);
  }

  /// Asks before going ahead. True only if the user taps the action button;
  /// Cancel, Back and tapping outside the dialog all count as no.
  ///
  /// With [keepWaiting], [_waitingForUser] stays set after a yes, for
  /// whatever waits for the user next; finish() clears it.
  Future<bool> _confirm(Confirmation confirmation,
      {bool keepWaiting = false}) async {
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
          FocusRing(
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Cancel"),
            ),
          ),
          FocusRing(
            child: TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmation.action),
            ),
          ),
        ],
      ),
    );
    final bool bYes = bConfirmed ?? false;
    if (mounted && !(keepWaiting && bYes)) {
      setState(() { _waitingForUser = false; });
    }
    return bYes;
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
  /// (by returning null) to do more than the user agreed to. [failed] gives
  /// the message for an error in [action]. [name] is used in the log, which
  /// also gets each error's details. [button] is the button tapped.
  Future<void> _runContactsAction<P, R>({
    required String name,
    required FocusNode button,
    required Confirmation permissionSettings,
    required Future<P> Function(Settings settings) preview,
    required ResultMessage? Function(Settings settings, P preview) nothingToDo,
    required Confirmation Function(P preview) confirmation,
    required Future<R?> Function(Settings settings, P preview) action,
    required ResultMessage Function(R result) describe,
    required ResultMessage Function(Object error) failed,
  }) async {
    if (_isBusy) return;
    // If a text field has the focus, close the keyboard, so the dialog, the
    // spinner and the result can be seen. (Otherwise the field gets the
    // focus back after the dialog, the keyboard opens again and the page
    // scrolls back up to the field.) A focused button gets it back at the
    // end ([_refocus]).
    final focus = FocusManager.instance.primaryFocus;
    if (_editableOf(focus) != null) focus!.unfocus();
    _actionButton = button;
    _refocus = [_createFocus, _deleteFocus]
        .where((node) => node.hasPrimaryFocus)
        .firstOrNull;
    _statusRequest++; // a status count still running is out of date
    _statusOutdated = true;
    setState(() {
      _isBusy = true;
      _result = null;
    });
    unawaited(_saveSettingsNow());
    final settings = _settings;
    // Once that is on screen: the button has let go of the keyboard focus
    // (else, if that happens as a dialog opens, the dialog may not get the
    // focus), and the result is cleared (TalkBack reads a result out when
    // its text changes, so the next one is read out even if it is the same).
    // (No frames are drawn while the app is out of sight; nothing to wait
    // for then.)
    if (SchedulerBinding.instance.framesEnabled) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (!mounted) return;

    void finish(ResultMessage? message) {
      if (!mounted) return;
      // Stop goes away now, so it loses the focus too.
      final refocus = _stopFocus.hasFocus ? _actionButton : _refocus;
      _refocus = null;
      _actionButton = null;
      setState(() {
        _isBusy = false;
        _waitingForUser = false;
        _progress = null;
        _stopRequested = false;
      });
      unawaited(_refreshStatus());
      if (refocus == null) {
        if (message != null) _showResult(message);
        return;
      }
      // Once it is enabled again. (Nothing else can have taken the focus
      // meanwhile: the fields are out of its reach and the buttons
      // disabled, and Stop goes away. Flutter may have moved it to the
      // other button, the one focused before, once enabled again.) Then
      // the result: TalkBack reads out the newly focused button, which
      // would cut short a result that came first.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        refocus.requestFocus();
        if (message != null) _showResult(message);
      });
    }

    log("$name: about to request permission");
    final PermissionAnswer permission;
    try {
      permission = await widget.contacts.requestPermission();
    } catch (e, st) {
      // E.g. the plugin's "no activity available" while the app's screen
      // is being recreated.
      logError("$name, requesting permission", e, st);
      return finish(kPermissionRequestFailedMessage);
    }
    switch (permission) {
      case PermissionAnswer.granted:
        break;
      case PermissionAnswer.denied:
        return finish(kPermissionDeniedMessage);
      case PermissionAnswer.permanentlyDenied:
        // The buttons stay disabled until the settings have been started,
        // so a quick second tap can't ask again; no spinner meanwhile.
        if (!await _confirm(permissionSettings, keepWaiting: true)) {
          log("$name: settings not opened");
          return finish(null);
        }
        ResultMessage? failedToOpen;
        try {
          await widget.contacts.openSettings();
        } catch (e, st) {
          logError("$name, opening settings", e, st);
          failedToOpen = kOpenSettingsFailedMessage;
        }
        // The status line is updated again when the user comes back.
        return finish(failedToOpen);
    }

    final P planned;
    try {
      planned = await preview(settings);
    } catch (e, st) {
      logError("$name, preview", e, st);
      // Nothing was changed yet, so don't say "create" or "delete".
      return finish(kReadFailedMessage);
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
    } catch (e, st) {
      if (e is StoppedPartway) {
        // How far it got; and what stopped it, and where.
        logError("$name, ${e.progress}", e.cause, e.stackTrace);
      } else {
        logError(name, e, st);
      }
      return finish(failed(e));
    }
    finish(result == null ? kChangedMeanwhileMessage : describe(result));
  }

  Future<void> _createAllContacts() => _runContactsAction(
        name: "_createAllContacts",
        button: _createFocus,
        permissionSettings: permissionSettingsConfirmation("create"),
        preview: (settings) =>
            previewCreate(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (settings, preview) => preview.toCreate == 0
            ? nothingToCreateMessage(preview, previewSettings(settings))
            : null,
        confirmation: createConfirmation,
        action: (settings, preview) => createFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toCreate,
            chunkSize: widget.createChunkSize,
            onProgress: _showProgress(creating: true),
            stopRequested: () => _stopRequested),
        describe: createdMessage,
        failed: createFailedMessage,
      );

  Future<void> _deleteAllContacts() => _runContactsAction(
        name: "_deleteAllContacts",
        button: _deleteFocus,
        permissionSettings: permissionSettingsConfirmation("delete"),
        preview: (settings) =>
            previewDelete(widget.contacts, widget.ledgerStore, settings),
        nothingToDo: (_, preview) =>
            preview.toDelete == 0 ? nothingToDeleteMessage(preview) : null,
        confirmation: deleteConfirmation,
        action: (settings, preview) => deleteFakeContacts(
            widget.contacts, widget.ledgerStore, settings,
            atMost: preview.toDelete,
            chunkSize: widget.deleteChunkSize,
            onProgress: _showProgress(creating: false),
            stopRequested: () => _stopRequested),
        describe: deletedMessage,
        failed: deleteFailedMessage,
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
  ///
  /// The look is the theme's: outlined fields (see appTheme), greyed while
  /// disabled (before the settings load, and during Create or Delete).
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool bCanAct = _settingsLoaded && !_isBusy;

    // While Create or Delete runs, Back doesn't close the app, which would
    // cut it off without a result (Android finishes the call that is
    // running; only the next Create or Delete would record what it made).
    // With progress shown, Back stops it, as Stop does; before that (while
    // the address book is read, or for an action of one chunk) it ignores
    // Back for a moment.
    return PopScope(
      canPop: !_isBusy,
      onPopInvokedWithResult: (bDidPop, _) {
        if (!bDidPop) _requestStop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title),
        ),
        body: SafeArea(
          // From the top (not centred), so what shows below the buttons
          // (progress, results) can grow without moving anything above it.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Center(
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
                    // Create is the app's main action; Delete, which removes
                    // contacts, is in the error colour.
                    Center(
                      child: FocusRing(
                        child: FilledButton(
                          key: keyCreate,
                          focusNode: _createFocus,
                          onPressed: bCanAct && _checks.createBlocked == null
                              ? () => _createAllContacts()
                              : null,
                          // While it can't be used, TalkBack also says why.
                          // (Inside the button, so it joins the button's
                          // node.)
                          child: Semantics(
                            hint: _checks.createBlocked,
                            child: const Text("Create Fake Contacts"),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    Center(
                      child: FocusRing(
                        child: OutlinedButton(
                          key: keyDelete,
                          focusNode: _deleteFocus,
                          onPressed:
                              bCanAct ? () => _deleteAllContacts() : null,
                          style: destructiveButtonStyle(
                              Theme.of(context).colorScheme),
                          child: const Text("Delete Fake Contacts"),
                        ),
                      ),
                    ),
                    _buildBelowButtons(context),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Under the buttons: while a Create or Delete of more than one chunk
  /// runs, how far it got, and Stop; while busy otherwise, the spinner;
  /// afterwards, the result ([_buildResult]).
  ///
  /// The progress's space is always reserved, and the result shows in it
  /// (growing below it if longer), so the page keeps about the same height
  /// from one to the next: scrolled to its end, as on a small screen, a
  /// page that gets shorter moves the buttons down.
  Widget _buildBelowButtons(BuildContext context) {
    final progress = _progress;
    final bSpinner = progress == null &&
        ((_isBusy && !_waitingForUser) || !_settingsLoaded);
    return Stack(
      alignment: Alignment.topCenter,
      children: <Widget>[
        // Out of sight, of TalkBack's reach, of taps and of the focus while
        // there is no progress; but always taking up its space.
        ExcludeFocus(
          excluding: progress == null,
          child: Visibility(
            visible: progress != null,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: Padding(
              key: _progressBox,
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  // TalkBack reads the count; the bar would add a bare
                  // number ("41"). Not a live region: it would be read out
                  // after every chunk, a few times a second; the result is
                  // read out at the end.
                  ExcludeSemantics(
                    child: LinearProgressIndicator(
                        // (Never indeterminate: its animation would run
                        // unseen.)
                        value: progress == null || progress.total == 0
                            ? 0
                            : progress.done / progress.total),
                  ),
                  const SizedBox(height: 8),
                  Text(
                      progress == null
                          ? ""
                          : progressText(
                              creating: progress.creating,
                              done: progress.done,
                              total: progress.total),
                      key: progress == null ? null : keyProgress,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Center(
                    child: FocusRing(
                      child: OutlinedButton(
                        focusNode: _stopFocus,
                        onPressed: progress == null || _stopRequested
                            ? null
                            : _requestStop,
                        child: Text(_stopRequested ? "Stopping…" : "Stop"),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        _buildResult(context),
        if (bSpinner)
          const Positioned.fill(
              child: Center(child: CircularProgressIndicator())),
      ],
    );
  }

  /// The result ([_result]), as a live region, so TalkBack reads each new
  /// one out (they are new: each is cleared when the next Create or Delete
  /// starts). Always there, empty without a result, so TalkBack notices
  /// the change. Not a timed message: it stays, and covers nothing. A
  /// failure has an error icon (not read out: the text says so) and the
  /// error colour.
  Widget _buildResult(BuildContext context) {
    final result = _result;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyLarge;
    return Semantics(
      container: true,
      liveRegion: true,
      child: KeyedSubtree(
        key: _resultBox,
        child: result == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (result.isError) ...[
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.error,
                          // As high as a line of the text, at any font size.
                          // (Android scales large fonts nonlinearly: the
                          // size, not the line.)
                          size: MediaQuery.textScalerOf(context)
                                  .scale(style?.fontSize ?? 16) *
                              (style?.height ?? 1.5)),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(result.text,
                          key: keyResult,
                          style: result.isError
                              ? style?.copyWith(color: theme.colorScheme.error)
                              : style),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
