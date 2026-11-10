package me.billdietrich.fake_contacts

import android.os.Build
import android.view.accessibility.AccessibilityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Flutter ignores the user's accessibility timeout ("Time to take
        // action"), so the app asks for it the way Android's own snack bars
        // do (lib/accessibility_timeout.dart).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "fake_contacts/accessibility")
            .setMethodCallHandler { call, result ->
                if (call.method != "recommendedTimeoutMillis") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val millis = call.argument<Int>("millis")
                if (millis == null) {
                    result.error("bad_argument", "millis missing", null)
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    result.success(millis)
                    return@setMethodCallHandler
                }
                var flags = AccessibilityManager.FLAG_CONTENT_TEXT
                if (call.argument<Boolean>("controls") == true) {
                    flags = flags or AccessibilityManager.FLAG_CONTENT_CONTROLS
                }
                val manager = getSystemService(AccessibilityManager::class.java)
                result.success(manager?.getRecommendedTimeoutMillis(millis, flags) ?: millis)
            }
    }
}
