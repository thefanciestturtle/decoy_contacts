// The user's accessibility timeout ("Time to take action" in Android's
// accessibility settings), which Flutter doesn't apply by itself.

import 'dart:math' as math;

import 'package:flutter/services.dart';

import 'app_log.dart';

const MethodChannel _channel = MethodChannel('fake_contacts/accessibility');

/// How long to show something meant to show for [duration]: longer if the
/// user asked for more time in Android's accessibility settings (Android 10
/// and later), as Android's own snack bars do. [hasControls] says whether it
/// has something to tap (then "Time to take action" counts); otherwise only
/// a timeout for reading counts.
///
/// [duration] if that can't be found out, e.g. in tests without the
/// Android side.
Future<Duration> recommendedTimeout(Duration duration,
    {required bool hasControls}) async {
  try {
    final millis = await _channel.invokeMethod<int>('recommendedTimeoutMillis',
        {'millis': duration.inMilliseconds, 'controls': hasControls});
    if (millis == null) return duration;
    return Duration(milliseconds: math.max(millis, duration.inMilliseconds));
  } on MissingPluginException {
    return duration;
  } catch (e, st) {
    logError("recommendedTimeout", e, st);
    return duration;
  }
}
