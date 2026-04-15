import com.android.build.gradle.AppExtension

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.diji_app_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.diji_app_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Support Android 7.0+ (API 24). Do not use flutter.minSdkVersion — it can be 26+ and blocks Android 7.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true  // Required for older Android (e.g. Android 7) when method count is high
        ndk {
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Release APK name includes semver + build number from pubspec (e.g. diji_app_flutter-1.0.2-2-release.apk).
    @Suppress("DEPRECATION")
    applicationVariants.configureEach {
        val variant = this
        outputs.configureEach {
            val output = this as com.android.build.gradle.api.ApkVariantOutput
            output.outputFileName =
                "diji_app_flutter-${variant.versionName}-${variant.versionCode}-${variant.buildType.name}.apk"
        }
    }
}

flutter {
    source = "../.."
}

// Flutter always copies the built APK to `outputs/flutter-apk/app[-abi]-release.apk`. Duplicate those
// files with the pubspec version in the name so `flutter build apk` leaves easy-to-archive artifacts.
tasks.register("copyVersionedReleaseApks") {
    group = "build"
    description =
        "After release assemble, writes diji_app_flutter-<versionName>-<versionCode>-….apk next to Flutter's app-…-release.apk."
    doLast {
        val ext = project.extensions.getByType(AppExtension::class.java)
        val vName = ext.defaultConfig.versionName ?: "unknown"
        val vCode = ext.defaultConfig.versionCode ?: 0
        val flutterApkDir = layout.buildDirectory.dir("outputs/flutter-apk").get().asFile
        if (!flutterApkDir.isDirectory) {
            logger.warn("copyVersionedReleaseApks: missing ${flutterApkDir.path}")
            return@doLast
        }
        flutterApkDir
            .listFiles { f: File ->
                f.isFile &&
                    f.name.endsWith("-release.apk") &&
                    f.name.startsWith("app") &&
                    !f.name.startsWith("diji_app_flutter-")
            }
            ?.forEach { src ->
                val stem = src.name.removeSuffix(".apk")
                val tail = stem.removePrefix("app")
                val dest = flutterApkDir.resolve("diji_app_flutter-${vName}-${vCode}${tail}.apk")
                src.copyTo(dest, overwrite = true)
                logger.lifecycle("Versioned APK: ${dest.name}")
            }
    }
}

afterEvaluate {
    tasks.named("assembleRelease").configure { finalizedBy("copyVersionedReleaseApks") }
}
