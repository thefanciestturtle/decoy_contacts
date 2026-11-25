package io.github.thefanciestturtle.decoy_contacts

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RawContactsChannel(applicationContext.contentResolver)
            .register(flutterEngine.dartExecutor.binaryMessenger)
        AppSettingsChannel(this).register(flutterEngine.dartExecutor.binaryMessenger)
    }
}
