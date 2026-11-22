import com.android.build.api.variant.FilterConfiguration

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

// One APK per ABI (flutter build apk --split-per-abi), each with its own
// versionCode: ten times the build number (the number after the + in
// pubspec.yaml's version), plus a digit for the ABI. F-Droid's documentation
// asks for the ABI in the last digit, so that the newest APKs it keeps are
// the newest of every ABI. Flutter's plugin numbers the APKs its own way
// first (ABI * 1000 + the build number); this block runs after it and
// replaces that. It starts from flutter.versionCode, not from the code
// Flutter has already set, as F-Droid's example for the old variant API
// does (that gives 40063, not 63, for x86_64 of build number 6).
// Versions 2.0.0 and 2.0.1 had Flutter's codes, up to 4006, so the build
// number starts at 401: every code must be higher than the ones before it.
// tool/release_lib.sh has the same digits and that rule (RELEASE_MIN_BUILD),
// and checks every release APK's code.
val abiDigits = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)

androidComponents {
    onVariants(selector().all()) { variant ->
        variant.outputs.forEach { output ->
            val abi = output.filters
                .find { it.filterType == FilterConfiguration.FilterType.ABI }
                ?.identifier
            // No ABI: a universal APK (debug builds), left as it is.
            if (abi != null) {
                val digit = abiDigits[abi]
                    ?: throw GradleException(
                        "No versionCode digit for the ABI $abi: add it to abiDigits " +
                            "in android/app/build.gradle.kts and ABI_CODE in tool/release_lib.sh",
                    )
                output.versionCode.set(flutter.versionCode * 10 + digit)
            }
        }
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
