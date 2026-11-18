// Android build of the app; the C++ engine is compiled into libcaw.so through CMake (engine/CMakeLists.txt).
plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kmandevr.caw"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent once released: updates only install over an app with the same id and signing key.
        applicationId = "com.kmandevr.caw"
        // Android 8.0: every device has AAudio.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // 64-bit ARM: the phones C.A.W targets. Every ABI listed builds the engine again.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                // Only arm64 for the engine too: Flutter's plugin adds the other ABIs back to ndk.abiFilters,
                // which built and packed libcaw.so for them (unused on the phones C.A.W targets).
                abiFilters += listOf("arm64-v8a")
                arguments += listOf("-DCAW_TOOLS=OFF", "-DANDROID_STL=c++_static")
                // CI sets CAW_CCACHE so unchanged engine sources aren't compiled again.
                if (System.getenv("CAW_CCACHE") == "1") {
                    arguments += listOf("-DCMAKE_C_COMPILER_LAUNCHER=ccache", "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
                }
            }
        }
    }

    // Two builds of one app (owner, 2026-11-17: "the GitHub build has everything; the Play build follows Play's
    // rules"), with the same applicationId and key, so either installs over the other. github is today's APK; play
    // drops the install permissions (src/play/AndroidManifest.xml) and the app hides its self-updater
    // (lib/platform/distribution.dart), since Google Play does the updating. Build with --flavor github or play.
    flavorDimensions += "store"
    productFlavors {
        create("github") {
            dimension = "store"
            buildConfigField("boolean", "SELF_UPDATES", "true")
        }
        create("play") {
            dimension = "store"
            // MainActivity answers caw/updates with notImplemented: no PackageInstaller code is reachable.
            buildConfigField("boolean", "SELF_UPDATES", "false")
        }
    }
    buildFeatures {
        buildConfig = true
    }

    externalNativeBuild {
        cmake {
            path = file("../../../engine/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Native libraries are stored compressed, so the APK download is much smaller (the on-device compiler alone
    // is about 78 MB uncompressed); Android unpacks them once at install. Decision in docs/decisions.md.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // The on-device C++ compiler, when CI packaged it (engine/compiler/package-android.sh): the library and its
    // offline data. Without it the app works and says the compiler isn't in this build.
    val compilerPackage = System.getenv("CAW_COMPILER_PACKAGE")
    if (compilerPackage != null) {
        sourceSets.getByName("main") {
            jniLibs.srcDir("$compilerPackage/jniLibs")
            assets.srcDir("$compilerPackage/assets")
        }
    }

    // CI signs every build with one fixed key from repository secrets, so each APK installs over the last.
    // Without those secrets (a local build) the standard debug key is used.
    val keystorePath = System.getenv("CAW_KEYSTORE_PATH")
    signingConfigs {
        if (keystorePath != null) {
            create("caw") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("CAW_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("CAW_KEY_ALIAS")
                keyPassword = System.getenv("CAW_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("caw") ?: signingConfigs.getByName("debug")
        }
        debug {
            signingConfig = signingConfigs.findByName("caw") ?: signingConfigs.getByName("debug")
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
