package com.superxd.superxd

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.media.MediaDrm
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Base64
import android.util.Log
import com.github.gzuliyujiang.oaid.DeviceID
import com.github.gzuliyujiang.oaid.IGetter
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

// 学习通签到要的设备信息：用户信息接口按这份信息下发人脸签名用的 clientId，设备码按 OAID 算出与官方客户端一致的值。
// 只在用户使用学习通签到时由 Dart 侧按需取，原样交回，不在原生侧保存。
class ChaoxingDeviceChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> {
                val packageName = call.argument<String>("packageName").orEmpty()
                try {
                    result.success(deviceInfo(packageName))
                } catch (error: Exception) {
                    Log.e("ChaoxingDevice", "action=device_info errorType=${error.javaClass.simpleName}", error)
                    result.error("DEVICE_INFO", error.javaClass.simpleName, null)
                }
            }
            "oaid" -> oaid(result)
            else -> result.notImplemented()
        }
    }

    // 各厂商的 OAID 服务异步回调，1 秒没回就当取不到（与参考项目同一口径），由 Dart 侧退回固定随机设备码。
    private fun oaid(result: MethodChannel.Result) {
        val done = AtomicBoolean(false)
        fun finish(value: String) {
            if (done.compareAndSet(false, true)) mainHandler.post { result.success(value) }
        }
        mainHandler.postDelayed({ finish("") }, 1000)
        try {
            if (!DeviceID.supportedOAID(context)) {
                finish("")
                return
            }
            DeviceID.getOAID(context, object : IGetter {
                override fun onOAIDGetComplete(oaid: String) = finish(oaid)
                override fun onOAIDGetError(error: Exception) {
                    Log.e("ChaoxingDevice", "action=oaid errorType=${error.javaClass.simpleName}", error)
                    finish("")
                }
            })
        } catch (error: Exception) {
            Log.e("ChaoxingDevice", "action=oaid errorType=${error.javaClass.simpleName}", error)
            finish("")
        }
    }

    @SuppressLint("HardwareIds")
    private fun deviceInfo(packageName: String): Map<String, Any?> {
        val packageInfo = targetPackage(packageName)
        val metrics = context.resources.displayMetrics
        return mapOf(
            "androidId" to Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID).orEmpty(),
            "fingerprint" to Build.FINGERPRINT.orEmpty(),
            "mediaDrmId" to mediaDrmId(),
            "osVersion" to Build.VERSION.RELEASE.orEmpty(),
            "language" to Locale.getDefault().toLanguageTag(),
            "brand" to Build.BRAND.orEmpty(),
            "board" to Build.BOARD.orEmpty(),
            "hardware" to Build.HARDWARE.orEmpty(),
            "model" to Build.MODEL.orEmpty(),
            "abis" to Build.SUPPORTED_ABIS.joinToString(","),
            "width" to metrics.widthPixels,
            "height" to metrics.heightPixels,
            "density" to metrics.density.toString(),
            // 本机装了对应的学习通客户端时带上它的真实版本与签名，没装由 Dart 侧补默认值。
            "appVersionName" to packageInfo?.versionName,
            "appVersionCode" to packageInfo?.let { versionCode(it) },
            "signatures" to packageInfo?.let { signatureDigest(it) },
        )
    }

    private fun targetPackage(packageName: String): PackageInfo? {
        if (packageName.isEmpty()) return null
        return try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) PackageManager.GET_SIGNING_CERTIFICATES else @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(flags.toLong()))
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.getPackageInfo(packageName, flags)
            }
        } catch (_: PackageManager.NameNotFoundException) {
            null
        }
    }

    private fun versionCode(info: PackageInfo): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode.toString() else @Suppress("DEPRECATION") info.versionCode.toString()

    private fun signatureDigest(info: PackageInfo): String? {
        val signatures = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.signingInfo?.apkContentsSigners
        } else {
            @Suppress("DEPRECATION")
            info.signatures
        } ?: return null
        return signatures.joinToString(",") { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray()).joinToString("") { "%02x".format(it) }
        }
    }

    // Widevine 的设备唯一号；模拟器或不支持的设备上取不到就给空串。
    private fun mediaDrmId(): String = try {
        val widevine = UUID(-0x121074568629b532L, -0x5c37d8232ae2de13L)
        MediaDrm(widevine).let { drm ->
            try {
                Base64.encodeToString(drm.getPropertyByteArray(MediaDrm.PROPERTY_DEVICE_UNIQUE_ID), Base64.NO_WRAP)
            } finally {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) drm.close() else @Suppress("DEPRECATION") drm.release()
            }
        }
    } catch (error: Exception) {
        Log.e("ChaoxingDevice", "action=media_drm errorType=${error.javaClass.simpleName}", error)
        ""
    }
}
