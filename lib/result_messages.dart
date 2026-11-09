// The messages shown after Create and Delete.

import 'contact_actions.dart';

const String kPermissionDeniedMessage =
    "Permission to access contacts was denied.";

/// [doing] is "creating" or "deleting".
String errorMessage(String doing, Object error) =>
    "Error while $doing contacts: $error";

String createdMessage(CreateResult result) {
  var sMessage = "Created ${result.created} fake contact(s).";
  if (result.alreadyExisted > 0) {
    sMessage += " ${result.alreadyExisted} already existed.";
  }
  if (result.untracked > 0) {
    sMessage += " Warning: ${result.untracked}"
        " could not be recorded and must be deleted by hand.";
  }
  return sMessage;
}

String deletedMessage(DeleteResult result) {
  var sMessage = "Deleted ${result.deleted} fake contact(s).";
  if (result.skippedMerged > 0) {
    sMessage += " ${result.skippedMerged}"
        " were merged with other contacts and were left alone.";
  }
  if (result.skippedChanged > 0) {
    sMessage += " ${result.skippedChanged}"
        " no longer match what this app created (edited, or the app's records"
        " came from another phone) and were left alone.";
  }
  return sMessage;
}
