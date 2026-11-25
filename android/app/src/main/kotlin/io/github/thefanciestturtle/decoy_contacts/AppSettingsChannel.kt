package io.github.thefanciestturtle.decoy_contacts

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Opens this app's page in the system settings, for the app's Dart code
 * (lib/flutter_contacts_gateway.dart).
 *
 * The flutter_contacts plugin does it too, but from the application context
 * with a flag for a new task, so the page joins the task the Settings app
 * already has, along with any screen the user left open there: Back then
 * goes through those screens before it returns to this app. Started from the
 * activity, the page sits on the app's own task: Back returns to the app.
 */
class AppSettingsChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {

    /** On Android's main thread, which starting an activity needs. */
    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    /**
     * `open`: starts the page, and answers nothing. Answers an error if
     * Android has no screen for it, instead of crashing the app.
     */
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            METHOD_OPEN -> try {
                activity.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                        .setData(Uri.fromParts("package", activity.packageName, null)),
                )
                result.success(null)
            } catch (e: Exception) {
                result.error("open_failed", e.toString(), null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        const val CHANNEL = "io.github.thefanciestturtle.decoy_contacts/app_settings"
        const val METHOD_OPEN = "open"
    }
}
