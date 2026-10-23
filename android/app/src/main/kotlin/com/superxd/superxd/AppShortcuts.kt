package com.superxd.superxd

import android.app.Activity
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// 常用功能的快捷入口（lib/device/app_shortcuts.dart）：长按应用图标的菜单（动态快捷方式）与桌面快捷方式。
// 名字与图标由 Dart 给（图标是画好的自适应图标 PNG），点了带着入口 id 回到 MainActivity。
// 启动标志用 CLEAR_TOP + SINGLE_TOP：应用在后台时只把已有页面拉到前台、经 onNewIntent 交回入口 id，不重建界面（不加 CLEAR_TASK，那会整个冷启动）。
class AppShortcuts(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val ACTION = "com.superxd.superxd.SHORTCUT"
        const val EXTRA = "shortcut"
    }

    private val manager = activity.getSystemService(ShortcutManager::class.java)
    // 这次冷启动带来的入口 id，Dart 取一次就清掉。
    var pending: String? = null

    // 从入口打开的 Intent 里取入口 id，顺带告诉系统用过了（桌面据此排序建议）。
    fun launched(intent: Intent?): String? {
        if (intent?.action != ACTION) return null
        val id = intent.getStringExtra(EXTRA) ?: return null
        manager?.reportShortcutUsed(id)
        return id
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val manager = manager ?: return result.success(if (call.method == "pin") false else null)
        when (call.method) {
            "publish" -> {
                manager.setDynamicShortcuts(call.argument<List<Map<String, Any>>>("shortcuts").orEmpty().map(::info))
                result.success(null)
            }
            "pin" -> {
                if (!manager.isRequestPinShortcutSupported) return result.success(false)
                @Suppress("UNCHECKED_CAST")
                result.success(manager.requestPinShortcut(info(call.arguments as Map<String, Any>), null))
            }
            "takeLaunch" -> {
                result.success(pending)
                pending = null
            }
            else -> result.notImplemented()
        }
    }

    private fun info(item: Map<String, Any>): ShortcutInfo {
        val id = item["id"] as String
        val label = item["label"] as String
        val png = item["icon"] as ByteArray
        val intent = Intent(activity, MainActivity::class.java)
            .setAction(ACTION)
            .putExtra(EXTRA, id)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return ShortcutInfo.Builder(activity, id)
            .setShortLabel(label)
            .setLongLabel(label)
            .setIcon(Icon.createWithAdaptiveBitmap(BitmapFactory.decodeByteArray(png, 0, png.size)))
            .setIntent(intent)
            .build()
    }
}
