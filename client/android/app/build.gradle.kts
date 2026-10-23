import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.vectrixsecurity.frogster"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time on older Androids.
        isCoreLibraryDesugaringEnabled = true
    }

    // The release key never enters the repository. key.properties names the
    // keystore and its passwords (see tool/README-release.md) and is looked
    // for, first found wins, in:
    //   - the folder in FROGSTER_SIGNING_DIR;
    //   - ~/.frogster/signing, which survives fresh clones of the repo;
    //   - android/ of this checkout.
    // Without it a release build falls back to the debug key, which is
    // fine for trying the app out but cannot be updated in place later by a
    // properly signed build.
    val keyFile = listOfNotNull(
        System.getenv("FROGSTER_SIGNING_DIR")?.takeIf { it.isNotBlank() }?.let { File(it, "key.properties") },
        File(System.getProperty("user.home"), ".frogster/signing/key.properties"),
        rootProject.file("key.properties"),
    ).firstOrNull { it.isFile }
    val keyProperties = Properties().apply {
        keyFile?.inputStream()?.use { load(it) }
    }
    // A relative storeFile is taken next to key.properties; one written for
    // the app module ("../x.jks") still works.
    val keyStore = keyProperties.getProperty("storeFile")?.let { name ->
        val candidates = if (File(name).isAbsolute) listOf(File(name))
            else listOf(File(keyFile!!.parentFile, name), file(name))
        candidates.firstOrNull { it.isFile }
            ?: throw GradleException(
                "$keyFile names the keystore '$name', but it is not there. " +
                    "Put the .jks next to key.properties, or remove key.properties to sign with the debug key."
            )
    }
    signingConfigs {
        if (keyStore != null) {
            create("release") {
                storeFile = keyStore
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    defaultConfig {
        applicationId = "com.vectrixsecurity.frogster"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
