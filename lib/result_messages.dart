// The text of the dialogs that confirm Create and Delete, and of the
// messages shown afterwards.

import 'contact_actions.dart';

/// More fake contacts than this get a warning in the preview.
const int kManyFakeContacts = 10000;

const String kPermissionDeniedMessage =
    "Permission to access contacts was denied.";

/// The dialog when Android no longer asks for the contacts permission
/// (permanently denied), so it can only be allowed in the app's settings.
/// [verb] is "create" or "delete".
Confirmation permissionSettingsConfirmation(String verb) => (
      title: "Contacts access is off",
      // The steps fit every Android version the app runs on: before
      // Android 10, Contacts is a switch on the Permissions screen.
      body: "To $verb fake contacts, this app needs access to your contacts."
          " In Settings, tap Permissions and allow Contacts.",
      action: "Open settings",
    );

/// Shown if the app's settings couldn't be opened from that dialog.
const String kOpenSettingsFailedMessage = "Couldn't open Settings.";

/// Shown if asking for the contacts permission failed (rather than being
/// answered), e.g. while the app's screen was being recreated.
const String kPermissionRequestFailedMessage =
    "Couldn't ask for permission to access contacts. Try again.";

// The error messages below are plain sentences; the error itself goes to
// the log (see logError). The app can't tell a passing failure from a
// lasting one, and trying again is safe (Create skips what exists, Delete
// checks everything again), so they say to try again; except when the
// phone's storage is full (see storageFull), which trying again doesn't
// help.

/// Shown if reading the address book failed before Create or Delete
/// changed anything.
const String kReadFailedMessage = "Couldn't read your contacts. Try again.";

const String _kStorageFull = "your phone's storage is full";

/// "[done] of [planned] fake contacts", or "[done] fake contacts" if that
/// was all of them.
String _doneOf(int done, int planned) =>
    done == planned ? _fakeContacts(done) : "$done of ${_fakeContacts(planned)}";

/// Shown if Create failed: how far it got if it stopped partway (see
/// [StoppedPartway]).
String createFailedMessage(Object error) => switch (error) {
      StoppedPartway(done: null) => "Couldn't finish creating fake contacts."
          " Some may have been added that this app can't delete.",
      // Delete still finds them while the app stays open.
      StoppedPartway(:final int done, :final planned, recorded: false) =>
        "Created ${_doneOf(done, planned)}, but couldn't save"
            "${done == 1 ? " a record of it. Delete it" : " the list of them. Delete them"}"
            " now, or this app may not be able to later.",
      StoppedPartway(:final int done, :final planned) when done > 0 =>
        storageFull(error)
            ? "Created ${_doneOf(done, planned)} before your phone ran out of"
                " storage."
            : "Created ${_doneOf(done, planned)}, then something went wrong."
                " Try again to create the rest.",
      _ => storageFull(error)
          ? "Couldn't create fake contacts: $_kStorageFull."
          : "Couldn't create fake contacts. Try again.",
    };

/// Shown if Delete failed: how far it got if it stopped partway (see
/// [StoppedPartway]).
String deleteFailedMessage(Object error) => switch (error) {
      StoppedPartway(done: null) => storageFull(error)
          ? "Couldn't finish deleting fake contacts: $_kStorageFull."
          : "Couldn't finish deleting fake contacts. Try again.",
      StoppedPartway(:final int done, :final planned) when done > 0 =>
        storageFull(error)
            ? "Deleted ${_doneOf(done, planned)} before your phone ran out of"
                " storage."
            : "Deleted ${_doneOf(done, planned)}, then something went wrong."
                " Try again to delete the rest.",
      _ => storageFull(error)
          ? "Couldn't delete fake contacts: $_kStorageFull."
          : "Couldn't delete fake contacts. Try again.",
    };

/// Shown when, after the user said yes, Create or Delete would do more than
/// the dialog said, because the address book changed while it was open.
const String kChangedMeanwhileMessage =
    "Your contacts changed meanwhile, so nothing was done. Try again.";

/// What a dialog that asks before Create or Delete says. [action] is the
/// label of the button that goes ahead.
typedef Confirmation = ({String title, String body, String action});

/// "1 [what]" or "[n] [what]s", e.g. "1 fake contact", "2 fake contacts".
String _count(int n, String what) => n == 1 ? "1 $what" : "$n ${what}s";

/// "1 fake contact" or "[n] fake contacts".
String _fakeContacts(int n) => _count(n, "fake contact");

/// Sentences about tracked contacts that Delete leaves alone, in the past
/// tense if [done], else in the future tense.
String _leftAlone(int merged, int changed, {required bool done}) {
  String leftAlone(int n) =>
      done ? (n == 1 ? "was left alone." : "were left alone.") : "will be left alone.";
  var sText = "";
  if (merged > 0) {
    sText += merged == 1
        ? " 1 was merged with another contact and ${leftAlone(1)}"
        : " $merged were merged with other contacts and ${leftAlone(merged)}";
  }
  if (changed > 0) {
    sText += " $changed ${changed == 1 ? "no longer matches" : "no longer match"}"
        " what this app created (edited, or the app's records came from"
        " another phone) and ${leftAlone(changed)}";
  }
  return sText;
}

/// The dialog before Create. Only shown if [CreatePreview.toCreate] > 0.
Confirmation createConfirmation(CreatePreview preview) {
  final n = preview.toCreate;
  final existed = preview.alreadyExisted;
  return (
    title: "Create ${_fakeContacts(n)}?",
    body: [
      if (existed > 0)
        existed == 1
            ? "1 already exists and will be skipped."
            : "$existed already exist and will be skipped.",
      n == 1
          ? "It is added to the contacts on this phone."
          : "They are added to the contacts on this phone.",
    ].join(" "),
    action: "Create",
  );
}

/// The dialog before Delete. Only shown if [DeletePreview.toDelete] > 0.
Confirmation deleteConfirmation(DeletePreview preview) => (
      title: "Delete ${_fakeContacts(preview.toDelete)}?",
      body: "Only contacts this app created are deleted."
          "${_leftAlone(preview.skippedMerged, preview.skippedChanged, done: false)}",
      action: "Delete",
    );

/// What to do when [preview] has no names to combine: which list to fill
/// in.
String enterNamesHint(SettingsPreview preview) {
  assert(preview.combinations == 0, 'both name lists have names');
  final bNoLast = preview.lastNameCount == 0, bNoFirst = preview.firstNameCount == 0;
  if (bNoLast && bNoFirst) return "Enter at least one last name and one first name.";
  return bNoLast ? "Enter at least one last name." : "Enter at least one first name.";
}

/// The preview under the fields: how many fakes the settings make, and the
/// first of them, e.g.
///
///     27 last names × 28 first names = 756 fake contacts.
///     For example: Zoe Zen · +447700900010 · Zoe.Zen@example.com
///
/// With an empty name list it says so the same way, and which list to fill
/// in:
///
///     0 last names × 28 first names = no fake contacts.
///     Enter at least one last name.
///
/// More than [kManyFakeContacts] get a third line that warns it takes long
/// and can slow down the contacts app.
typedef PreviewText = ({
  String text,
  String spoken,
  (int, int)? spokenPhoneNumber,
});

/// The preview's [PreviewText.text]; [PreviewText.spoken], the same for a
/// screen reader (commas instead of the dots, words for the signs); and
/// where the example's phone number is in the spoken text, as (start, end),
/// so the screen reader can be told to read it digit by digit rather than
/// as one big number (null if the example has none).
PreviewText settingsPreviewText(SettingsPreview preview) {
  final spoken = _settingsPreview(preview, spoken: true);
  return (
    text: _settingsPreview(preview, spoken: false).text,
    spoken: spoken.text,
    spokenPhoneNumber: spoken.phoneNumber,
  );
}

({String text, (int, int)? phoneNumber}) _settingsPreview(
    SettingsPreview preview,
    {required bool spoken}) {
  final n = preview.combinations;
  final sSum = [
    _count(preview.lastNameCount, "last name"),
    spoken ? " times " : " × ",
    _count(preview.firstNameCount, "first name"),
    spoken ? " makes " : " = ",
    n == 0 ? "no fake contacts" : _fakeContacts(n),
    n == 1 ? ":" : ".",
  ].join();
  if (n == 0) return (text: "$sSum\n${enterNamesHint(preview)}", phoneNumber: null);
  final sample = preview.sample!;
  final out = StringBuffer("$sSum\n${n == 1 ? "" : "For example: "}");
  (int, int)? phoneNumber;
  var bFirst = true;
  for (final (sPart, bPhone) in [
    (sample.name, false),
    (sample.phone, true),
    (sample.email, false),
  ]) {
    if (sPart.isEmpty) continue;
    if (!bFirst) out.write(spoken ? ", " : " · ");
    bFirst = false;
    if (bPhone) phoneNumber = (out.length, out.length + sPart.length);
    out.write(sPart);
  }
  if (n > kManyFakeContacts) {
    out.write("\nThat many take a long time to create and can slow down"
        " your contacts app.");
  }
  return (text: out.toString(), phoneNumber: phoneNumber);
}

/// The status line: how many fake contacts are on the phone, counting only
/// those the app can confirm (see countFakeContacts). If it can confirm
/// none but tracks some it can't check, it doesn't claim there are none.
String statusMessage(DeletePreview found) {
  if (found.toDelete > 0) return "${_fakeContacts(found.toDelete)} on this phone.";
  return found.skippedMerged + found.skippedChanged > 0
      ? "No fake contacts this app can delete."
      : "No fake contacts on this phone.";
}

/// Shown instead of the dialog when Create has nothing to add. [settings]
/// is what the settings Create used make (see previewSettings), to say
/// which name list is empty, as the preview does. (Create is disabled while
/// a name list is empty, so that case is only a fallback.)
String nothingToCreateMessage(CreatePreview preview, SettingsPreview settings) {
  final existed = preview.alreadyExisted;
  if (existed == 0) {
    // Create makes every combination that doesn't exist yet, so making none
    // with none existing means a name list is empty.
    return "Nothing to create. ${enterNamesHint(settings)}";
  }
  return "Nothing to create. ${_fakeContacts(existed)}"
      " ${existed == 1 ? "already exists" : "already exist"}.";
}

/// Shown instead of the dialog when Delete has nothing to delete.
String nothingToDeleteMessage(DeletePreview preview) =>
    "No fake contacts to delete."
    "${_leftAlone(preview.skippedMerged, preview.skippedChanged, done: true)}";

String createdMessage(CreateResult result) {
  var sMessage = "Created ${_fakeContacts(result.created)}.";
  if (result.alreadyExisted > 0) {
    sMessage += " ${result.alreadyExisted} already existed.";
  }
  if (result.untracked > 0) {
    sMessage += " Warning: ${result.untracked}"
        " could not be recorded and must be deleted by hand.";
  }
  return sMessage;
}

String deletedMessage(DeleteResult result) =>
    "Deleted ${_fakeContacts(result.deleted)}."
    "${_leftAlone(result.skippedMerged, result.skippedChanged, done: true)}";
