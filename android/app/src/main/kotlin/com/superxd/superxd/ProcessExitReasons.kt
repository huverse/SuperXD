package com.superxd.superxd

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 本机诊断日志用的「上次进程为什么结束」：系统记下的最近几次退出原因（Android 11 起，同 Crashlytics 与 Play 的 ANR、原生崩溃来源），
// 只返回 since（毫秒）之后的；应用无响应（ANR）附系统给的线程堆栈前 80 行、最多 8KB。哪些算异常由 Dart 侧（lib/app_diagnostics.dart）判断。
class ProcessExitReasons(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "exitReasons") return result.notImplemented()
        try {
            val since = call.argument<Number>("since")?.toLong() ?: 0L
            val exits = context.getSystemService(ActivityManager::class.java)
                .getHistoricalProcessExitReasons(context.packageName, 0, 5)
                .filter { it.timestamp > since }
                .map { exit ->
                    mapOf(
                        "timestamp" to exit.timestamp,
                        "reason" to reasonName(exit.reason),
                        "status" to exit.status,
                        "importance" to exit.importance,
                        "pssKb" to exit.pss,
                        "rssKb" to exit.rss,
                        "description" to (exit.description ?: ""),
                        "trace" to if (exit.reason == ApplicationExitInfo.REASON_ANR) anrTrace(exit) else "",
                    )
                }
            result.success(exits)
        } catch (error: Exception) {
            Log.e("ProcessExitReasons", "action=read", error)
            result.error("EXIT_REASONS", "读不到上次的退出原因", null)
        }
    }

    private fun anrTrace(exit: ApplicationExitInfo): String = exit.traceInputStream?.bufferedReader()?.use { reader ->
        reader.lineSequence().take(80).joinToString("\n").take(8 * 1024)
    } ?: ""

    private fun reasonName(reason: Int): String = when (reason) {
        ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
        ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
        ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
        ApplicationExitInfo.REASON_CRASH -> "CRASH"
        ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
        ApplicationExitInfo.REASON_ANR -> "ANR"
        ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
        ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
        ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
        ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
        ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
        ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
        ApplicationExitInfo.REASON_OTHER -> "OTHER"
        ApplicationExitInfo.REASON_FREEZER -> "FREEZER"
        ApplicationExitInfo.REASON_PACKAGE_STATE_CHANGE -> "PACKAGE_STATE_CHANGE"
        ApplicationExitInfo.REASON_PACKAGE_UPDATED -> "PACKAGE_UPDATED"
        else -> "UNKNOWN_$reason"
    }
}
