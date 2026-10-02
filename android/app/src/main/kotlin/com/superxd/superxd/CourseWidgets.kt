package com.superxd.superxd

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId

// 桌面课表小组件。Dart 侧（device/home_widget_publisher.dart）发来课程快照与配色，存进本应用私有的 SharedPreferences；
// 小组件按系统时间挑当前与下一节，在下一个上下课时刻或校园日界用非精确闹钟（不需要权限）刷新，应用不运行也会走时。
// 桌面上没有任何小组件时撤销闹钟。快照只覆盖 7 天，过期后提示打开应用，不把过期快照显示成“近期没课”。

private const val PREFS = "superxd_course_widget"
private const val OPAQUE = 0xFF000000.toInt()
private val WEEKDAYS = arrayOf("周一", "周二", "周三", "周四", "周五", "周六", "周日")

private class WidgetCourse(
    val start: Long, val end: Long, val date: LocalDate, val startText: String, val endText: String,
    val name: String, val place: String,
)

private class WidgetColors(val background: Int, val text: Int, val secondary: Int)

// 应用还没发来配色时的中性配色（衬底 92% 不透明）。
private val LIGHT = WidgetColors(0xEBFFFFFF.toInt(), 0xFF1F1F1F.toInt(), 0xFF5F5F5F.toInt())
private val DARK = WidgetColors(0xEB1F1F1F.toInt(), 0xFFF2F2F2.toInt(), 0xFFBDBDBD.toInt())

private class WidgetState(
    val status: String, val zone: ZoneId, val until: Long, val items: List<WidgetCourse>,
    val mode: String, val light: WidgetColors, val dark: WidgetColors,
) {
    fun today(now: Long): LocalDate = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()

    // 不能显示课程时的提示；快照过期也算。
    fun message(now: Long): Int? = when (status) {
        "ready" -> if (now >= until) R.string.course_widget_stale else null
        "noTerm" -> R.string.course_widget_no_term
        "noTermStart" -> R.string.course_widget_no_term_start
        "noBells" -> R.string.course_widget_no_bells
        else -> R.string.course_widget_signed_out
    }

    fun upcoming(now: Long) = items.filter { it.end > now }

    // “今天”“明天”，更晚的写星期几；快照只覆盖 7 天，星期几不会有歧义。
    fun dayWord(date: LocalDate, now: Long): String {
        val today = today(now)
        return when (date) {
            today -> "今天"
            today.plusDays(1) -> "明天"
            else -> WEEKDAYS[date.dayOfWeek.value - 1]
        }
    }

    // 正在上：“上课中 · 至09:40”；今天：“08:00”；更晚：“明天 08:00”“周三 08:00”。
    fun label(course: WidgetCourse, now: Long): String = when {
        course.start <= now -> "上课中 · 至${course.endText}"
        course.date == today(now) -> course.startText
        else -> "${dayWord(course.date, now)} ${course.startText}"
    }

    // “今日课程”显示哪天：最早一节没下课的课所在的日子。今天还有课时就是今天（已下课的变淡），今天的课上完了就是下一个有课的日子。
    fun shownDay(now: Long): LocalDate? = upcoming(now).firstOrNull()?.date

    // 下一次需要重画的时刻：最近的上课或下课时刻、校园日界、快照过期时刻。
    fun nextBoundary(now: Long): Long {
        val midnight = today(now).plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        return (items.flatMap { listOf(it.start, it.end) } + midnight + until).filter { it > now }.min()
    }
}

// 快照是持久化的 JSON：解析失败时按未登录显示并记日志，不让小组件崩溃。
private fun readState(context: Context): WidgetState {
    val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    return try {
        val snapshot = prefs.getString("snapshot", null)?.let(::JSONObject)
        val theme = prefs.getString("theme", null)?.let(::JSONObject)
        val items = snapshot?.getJSONArray("items")?.let { array ->
            List(array.length()) { index ->
                val item = array.getJSONObject(index)
                WidgetCourse(
                    item.getLong("start"), item.getLong("end"), LocalDate.parse(item.getString("date")),
                    item.getString("startText"), item.getString("endText"),
                    item.getString("name"), item.getString("place"),
                )
            }
        } ?: emptyList()
        fun colors(key: String, fallback: WidgetColors) = theme?.getJSONObject(key)?.let {
            WidgetColors(it.getLong("background").toInt(), it.getLong("text").toInt(), it.getLong("secondary").toInt())
        } ?: fallback
        WidgetState(
            snapshot?.getString("status") ?: "signedOut",
            snapshot?.let { ZoneId.of(it.getString("timeZone")) } ?: ZoneId.systemDefault(),
            snapshot?.optLong("until") ?: 0L, items,
            theme?.getString("mode") ?: "system", colors("light", LIGHT), colors("dark", DARK),
        )
    } catch (error: Exception) {
        Log.e("CourseWidget", "action=read", error)
        WidgetState("signedOut", ZoneId.systemDefault(), 0L, emptyList(), "system", LIGHT, DARK)
    }
}

private fun night(context: Context) =
    context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES

// 跟随系统时，Android 12 起把浅深两色都交给桌面，由桌面按当时的深浅色挑；更早的系统按刷新时的深浅色。
private fun RemoteViews.paint(context: Context, state: WidgetState, id: Int, method: String, pick: (WidgetColors) -> Int) {
    val light = pick(state.light)
    val dark = pick(state.dark)
    when {
        state.mode == "light" -> setInt(id, method, light)
        state.mode == "dark" -> setInt(id, method, dark)
        Build.VERSION.SDK_INT >= 31 -> setColorInt(id, method, light, dark)
        else -> setInt(id, method, if (night(context)) dark else light)
    }
}

// 点按小组件只把应用带到前台（同点桌面图标），不强行跳页，避免丢掉正在编辑的内容。
private fun launchIntent(context: Context) = Intent(context, MainActivity::class.java)
    .setAction(Intent.ACTION_MAIN)
    .addCategory(Intent.CATEGORY_LAUNCHER)
    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)

private fun base(context: Context, layout: Int, state: WidgetState, message: Int?, texts: IntArray, secondaries: IntArray): RemoteViews {
    val views = RemoteViews(context.packageName, layout)
    views.paint(context, state, R.id.course_widget_bg, "setColorFilter") { it.background or OPAQUE }
    views.setInt(R.id.course_widget_bg, "setImageAlpha", state.light.background ushr 24)
    for (id in texts + R.id.course_widget_message) views.paint(context, state, id, "setTextColor") { it.text }
    for (id in secondaries) views.paint(context, state, id, "setTextColor") { it.secondary }
    views.setOnClickPendingIntent(android.R.id.background, PendingIntent.getActivity(context, 0, launchIntent(context), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
    views.setViewVisibility(R.id.course_widget_content, if (message == null) View.VISIBLE else View.GONE)
    views.setViewVisibility(R.id.course_widget_message, if (message == null) View.GONE else View.VISIBLE)
    if (message != null) views.setTextViewText(R.id.course_widget_message, context.getString(message))
    return views
}

// 能放下几行 14sp 文字：按小组件当前高度（竖屏）与系统字号估算，行高约为字号的 1.47 倍（模拟器实测）。拿不到尺寸时按 4 行。
private fun lineCapacity(context: Context, manager: AppWidgetManager, id: Int, reservedDp: Int): Int {
    val height = manager.getAppWidgetOptions(id).getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT)
    if (height <= 0) return 4
    return ((height - reservedDp) / (14f * 1.47f * context.resources.configuration.fontScale)).toInt()
}

// 哪天、几点、课名；放得下 4 行时课名占两行，5 行起加地点。
private fun renderNext(context: Context, state: WidgetState, now: Long, lines: Int): RemoteViews {
    val course = state.upcoming(now).firstOrNull()
    val message = state.message(now) ?: if (course == null) R.string.course_widget_empty else null
    val views = base(context, R.layout.course_widget_next, state, message,
        intArrayOf(R.id.course_widget_time, R.id.course_widget_name), intArrayOf(R.id.course_widget_label, R.id.course_widget_place))
    if (message != null || course == null) return views
    val ongoing = course.start <= now
    views.setTextViewText(R.id.course_widget_label, if (ongoing) "上课中" else state.dayWord(course.date, now))
    views.setTextViewText(R.id.course_widget_time, if (ongoing) "至${course.endText}" else course.startText)
    views.setTextViewText(R.id.course_widget_name, course.name)
    views.setInt(R.id.course_widget_name, "setMaxLines", if (lines >= 4) 2 else 1)
    views.setTextViewText(R.id.course_widget_place, course.place)
    views.setViewVisibility(R.id.course_widget_place, if (lines >= 5 && course.place.isNotEmpty()) View.VISIBLE else View.GONE)
    return views
}

// 每节两行；放不下两节（4 行）时只显示一节。
private fun renderPair(context: Context, state: WidgetState, now: Long, lines: Int): RemoteViews {
    val courses = state.upcoming(now).take(if (lines >= 4) 2 else 1)
    val message = state.message(now) ?: if (courses.isEmpty()) R.string.course_widget_empty else null
    val views = base(context, R.layout.course_widget_pair, state, message, intArrayOf(R.id.course_widget_name, R.id.course_widget_second_name),
        intArrayOf(R.id.course_widget_label, R.id.course_widget_place, R.id.course_widget_second_label, R.id.course_widget_second_place))
    if (message != null) return views
    // 时间与地点分开排：地点过长时省略开头（楼名在前、房间号在后），时间和房间号都保得住。
    // 正在上的课不写地点（人已在教室），把位置留给下课时间。
    fun fill(course: WidgetCourse, name: Int, label: Int, place: Int) {
        val shown = if (course.start <= now) "" else course.place
        views.setTextViewText(name, course.name)
        views.setTextViewText(label, if (shown.isEmpty()) state.label(course, now) else "${state.label(course, now)} · ")
        views.setTextViewText(place, shown)
    }
    fill(courses[0], R.id.course_widget_name, R.id.course_widget_label, R.id.course_widget_place)
    val second = courses.getOrNull(1)
    for (id in intArrayOf(R.id.course_widget_second_name, R.id.course_widget_second_row)) {
        views.setViewVisibility(id, if (second == null) View.GONE else View.VISIBLE)
    }
    if (second != null) fill(second, R.id.course_widget_second_name, R.id.course_widget_second_label, R.id.course_widget_second_place)
    return views
}

private fun renderDay(context: Context, state: WidgetState, now: Long, widgetId: Int): RemoteViews {
    val views = base(context, R.layout.course_widget_day, state, state.message(now), intArrayOf(), intArrayOf(R.id.course_widget_label, R.id.course_widget_list_empty))
    val day = state.shownDay(now) ?: state.today(now)
    views.setTextViewText(R.id.course_widget_label, "${state.dayWord(day, now)} ${day.monthValue}月${day.dayOfMonth}日")
    // 每个小组件一个独立的数据地址，系统才不会把不同小组件的列表混用。
    val adapter = Intent(context, CourseWidgetDayService::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, widgetId)
    adapter.data = Uri.parse(adapter.toUri(Intent.URI_INTENT_SCHEME))
    @Suppress("DEPRECATION")
    views.setRemoteAdapter(R.id.course_widget_list, adapter)
    views.setEmptyView(R.id.course_widget_list, R.id.course_widget_list_empty)
    views.setPendingIntentTemplate(R.id.course_widget_list, PendingIntent.getActivity(context, 1, launchIntent(context), PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
    return views
}

object CourseWidgets {
    private val providers = listOf(CourseWidgetNext::class.java, CourseWidgetPair::class.java, CourseWidgetDay::class.java)

    // 重画全部已添加的小组件，并按需安排或撤销下一次刷新。
    fun updateAll(context: Context) {
        val manager = AppWidgetManager.getInstance(context)
        val state = readState(context)
        val now = System.currentTimeMillis()
        var placed = false
        for (provider in providers) {
            val ids = manager.getAppWidgetIds(ComponentName(context, provider))
            if (ids.isEmpty()) continue
            placed = true
            for (id in ids) {
                manager.updateAppWidget(id, when (provider) {
                    CourseWidgetNext::class.java -> renderNext(context, state, now, lineCapacity(context, manager, id, reservedDp = 16))
                    CourseWidgetPair::class.java -> renderPair(context, state, now, lineCapacity(context, manager, id, reservedDp = 20))
                    else -> renderDay(context, state, now, id)
                })
            }
            @Suppress("DEPRECATION")
            if (provider == CourseWidgetDay::class.java) manager.notifyAppWidgetViewDataChanged(ids, R.id.course_widget_list)
        }
        val refresh = PendingIntent.getBroadcast(context, 0, Intent(context, CourseWidgetRefresh::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val alarms = context.getSystemService(AlarmManager::class.java)
        if (placed) alarms.setWindow(AlarmManager.RTC, state.nextBoundary(now), 60_000L, refresh) else alarms.cancel(refresh)
    }
}

abstract class CourseWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = CourseWidgets.updateAll(context)

    override fun onDisabled(context: Context) = CourseWidgets.updateAll(context)

    // 拉伸或改字号后按新尺寸重排。
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = CourseWidgets.updateAll(context)
}

class CourseWidgetNext : CourseWidgetProvider()

class CourseWidgetPair : CourseWidgetProvider()

class CourseWidgetDay : CourseWidgetProvider()

// 课程边界闹钟、改系统时间或时区时重画。
class CourseWidgetRefresh : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = CourseWidgets.updateAll(context)
}

class CourseWidgetDayService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = DayRows(applicationContext)
}

// “今日课程”那一天的全部课程；已下课的时间与课名改用次要文字色。
private class DayRows(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private var state = readState(context)
    private var now = 0L
    private var rows = emptyList<WidgetCourse>()

    override fun onCreate() {}

    override fun onDataSetChanged() {
        state = readState(context)
        now = System.currentTimeMillis()
        val day = state.shownDay(now)
        rows = if (state.message(now) == null) state.items.filter { it.date == day } else emptyList()
    }

    override fun onDestroy() {}

    override fun getCount() = rows.size

    override fun getViewAt(position: Int): RemoteViews {
        val course = rows[position]
        val done = course.end <= now
        val views = RemoteViews(context.packageName, R.layout.course_widget_day_row)
        views.setTextViewText(R.id.course_widget_row_time, "${course.startText}\n${course.endText}")
        views.setTextViewText(R.id.course_widget_row_name, course.name)
        views.setTextViewText(R.id.course_widget_row_place, course.place)
        views.setViewVisibility(R.id.course_widget_row_place, if (course.place.isEmpty()) View.GONE else View.VISIBLE)
        for (id in intArrayOf(R.id.course_widget_row_time, R.id.course_widget_row_name)) {
            views.paint(context, state, id, "setTextColor") { if (done) it.secondary else it.text }
        }
        views.paint(context, state, R.id.course_widget_row_place, "setTextColor") { it.secondary }
        views.setOnClickFillInIntent(R.id.course_widget_row, Intent())
        return views
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount() = 1

    override fun getItemId(position: Int) = position.toLong()

    override fun hasStableIds() = false
}

class CourseWidgetChannel(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val key = when (call.method) {
            "publish" -> "snapshot"
            "theme" -> "theme"
            else -> return result.notImplemented()
        }
        try {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(key, requireNotNull(call.argument<String>(key))).apply()
            CourseWidgets.updateAll(context)
            result.success(null)
        } catch (error: Exception) {
            Log.e("CourseWidget", "action=${call.method}", error)
            result.error("COURSE_WIDGET", "小组件未更新", null)
        }
    }
}
