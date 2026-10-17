package com.superxd.superxd

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import androidx.core.content.pm.PackageInfoCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

// 只开放缓存 app_update 文件夹；单独子类，避免与插件声明的 FileProvider 在清单合并时冲突。
class AppUpdateFileProvider : FileProvider()

// 应用内更新的安装通道（lib/device/app_installer_channel.dart）：只接受缓存 app_update 文件夹里的 .apk。
// inspect 读安装包自报的包名、版本号与签名证书，和已装的本应用比对；install 以只读授权交给系统安装器，装不装由用户在系统界面决定。
// 要用户允许本应用「安装未知应用」，openInstallSettings 打开本应用的那一页。
class AppUpdateInstaller(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val signingFlags = PackageManager.GET_SIGNING_CERTIFICATES

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "canInstall" -> result.success(activity.packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
                    result.success(null)
                }
                "inspect" -> result.success(inspect(packageFile(call)))
                "install" -> {
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.app_update", packageFile(call))
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW)
                            .setDataAndType(uri, "application/vnd.android.package-archive")
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e("AppUpdate", "action=${call.method}", error)
            result.error("APP_UPDATE", "安装通道出错", null)
        }
    }

    private fun packageFile(call: MethodCall): File {
        val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
        val root = File(activity.cacheDir, "app_update").canonicalFile
        require(file.parentFile == root && file.isFile && file.name.endsWith(".apk"))
        return file
    }

    private fun inspect(file: File): Map<String, Any> {
        val manager = activity.packageManager
        val archive = requireNotNull(manager.getPackageArchiveInfo(file.path, signingFlags)) { "不是安装包" }
        val installed = manager.getPackageInfo(activity.packageName, signingFlags)
        val archiveSigners = signers(archive)
        return mapOf(
            "samePackage" to (archive.packageName == activity.packageName),
            "versionCode" to PackageInfoCompat.getLongVersionCode(archive),
            "sameSigner" to (archiveSigners.isNotEmpty() && archiveSigners == signers(installed)),
        )
    }

    // 签名证书的 SHA-256 集合：读 signingInfo（轮换过密钥时取当前签名者）。
    private fun signers(info: PackageInfo): Set<String> =
        info.signingInfo?.apkContentsSigners.orEmpty().map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }.toSet()
}
