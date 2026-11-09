// The text of the dialogs that confirm Create and Delete, and of the
// messages shown afterwards.

import 'contact_actions.dart';

const String kPermissionDeniedMessage =
    "Permission to access contacts was denied.";

/// [doing] is "reading", "creating" or "deleting".
String errorMessage(String doing, Object error) =>
    "Error while $doing contacts: $error";

/// Shown when, after the user said yes, Create or Delete would do more than
/// the dialog said, because the address book changed while it was open.
const String kChangedMeanwhileMessage =
    "Your contacts changed meanwhile, so nothing was done. Try again.";

/// What a dialog that asks before Create or Delete says. [action] is the
/// label of the button that goes ahead.
typedef Confirmation = ({String title, String body, String action});

/// "1 fake contact" or "[n] fake contacts".
String _fakeContacts(int n) => n == 1 ? "1 fake contact" : "$n fake contacts";

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

/// The status line: how many fake contacts are on the phone, counting only
/// those the app can confirm (see countFakeContacts). If it can confirm
/// none but tracks some it can't check, it doesn't claim there are none.
String statusMessage(DeletePreview found) {
  if (found.toDelete > 0) return "${_fakeContacts(found.toDelete)} on this phone.";
  return found.skippedMerged + found.skippedChanged > 0
      ? "No fake contacts this app can delete."
      : "No fake contacts on this phone.";
}

/// Shown instead of the dialog when Create has nothing to add.
String nothingToCreateMessage(CreatePreview preview) {
  final existed = preview.alreadyExisted;
  if (existed == 0) {
    return "Nothing to create. Enter at least one first name and one last name.";
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
