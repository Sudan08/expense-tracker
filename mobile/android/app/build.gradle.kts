import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties holds the release keystore path + passwords. Never
// committed (see the root .gitignore entries added alongside this) and the
// keystore file itself lives outside the repo entirely, under
// ~/.android-keystores/ -- so an accidental `git add -A` can't catch either.
// Absent on a fresh checkout that hasn't generated a keystore yet, which is
// why every read below is guarded rather than assumed to exist: this file
// must still build release with the debug key in that case, not fail.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "np.com.expensetracker.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications (the 22:00 reminder): it
        // uses java.time to work out when "10pm tomorrow" is, and that only
        // exists natively from API 26. Desugaring back-ports it so the app
        // keeps Flutter's default minSdk instead of dropping older handsets
        // for one dependency. Without this the build fails outright at
        // :app:checkDebugAarMetadata.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "np.com.expensetracker.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real release signing once key.properties exists (see above);
            // falls back to the debug key otherwise so a fresh checkout
            // without a generated keystore still builds. A debug-signed
            // release APK installs fine but Android (and Google Play
            // Protect) treats it as an unverified, freely re-signable build
            // -- see docs/EXPENSE_TRACKER_PLAN.md for why that matters here.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

dependencies {
    // Pairs with isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
