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

String formatCampusTimestamp(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return value;
  final date = campusInstant(parsed);
  return '${formatCampusDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';
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
