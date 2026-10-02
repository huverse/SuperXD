import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val signingPropertiesFile = providers.gradleProperty("superxdSigningProperties").orNull?.let { file(it) }
val releaseProperties = Properties()
if (signingPropertiesFile != null) {
    check(signingPropertiesFile.isFile) { "Release signing properties file is missing" }
    signingPropertiesFile.inputStream().use { releaseProperties.load(it) }
}
val releaseKeyFile = releaseProperties.getProperty("storeFile")?.let { value ->
    val candidate = File(value)
    if (candidate.isAbsolute) candidate else File(signingPropertiesFile!!.parentFile, value)
}
val releaseSigningReady = releaseKeyFile?.isFile == true &&
    listOf("keyAlias", "storePassword", "keyPassword").all { !releaseProperties.getProperty(it).isNullOrBlank() }

// [人工决策-2026-09-28 01:15:35] Alpha使用仓库外长期专用签名；缺配置的release直接失败，禁止回退debug签名。
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.startsWith("pre") && it.name.endsWith("ReleaseBuild") }) {
        check(releaseSigningReady) { "Release signing is required: set -PsuperxdSigningProperties to a private properties file outside Git" }
    }
}

android {
    namespace = "com.superxd.superxd"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // 课前提醒用 flutter_local_notifications 定时通知，插件要求开启核心库脱糖。
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.superxd.superxd"
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

    // [人工决策-2026-09-28 01:15:35] 私有Alpha独立包并装，不覆盖开发版数据；后续Alpha复用同一包名和签名。
    flavorDimensions += "distribution"
    productFlavors {
        create("production") { dimension = "distribution" }
        create("alpha") {
            dimension = "distribution"
            applicationIdSuffix = ".alpha"
        }
    }

    signingConfigs {
        create("release") {
            enableV2Signing = true
            enableV3Signing = true
            if (releaseSigningReady) {
                storeFile = releaseKeyFile
                storePassword = releaseProperties.getProperty("storePassword")
                keyAlias = releaseProperties.getProperty("keyAlias")
                keyPassword = releaseProperties.getProperty("keyPassword")
            }
        }
    }
    buildTypes {
        release { signingConfig = signingConfigs.getByName("release") }
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
