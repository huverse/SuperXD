package com.superxd.superxd

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.PixelCopy
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 满档玻璃的运行时守护：本进程用过满档且上一进程以崩溃、原生崩溃或 ANR 结束时，本版本内限档，升级后重试；
// 用户在外观页点「完整」时 retry 解除限档。档位规则见 lib/theme/campus_glass_tier.dart。
// probe：玻璃显示自检，截 Flutter 画面里给定的一块（物理像素），返回近乎纯黑的像素占比；判定与处理在 lib/theme/campus_glass_probe.dart。
class GlassGuard(private val context: Context) : MethodChannel.MethodCallHandler {
    private val preferences = context.getSharedPreferences("glass_guard", Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "guard" -> result.success(capped())
            "markFull" -> {
                preferences.edit().putBoolean(KEY_USED_FULL, true).apply()
                result.success(null)
            }
            "probe" -> probe(call, result)
            "retry" -> {
                preferences.edit().remove(KEY_CAPPED_VERSION).apply()
                Log.i("GlassGuard", "action=retry")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // Flutter 画在 SurfaceView 上，整窗截图拿不到它的内容，要对那块 Surface 截；找不到（如改成纹理视图）就截整窗。
    private fun probe(call: MethodCall, result: MethodChannel.Result) {
        val activity = context as? Activity ?: return result.success(null)
        val left = call.argument<Int>("left") ?: return result.success(null)
        val top = call.argument<Int>("top") ?: return result.success(null)
        val width = call.argument<Int>("width") ?: return result.success(null)
        val height = call.argument<Int>("height") ?: return result.success(null)
        val surface = surfaceOf(activity.window.decorView)
        val bounds = Rect(0, 0, surface?.width ?: activity.window.decorView.width, surface?.height ?: activity.window.decorView.height)
        val area = Rect(left, top, left + width, top + height)
        if (!area.intersect(bounds) || area.isEmpty) return result.success(null)
        val bitmap = Bitmap.createBitmap(area.width(), area.height(), Bitmap.Config.ARGB_8888)
        val done = PixelCopy.OnPixelCopyFinishedListener { code ->
            if (code != PixelCopy.SUCCESS) {
                Log.w("GlassGuard", "action=probe copy=$code")
                bitmap.recycle()
                result.success(null)
                return@OnPixelCopyFinishedListener
            }
            val dark = darkShare(bitmap)
            bitmap.recycle()
            result.success(dark)
        }
        val handler = Handler(Looper.getMainLooper())
        try {
            if (surface != null) PixelCopy.request(surface, area, bitmap, done, handler)
            else PixelCopy.request(activity.window, area, bitmap, done, handler)
        } catch (error: IllegalArgumentException) {
            Log.w("GlassGuard", "action=probe failed", error)
            bitmap.recycle()
            result.success(null)
        }
    }

    private fun surfaceOf(view: View): SurfaceView? {
        if (view is SurfaceView) return view
        if (view !is ViewGroup) return null
        for (index in 0 until view.childCount) surfaceOf(view.getChildAt(index))?.let { return it }
        return null
    }

    // 隔行隔列取样，三个通道都不超过 12 的算近乎纯黑；深色配色的栏底与上面的图标、文字都不在这个范围里。
    private fun darkShare(bitmap: Bitmap): Double {
        val step = 4
        val row = IntArray(bitmap.width)
        var dark = 0
        var total = 0
        for (y in 0 until bitmap.height step step) {
            bitmap.getPixels(row, 0, bitmap.width, 0, y, bitmap.width, 1)
            for (x in 0 until bitmap.width step step) {
                val pixel = row[x]
                val red = (pixel shr 16) and 0xFF
                val green = (pixel shr 8) and 0xFF
                val blue = pixel and 0xFF
                if (red <= 12 && green <= 12 && blue <= 12) dark++
                total++
            }
        }
        return if (total == 0) 0.0 else dark.toDouble() / total
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
        val reason = context.getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(context.packageName, 0, 1)
            .firstOrNull()?.reason ?: return false
        return reason == ApplicationExitInfo.REASON_CRASH ||
            reason == ApplicationExitInfo.REASON_CRASH_NATIVE ||
            reason == ApplicationExitInfo.REASON_ANR
    }

    private fun versionCode(): Long = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode

    private companion object {
        const val KEY_USED_FULL = "used_full"
        const val KEY_CAPPED_VERSION = "capped_version"
    }
}
