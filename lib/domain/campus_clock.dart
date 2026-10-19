import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const campusTimeZone = 'Asia/Shanghai';

bool _ready = false;

void ensureCampusClock() {
  if (_ready) return;
  tzdata.initializeTimeZones();
  _ready = true;
}

tz.TZDateTime campusInstant([DateTime? instant]) {
  ensureCampusClock();
  return tz.TZDateTime.from(instant ?? DateTime.now(), tz.getLocation(campusTimeZone));
}

String campusToday() {
  final now = campusInstant();
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '${now.year}-$month-$day';
}

String formatCampusDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

// [人工决策-2026-10-19 17:55:48] 展示的时刻按远近写（用户选定，同微信、iMessage；本项目不沿用全局规则里 Vue 前端一节的 YYYY-MM-DD HH:mm:ss）：
// 今天「今天 17:12」、昨天「昨天 17:12」、明天「明天 17:12」、今年「10月18日 17:12」、跨年「2025年10月18日 17:12」，都不带秒；哪天按校园时区算。
String formatCampusRelative(String value, {DateTime? now}) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = campusInstant(parsed), today = campusInstant(now);
  final clock = formatCampusClock(parsed);
  final days = DateTime.utc(today.year, today.month, today.day).difference(DateTime.utc(local.year, local.month, local.day)).inDays;
  return switch (days) {
    0 => '今天 $clock',
    1 => '昨天 $clock',
    -1 => '明天 $clock',
    _ when local.year == today.year => '${local.month}月${local.day}日 $clock',
    _ => '${local.year}年${local.month}月${local.day}日 $clock',
  };
}

// 绝对时刻在校园时区的钟点 HH:mm。
String formatCampusClock(DateTime instant) {
  final local = campusInstant(instant);
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

// 绝对时刻在校园时区的短写「10月17日 09:12」：历史版本里按时刻指代某一版时用。
String formatCampusMoment(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final local = campusInstant(parsed);
  return '${local.month}月${local.day}日 ${formatCampusClock(parsed)}';
}

// 校园日期（YYYY-MM-DD）当天第 minuteOfDay 分钟对应的绝对时刻（UTC）。
DateTime campusMoment(String isoDate, int minuteOfDay) {
  ensureCampusClock();
  final parts = isoDate.split('-').map(int.parse).toList();
  final local = tz.TZDateTime(tz.getLocation(campusTimeZone), parts[0], parts[1], parts[2], minuteOfDay ~/ 60, minuteOfDay % 60);
  return DateTime.fromMillisecondsSinceEpoch(local.millisecondsSinceEpoch, isUtc: true);
}

DateTime campusNow() {
  ensureCampusClock();
  final now = tz.TZDateTime.now(tz.getLocation(campusTimeZone));
  return DateTime(now.year, now.month, now.day);
}

int? clockMinutes(String value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value);
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  return hour < 24 && minute < 60 ? hour * 60 + minute : null;
}
