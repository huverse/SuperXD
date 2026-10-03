package com.superxd.superxd

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

// 只开放缓存 calendar_export 文件夹；单独子类，避免与插件声明的 FileProvider 在清单合并时冲突。
class CalendarFileProvider : FileProvider()

// 把导出的 .ics 交给日历：日历应用的导入入口只接“打开”，没有能打开的应用时退回系统分享。
// 只接受缓存 calendar_export 文件夹里的 .ics；对方在启动后才读取，文件留到下次导出时由 Dart 侧清空。
class CalendarExporter(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "open") return result.notImplemented()
        try {
            val file = File(requireNotNull(call.argument<String>("path"))).canonicalFile
            val root = File(activity.cacheDir, "calendar_export").canonicalFile
            require(file.parentFile == root && file.isFile && file.name.endsWith(".ics"))
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.calendar_export", file)
            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "text/calendar").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
                result.success("calendar")
            } catch (missing: ActivityNotFoundException) {
                val send = Intent(Intent.ACTION_SEND).setType("text/calendar").putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                send.clipData = ClipData.newRawUri(file.name, uri)
                activity.startActivity(Intent.createChooser(send, file.name))
                result.success("share")
            }
        } catch (error: Exception) {
            Log.e("CalendarExport", "action=open", error)
            result.error("CALENDAR_EXPORT", "无法打开日历", null)
        }
    }
}
