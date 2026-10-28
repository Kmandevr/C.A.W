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
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DCAW_TOOLS=OFF", "-DANDROID_STL=c++_static")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("../../../engine/CMakeLists.txt")
            version = "3.22.1"
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
