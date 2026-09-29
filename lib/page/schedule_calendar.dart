import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

int maxCourseWeek(List<CourseRecord> courses) {
  var maxWeek = 1;
  for (final course in courses) {
    for (final meeting in course.meetings) {
      for (final week in meeting.weeks) {
        if (week > maxWeek) maxWeek = week;
      }
    }
  }
  return maxWeek;
}

List<int> monthsOfTerm(String termStartDate, int maxWeek) {
  final months = <int>[];
  for (var week = 1; week <= maxWeek; week++) {
    final month = parseIsoDate(weekRange(termStartDate, week).start).month;
    if (months.isEmpty || months.last != month) months.add(month);
  }
  return months;
}

List<int> weeksOfMonth(String termStartDate, int maxWeek, int month) {
  final weeks = <int>[];
  for (var week = 1; week <= maxWeek; week++) {
    if (parseIsoDate(weekRange(termStartDate, week).start).month == month) weeks.add(week);
  }
  return weeks;
}

String weekRailLabel(String termStartDate, int week) {
  final range = weekRange(termStartDate, week);
  final first = week == 1 && termStartDate.compareTo(range.start) > 0 ? termStartDate : range.start;
  final date = parseIsoDate(first);
  return '第$week周\n${date.month}/${date.day}';
}

String monthRailLabel(int month) => '$month月';

String dayInWeek({required String termStartDate, required int week, required String today}) {
  final range = weekRange(termStartDate, week);
  if (weekIndex(termStartDate, today) == week && today.compareTo(range.start) >= 0 && today.compareTo(range.end) <= 0) {
    return today;
  }
  if (week == 1 && termStartDate.compareTo(range.start) > 0) return termStartDate;
  return range.start;
}

List<String> semesterDays(String termStartDate, int maxWeek) {
  final days = <String>[];
  var cursor = parseIsoDate(termStartDate);
  final end = parseIsoDate(weekRange(termStartDate, maxWeek).end);
  while (!cursor.isAfter(end)) {
    days.add(formatIsoDate(cursor));
    cursor = cursor.add(const Duration(days: 1));
  }
  return days;
}

List<String> weekDates(String day) {
  final monday = parseIsoDate(mondayOf(day));
  return [for (var offset = 0; offset < 7; offset++) formatIsoDate(monday.add(Duration(days: offset)))];
}
