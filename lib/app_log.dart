// Logging of errors, with their details, for finding out what went wrong.

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Where [logError] writes its text, besides `dart:developer`'s log.
/// Android's log (logcat) by default; tests collect it instead.
@visibleForTesting
void Function(String message) errorLogSink = _toAndroidLog;

// debugPrint is kept in release builds, and its text goes to logcat (tag
// "flutter"), where `adb logcat` and bug reports can find it. Only the system
// and adb can read another app's log lines.
void _toAndroidLog(String message) => debugPrint(message);

/// Logs [error] with its [stackTrace]. [where] says what was being done.
///
/// The app shows the user a plain sentence instead of the error, so this is
/// where the details are kept. Besides `dart:developer`'s log, which only a
/// debugger or DevTools sees, they go to Android's log (see
/// [errorLogSink]). Routine trace lines use `log` alone.
void logError(String where, Object error, [StackTrace? stackTrace]) {
  developer.log('$where: error', error: error, stackTrace: stackTrace, level: 1000);
  errorLogSink('Fake Contacts: $where: $error'
      '${stackTrace == null ? '' : '\n$stackTrace'}');
}
