package com.superxd.superxd

import android.app.Activity
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

// 课前提醒的实时更新（Android 16 Live Updates；ColorOS 16 流体云按同一接口显示，不接厂商 SDK）。
// Dart 侧（device/notification_reminders.dart）开了状态栏胶囊时把未来的课前提醒交过来，存进本应用私有的 SharedPreferences（已排除系统备份）。
// 只排一个闹钟：到点处理所有到期的课再排下一个时刻，应用不运行也会走。开课前 N 分钟发出、胶囊倒数到开课；开课时同一条改成上课中、倒数到下课；
// 下课由 setTimeoutAfter 自动消失。用户划掉的这节课不再补发（谷歌规范）。Android 15 及以下没有这套接口，Dart 侧不会开。
// 显示时段与胶囊内容的人工决策在 lib/application/campus_reminders.dart。

private const val PREFS = "superxd_course_live"
private const val CHANNEL = "course_reminder"
private const val ID_BASE = 620000
private const val DISMISS = "com.superxd.superxd.COURSE_LIVE_DISMISS"
// Android 16 的 SDK 没公开 setRequestPromotedOngoing，按文档写 EXTRA_REQUEST_PROMOTED_ONGOING 的取值。
private const val REQUEST_PROMOTED = "android.requestPromotedOngoing"

private class LiveCourse(
    val key: String, val fireAt: Long, val start: Long, val end: Long,
    val title: String, val before: String, val during: String,
) {
    // 每节课一个稳定的通知 id，计划重排后仍更新同一条。
    val id get() = ID_BASE + Math.floorMod(key.hashCode(), 10000)
}

// 计划是持久化的 JSON：解析失败时当没有计划并记日志，不让闹钟崩溃。
private fun readPlan(context: Context): List<LiveCourse> = try {
    val array = JSONArray(context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("items", "[]"))
    List(array.length()) { index ->
        val item = array.getJSONObject(index)
        LiveCourse(
            item.getString("key"), item.getLong("fireAt"), item.getLong("start"), item.getLong("end"),
            item.getString("title"), item.getString("before"), item.getString("during"),
        )
    }
} catch (error: Exception) {
    Log.e("CourseLive", "action=read", error)
    emptyList()
}

private fun dismissed(context: Context): Set<String> =
    context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getStringSet("dismissed", emptySet()).orEmpty()

private fun launchIntent(context: Context) = Intent(context, MainActivity::class.java)
    .setAction(Intent.ACTION_MAIN)
    .addCategory(Intent.CATEGORY_LAUNCHER)
    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)

object CourseLive {
    fun supported() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA

    // 整体替换计划：不在新计划里的课撤下通知，划掉记录只留新计划里的课（条数随计划有界）。
    fun replace(context: Context, items: String) {
        val old = readPlan(context)
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.edit().putString("items", items).commit()
        val plan = readPlan(context)
        val keys = plan.map { it.key }.toSet()
        prefs.edit().putStringSet("dismissed", dismissed(context).intersect(keys)).commit()
        val manager = context.getSystemService(NotificationManager::class.java)
        for (course in old) if (course.key !in keys) manager.cancel(course.id)
        run(context)
    }

    // 发出或更新所有该显示的课，再排下一个时刻的闹钟；没有了就撤销闹钟。
    fun run(context: Context) {
        val alarm = PendingIntent.getBroadcast(context, 0, Intent(context, CourseLiveReceiver::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val alarms = context.getSystemService(AlarmManager::class.java)
        val plan = readPlan(context)
        if (!supported() || plan.isEmpty()) {
            alarms.cancel(alarm)
            return
        }
        val now = System.currentTimeMillis()
        val skip = dismissed(context)
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "课前提醒", NotificationManager.IMPORTANCE_HIGH).apply { description = "上课前按设置的提前时间提醒" })
        for (course in plan) {
            if (course.fireAt <= now && now < course.end && course.key !in skip) manager.notify(course.id, build(context, course, now))
        }
        val next = plan.flatMap { listOf(it.fireAt, it.start) }.filter { it > now }.minOrNull()
        when {
            next == null -> alarms.cancel(alarm)
            alarms.canScheduleExactAlarms() -> alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, alarm)
            else -> alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, alarm)
        }
        Log.d("CourseLive", "action=run plan=${plan.size} next=$next")
    }

    // 胶囊文字由系统按 when 显示剩余分钟（开课前到开课、上课中到下课）；只在第一次发出时响铃振动，开课时改写不再打扰。
    private fun build(context: Context, course: LiveCourse, now: Long): Notification {
        val ongoing = course.start <= now
        val dismiss = Intent(context, CourseLiveReceiver::class.java).setAction(DISMISS).putExtra("key", course.key)
        return Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_reminder)
            .setContentTitle(course.title)
            .setContentText(if (ongoing) course.during else course.before)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setWhen(if (ongoing) course.end else course.start)
            .setShowWhen(true)
            .setTimeoutAfter(course.end - now)
            .setContentIntent(PendingIntent.getActivity(context, 0, launchIntent(context), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .setDeleteIntent(PendingIntent.getBroadcast(context, course.id, dismiss, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .addExtras(Bundle().apply { putBoolean(REQUEST_PROMOTED, true) })
            .build()
    }
}

// 计划闹钟、开机、应用更新、改系统时间或时区时重新处理；用户划掉通知时记下这节课。
class CourseLiveReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == DISMISS) {
            val key = intent.getStringExtra("key") ?: return
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putStringSet("dismissed", dismissed(context) + key).apply()
            Log.d("CourseLive", "action=dismiss")
            return
        }
        CourseLive.run(context)
    }
}

class CourseLiveChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    // 本应用的实时更新设置页（ColorOS 16 上是流体云的授权页）。
    private fun promotionSettings() = Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                // 系统允许，或有实时更新设置页让用户去开，才算有实时更新：Android 16 首版（模拟器 BE2A）没有这一页，也不会提升。
                "capability" -> result.success(if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
                    val allowed = activity.getSystemService(NotificationManager::class.java).canPostPromotedNotifications()
                    mapOf("live" to (allowed || promotionSettings().resolveActivity(activity.packageManager) != null), "allowed" to allowed)
                } else {
                    mapOf("live" to false, "allowed" to false)
                })
                "replace" -> {
                    CourseLive.replace(activity.applicationContext, requireNotNull(call.argument<String>("items")))
                    result.success(null)
                }
                "openSettings" -> {
                    activity.startActivity(promotionSettings())
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            Log.e("CourseLive", "action=${call.method} errorType=${error.javaClass.simpleName}", error)
            result.error("COURSE_LIVE", error.javaClass.simpleName, null)
        }
    }
}
