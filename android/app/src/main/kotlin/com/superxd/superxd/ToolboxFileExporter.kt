package com.superxd.superxd

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class ToolboxFileExporter(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private data class Export(val source: File, val filename: String, val mime: String, val result: MethodChannel.Result)

    companion object {
        private val extensions = mapOf("video/mp4" to "mp4", "video/webm" to "webm", "video/quicktime" to "mov", "video/x-matroska" to "mkv", "video/x-msvideo" to "avi",
            "image/jpeg" to "jpg", "image/png" to "png", "image/webp" to "webp", "image/gif" to "gif", "audio/mpeg" to "mp3", "audio/mp4" to "m4a", "audio/aac" to "aac", "audio/ogg" to "ogg", "audio/wav" to "wav")
        // 一次性导出只有图片（人脸照片等），不开放视频音频。
        private val externalMimes = setOf("image/jpeg", "image/png", "image/webp")
        // 一次性导出的文件名：不得含路径分隔符、冒号与控制字符，不得以点开头（隐藏文件），64 字以内且带扩展名。
        private val externalName = Regex("^[^./\\\\:\\p{Cntrl}][^/\\\\:\\p{Cntrl}]{0,63}$")
    }

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
                    require(extensions[mime] == filename.substringAfterLast('.'))
                    dispatch(Export(source, filename, mime, result))
                }
                // 一次性导出（人脸照片等）：文件名用语义化名字。来源只认应用缓存目录（Dart 侧的临时文件就在这里），
                // 不能拿它把应用私有的库、密钥或配置导出到公共目录；mime 只放行图片且与扩展名对得上。
                "publishExternal" -> {
                    val source = File(requireNotNull(call.argument<String>("source"))).canonicalFile
                    val cache = activity.cacheDir.canonicalFile
                    require(source.path.startsWith(cache.path + File.separator) && source.isFile)
                    val filename = requireNotNull(call.argument<String>("filename"))
                    require(filename.matches(externalName) && filename.contains('.'))
                    val mime = requireNotNull(call.argument<String>("mimeType"))
                    require(mime in externalMimes && extensions[mime] == filename.substringAfterLast('.'))
                    dispatch(Export(source, filename, mime, result))
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

    private fun dispatch(export: Export) = executor.execute { publishMedia(export) }

    // [人工决策-2026-09-27 20:12:08] 默认保存公共Download/SuperXD，卸载工具不删除导出视频；不申请全存储权限。
    // [人工决策-2026-10-08 20:55:42] 用户复核：默认保存到 Download/SuperXD 仍有效（一次性导出的人脸照片同一目录）。
    // [人工决策-2026-10-18 12:27:26] 最低系统提到 Android 11 后，用户选定删掉旧 Android（9 及以下）让用户自己选保存位置的那条路径与它的结果回调。
    private fun publishMedia(export: Export) {
        val resolver = activity.contentResolver
        var created: Uri? = null
        try {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            val relativePath = "Download/SuperXD/"
            // 文件名是幂等键；只查本次导出，不枚举用户媒体库。写入中（IS_PENDING）的残留要一起查出来删掉重写。
            findByName(resolver, collection, export.filename, relativePath)?.use { cursor ->
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
        } catch (error: Throwable) {
            Log.e("ToolboxFiles", "action=publish", error)
            created?.let { uri ->
                try { resolver.delete(uri, null, null) }
                catch (cleanup: Exception) { Log.e("ToolboxFiles", "action=cleanup", cleanup) }
            }
            main.post { export.result.error("SAVE_FAILED", "保存失败，请重试", null) }
        }
    }

    // 媒体库查询默认排除写入中的条目，用 QUERY_ARG_MATCH_PENDING 一起查出来：
    // 上次中途失败留下的写入中条目才能被找到并清理，不会让新文件被系统改名成「(1)」。
    private fun findByName(resolver: ContentResolver, collection: Uri, filename: String, relativePath: String): Cursor? {
        val projection = arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.IS_PENDING)
        val selection = "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND ${MediaStore.MediaColumns.RELATIVE_PATH} = ?"
        return resolver.query(collection, projection, Bundle().apply {
            putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
            putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, arrayOf(filename, relativePath))
            putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
        }, null)
    }

    fun close() = executor.shutdown()
}
