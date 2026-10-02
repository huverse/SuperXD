package com.superxd.superxd

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 满档玻璃的运行时守护：本进程用过满档且上一进程以崩溃、原生崩溃或 ANR 结束时，本版本内限档，升级后重试。
// 档位规则见 lib/theme/campus_glass_tier.dart。
class GlassGuard(private val context: Context) : MethodChannel.MethodCallHandler {
    private val preferences = context.getSharedPreferences("glass_guard", Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "guard" -> result.success(capped())
            "markFull" -> {
                preferences.edit().putBoolean(KEY_USED_FULL, true).apply()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun capped(): Boolean {
        val version = versionCode()
        val failed = preferences.getBoolean(KEY_USED_FULL, false) && previousExitFailed()
        val editor = preferences.edit().remove(KEY_USED_FULL)
        if (failed) editor.putLong(KEY_CAPPED_VERSION, version)
        editor.apply()
        if (failed) Log.w("GlassGuard", "action=cap version=$version")
        return preferences.getLong(KEY_CAPPED_VERSION, -1) == version
    }

    private fun previousExitFailed(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        val reason = context.getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(context.packageName, 0, 1)
            .firstOrNull()?.reason ?: return false
        return reason == ApplicationExitInfo.REASON_CRASH ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            reason == ApplicationExitInfo.REASON_ANR
    }

    private fun versionCode(): Long {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else @Suppress("DEPRECATION") info.versionCode.toLong()
    }

    private companion object {
        const val KEY_USED_FULL = "used_full"
        const val KEY_CAPPED_VERSION = "capped_version"
    }
}
