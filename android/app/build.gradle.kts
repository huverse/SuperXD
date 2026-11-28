import java.io.File
import java.net.URI
import java.util.Base64
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
        // [人工决策-2026-10-17 23:06:01] 最低 Android 11：本机库用了 UPSERT（SQLite 3.24 起）与窗口函数（3.25 起），
        // 安卓 10 及以下系统自带 3.22 及更早，登录即报 SQL 语法错误（用 3.22.0 源码编的命令行逐句实测）；
        // 用户选定提高最低版本（未选改写 SQL 保 Android 7、随包带新版 SQLite）。新写法的守护见 test/code_conventions_test.dart。
        minSdk = 30
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

// 明文 HTTP 只对教务、中转与本机代理的回环地址放行（安卓网络安全配置，取代清单里全局的 usesCleartextTraffic），其余一律 HTTPS，以后接入的第三方误写成 http 会被系统拦下。
// 只管安卓原生的网络栈（应用更新的安装包下载、网页视图等）；Dart 的请求不看这份配置。清单引用 @xml/network_security_config，由下面的任务按构建生成。
// 教务地址同 lib/edu/kingo_client.dart 的 kingoBase（test/legal_page_test.dart 核对两边一致）。中转地址来自构建参数 --dart-define=SUPERXD_RELAY
// （Flutter 经 -Pdart-defines 交给 Gradle，每项是「名=值」的 base64，逗号分隔），是 http 时放行它的主机，是 https 或没给就不放；写坏了构建失败。
// 另放行回环地址：电影院的本机代理只监听 127.0.0.1（路径带随机口令），系统播放器 ExoPlayer 走安卓原生网络栈、经它取播放清单与密钥
// （人工决策见 lib/toolbox/cinema/cinema_engine.dart 文件头；mpv 用自己的网络栈，不受这份配置管）。
val superxdEduHost = "42.247.18.146"
val superxdLoopbackHost = "127.0.0.1"
val superxdRelayHost: String? = run {
    val relay = project.findProperty("dart-defines")?.toString().orEmpty().split(',').filter { it.isNotEmpty() }
        .map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        .firstOrNull { it.startsWith("SUPERXD_RELAY=") }?.substringAfter('=').orEmpty()
    if (relay.isEmpty()) return@run null
    val uri = URI(relay)
    if (uri.scheme == "https") return@run null
    val host = uri.host
    check(uri.scheme == "http" && host != null && Regex("[A-Za-z0-9.-]+").matches(host)) { "SUPERXD_RELAY should be http(s)://host:port" }
    host
}

abstract class NetworkSecurityConfigTask : DefaultTask() {
    @get:Input abstract val cleartextHosts: ListProperty<String>
    @get:OutputDirectory abstract val outputDirectory: DirectoryProperty

    @TaskAction
    fun write() {
        val file = outputDirectory.get().file("xml/network_security_config.xml").asFile
        file.parentFile.mkdirs()
        val domains = cleartextHosts.get().joinToString("\n") { "        <domain includeSubdomains=\"false\">$it</domain>" }
        file.writeText(
            """
            |<?xml version="1.0" encoding="utf-8"?>
            |<!-- 构建时由 android/app/build.gradle.kts 生成：明文 HTTP 只对教务、中转与本机代理的回环地址放行，其余一律 HTTPS。 -->
            |<network-security-config>
            |    <base-config cleartextTrafficPermitted="false" />
            |    <domain-config cleartextTrafficPermitted="true">
            |$domains
            |    </domain-config>
            |</network-security-config>
            |""".trimMargin(),
        )
    }
}

androidComponents {
    onVariants { variant ->
        val task = tasks.register<NetworkSecurityConfigTask>("superxdNetworkSecurityConfig${variant.name.replaceFirstChar { it.uppercase() }}") {
            cleartextHosts.set(listOfNotNull(superxdEduHost, superxdRelayHost, superxdLoopbackHost).distinct())
        }
        variant.sources.res?.addGeneratedSourceDirectory(task, NetworkSecurityConfigTask::outputDirectory)
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

// 依赖随包登记、应用用不到的 Flutter 资源，拷进安装包时排除（11-18 性能审查 P2-1、P2-5，按审查建议做）：
// - lucide_icons_flutter 在自己的 pubspec 里登记了六个可变字重字体族 Lucide100–Lucide600（原始约 2.9MB、压缩后约 1.3MB），应用只用 Lucide 一族
//   （lib/theme/campus_icons.dart）；Flutter 的图标裁剪只裁有引用的族，没引用的原样打包。FontManifest 里还登记着，但字体只在用到那一族时才读，
//   应用不引用带字重后缀的图标（test/code_conventions_test.dart 守护）。
// - forge2d 给网页版带的 box2d.wasm：安卓走原生的 libbox2d.so，不读它。
// iOS 包照旧带着（Xcode 没有对应的过滤，iOS 包不走应用内更新下载）。
tasks.withType<Copy>().configureEach {
    if (name.startsWith("copyFlutterAssets")) {
        exclude("**/packages/lucide_icons_flutter/assets/build_font/**", "**/packages/forge2d/lib/src/backend/wasm/**")
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // 学习通签到的设备码按 OAID 算（与官方客户端一致）；它自带的存储、电话状态等权限在清单里移除。
    implementation("com.github.gzu-liyujiang:Android_CN_OAID:4.2.17")
    // 胖乖生活登录前的人机验证：网易易盾行为式验证码（闭源 SDK，用户 11-27 选的，人工决策见 lib/toolbox/life/pangguai/pangguai_service.dart；接法见 PangguaiCaptcha.kt）。
    // 它依赖的 Glide 4.9 还拖着旧的 support 库，这里显式要 AndroidX 版的 Glide 4.16（Gradle 取高版本），不开 Jetifier。
    implementation("io.github.yidun:captcha:3.7.1.1")
    implementation("com.github.bumptech.glide:glide:4.16.0")
}
