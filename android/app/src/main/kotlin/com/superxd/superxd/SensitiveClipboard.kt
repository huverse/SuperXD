package com.superxd.superxd

import android.app.Activity
import android.content.ClipData
import android.content.ClipboardManager
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 复制恢复码这类敏感内容（通道 superxd/sensitive_clipboard，Dart 侧 lib/page/sensitive_clipboard.dart；人工决策见 lib/domain/app_account.dart 的 19:18:31 那条）：
// 标成敏感内容（ClipDescription.EXTRA_IS_SENSITIVE，Android 13 起剪贴板预览与输入法建议不显示原文；更早的系统不认这个标记，照常复制），
// 到点清掉，而且只在剪贴板里还是这一串时才清（用户之后自己复制了别的就不动）。Android 10 起应用在后台读不到剪贴板，
// 到点时读不到就等回到前台、拿到焦点（MainActivity.onWindowFocusChanged）再看一次。
class SensitiveClipboard(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val handler = Handler(Looper.getMainLooper())
    private var pendingText: String? = null
    private var deadline = 0L

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "copy") return result.notImplemented()
        try {
            val text = requireNotNull(call.argument<String>("text"))
            val clearAfter = requireNotNull(call.argument<Int>("clearAfterMs")).toLong()
            val clip = ClipData.newPlainText("SuperXD", text)
            // 常量 ClipDescription.EXTRA_IS_SENSITIVE 是 API 33 才有的，值就是这个字符串；写字符串让更早的系统也能编译、照常复制。
            clip.description.extras = PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
            activity.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
            pendingText = text
            deadline = SystemClock.elapsedRealtime() + clearAfter
            handler.removeCallbacksAndMessages(null)
            handler.postDelayed({ clearIfDue() }, clearAfter)
            result.success(null)
        } catch (error: Exception) {
            Log.e("SensitiveClipboard", "action=copy", error)
            result.error("SENSITIVE_CLIPBOARD", "复制没有完成", null)
        }
    }

    // 到点了、剪贴板里还是那一串才清；读不到（应用不在前台）留到拿回焦点再看，读到了不管清没清都不再惦记。
    fun clearIfDue() {
        val text = pendingText ?: return
        if (SystemClock.elapsedRealtime() < deadline) return
        try {
            val clipboard = activity.getSystemService(ClipboardManager::class.java)
            if (!activity.hasWindowFocus()) return
            pendingText = null
            val current = clipboard.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()
            if (current == text) clipboard.clearPrimaryClip()
        } catch (error: Exception) {
            Log.e("SensitiveClipboard", "action=clear", error)
        }
    }

    fun close() = handler.removeCallbacksAndMessages(null)
}
