plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.thefanciestturtle.decoy_contacts"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.thefanciestturtle.decoy_contacts"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Release builds are left unsigned. The maintainer signs them with
    // tool/sign_release.sh, and F-Droid checks that its own build is the
    // same APK. To install one for testing, sign a copy with the debug key
    // (tool/release_smoke_test.sh does).

    // Leave out Google's dependency metadata: a block in the APK's signature
    // that is encrypted for Google Play, so nobody else can read it. F-Droid
    // rejects APKs that have it. (Only a signing build adds it.)
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
