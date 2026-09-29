const termStartHint = '请选择课程正式开始的第一天。第几周从你选的这一天所在周的周一开始算。如果选的是某一周的周三，这一周的周一也算同一周，不会提前一周，也不会推后一周。';

DateTime parseIsoDate(String value) {
  final matched = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
  if (matched == null) throw FormatException('日期须为 YYYY-MM-DD');
  final year = int.parse(matched.group(1)!);
  final month = int.parse(matched.group(2)!);
  final day = int.parse(matched.group(3)!);
  final utc = DateTime.utc(year, month, day);
  if (utc.year != year || utc.month != month || utc.day != day) {
    throw FormatException('无效日期 $value');
  }
  return utc;
}

String formatIsoDate(DateTime utc) {
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  return '${utc.year}-$month-$day';
}

String mondayOf(String isoDate) {
  final utc = parseIsoDate(isoDate);
  final back = utc.weekday == DateTime.sunday ? 6 : utc.weekday - DateTime.monday;
  return formatIsoDate(utc.subtract(Duration(days: back)));
}

int weekdayOf(String isoDate) => parseIsoDate(isoDate).weekday;

int weekIndex(String termStartDate, String day) {
  final origin = parseIsoDate(mondayOf(termStartDate)).millisecondsSinceEpoch;
  final current = parseIsoDate(mondayOf(day)).millisecondsSinceEpoch;
  return ((current - origin) / 86400000 / 7).round() + 1;
}

({int week, String start, String end}) weekRange(String termStartDate, int weekNumber) {
  if (weekNumber < 1) throw FormatException('周次须为从 1 开始的整数');
  final start = parseIsoDate(mondayOf(termStartDate)).add(Duration(days: (weekNumber - 1) * 7));
  final end = start.add(const Duration(days: 6));
  return (week: weekNumber, start: formatIsoDate(start), end: formatIsoDate(end));
}
