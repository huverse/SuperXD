package com.superxd.superxd

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class ToolboxFileExporter(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var pending: Export? = null
    private val requestCode = 49210
    private data class Export(val source: File, val filename: String, val mime: String, val result: MethodChannel.Result)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "publish" -> {
                    val source = File(requireNotNull(call.argument<String>("source"))).canonicalFile
                    val root = File(activity.filesDir, "toolbox/downloads").canonicalFile
                    require(source.path.startsWith(root.path + File.separator) && source.isFile)
                    val id = requireNotNull(call.argument<String>("id"))
                    require(id.matches(Regex("[a-f0-9-]{36}")))
                    val filename = requireNotNull(call.argument<String>("filename"))
                    require(filename.matches(Regex("SuperXD_${Regex.escape(id)}\\.(mp4|webm|mov|mkv|avi|jpg|png|webp|gif|mp3|m4a|aac|ogg|wav)")))
                    val mime = requireNotNull(call.argument<String>("mimeType"))
                    val extensions = mapOf("video/mp4" to "mp4", "video/webm" to "webm", "video/quicktime" to "mov", "video/x-matroska" to "mkv", "video/x-msvideo" to "avi",
                        "image/jpeg" to "jpg", "image/png" to "png", "image/webp" to "webp", "image/gif" to "gif", "audio/mpeg" to "mp3", "audio/mp4" to "m4a", "audio/aac" to "aac", "audio/ogg" to "ogg", "audio/wav" to "wav")
                    require(extensions[mime] == filename.substringAfterLast('.'))
                    val export = Export(source, filename, mime, result)
                    if (Build.VERSION.SDK_INT >= 29) {
                        executor.execute { publishMedia(export) }
                    } else {
                        check(pending == null) { "已有保存操作" }
                        pending = export
                        activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = mime
                            putExtra(Intent.EXTRA_TITLE, filename)
                        }, requestCode)
                    }
                }
                "open" -> {
                    val uri = Uri.parse(requireNotNull(call.argument<String>("uri")))
                    require(uri.scheme == "content")
                    activity.startActivity(Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, call.argument<String>("mimeType"))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    })
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e("ToolboxFiles", "action=${call.method}", error)
            result.error("FILE_OPERATION", "文件操作未完成", null)
        }
    }

    // [人工决策-2026-09-27 20:12:08] 默认保存公共Download/SuperXD，卸载工具不删除导出视频；旧Android通过用户选址，不申请全存储权限。
    private fun publishMedia(export: Export) {
        val resolver = activity.contentResolver
        var created: Uri? = null
        try {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val relativePath = "Download/SuperXD/"
            // UUID文件名是幂等键；只查本次导出，不枚举用户媒体库。
            resolver.query(collection, arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.IS_PENDING),
                "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                arrayOf(export.filename, relativePath), null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val existing = Uri.withAppendedPath(collection, cursor.getLong(0).toString())
                    if (cursor.getInt(1) == 0) {
                        main.post { export.result.success(existing.toString()) }
                        return
                    }
                    resolver.delete(existing, null, null)
                }
            }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, export.filename)
                put(MediaStore.MediaColumns.MIME_TYPE, export.mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            created = requireNotNull(resolver.insert(collection, values))
            export.source.inputStream().use { input ->
                requireNotNull(resolver.openOutputStream(created, "w")).use { output -> input.copyTo(output) }
            }
            check(resolver.update(created, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null) == 1)
            val uri = created
            main.post { export.result.success(uri.toString()) }
        } catch (error: Exception) {
            Log.e("ToolboxFiles", "action=publish", error)
            created?.let { uri ->
                try { resolver.delete(uri, null, null) }
                catch (cleanup: Exception) { Log.e("ToolboxFiles", "action=cleanup", cleanup) }
            }
            main.post { export.result.error("SAVE_FAILED", "保存失败，请重试", null) }
        }
    }

    fun onActivityResult(code: Int, resultCode: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        val export = pending ?: return true
        pending = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { export.result.success(null); return true }
        executor.execute {
            try {
                export.source.inputStream().use { input ->
                    requireNotNull(activity.contentResolver.openOutputStream(uri, "w")).use { output -> input.copyTo(output) }
                }
                main.post { export.result.success(uri.toString()) }
            } catch (error: Exception) {
                Log.e("ToolboxFiles", "action=save_document", error)
                try { DocumentsContract.deleteDocument(activity.contentResolver, uri) }
                catch (cleanup: Exception) { Log.e("ToolboxFiles", "action=cleanup_document", cleanup) }
                main.post { export.result.error("SAVE_FAILED", "保存失败，请重试", null) }
            }
        }
        return true
    }

    fun close() {
        pending?.result?.error("ACTIVITY_CLOSED", "保存未完成，可重试", null)
        pending = null
        executor.shutdown()
    }
}
