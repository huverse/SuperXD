import 'dart:math' as math;

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

// 一次具体上课：哪天、几点到几点（UTC 绝对时刻）、哪门课的哪个时段。课前提醒、日历导出、桌面小组件共用。
class CourseOccurrence {
  const CourseOccurrence({
    required this.date,
    required this.start,
    required this.end,
    required this.course,
    required this.meeting,
  });
  final String date;
  final DateTime start;
  final DateTime end;
  final CourseRecord course;
  final CourseMeeting meeting;

  // 稳定标识：课表校验保证同一课程的“时段加周次”不重复，所以课程加日期加节次唯一。
  String get key => '${course.sectionId.isNotEmpty ? course.sectionId : course.courseName}|$date|${meeting.periodStart}-${meeting.periodEnd}';

  // 节次文案：“第1–2节”，只有一节时“第3节”。
  String get periods => meeting.periodStart == meeting.periodEnd ? '第${meeting.periodStart}节' : '第${meeting.periodStart}–${meeting.periodEnd}节';
}

// 缺开学日或作息时无法换算成钟点，列表为空并给出原因，不猜时刻。
enum OccurrenceGap { termStart, bells }

class CourseOccurrences {
  const CourseOccurrences(this.items, {this.gap, this.unresolved = 0});
  final List<CourseOccurrence> items;
  final OccurrenceGap? gap;
  // 范围内有课、但作息里找不到对应节次的时段数；这些时段不出现在列表里。
  final int unresolved;
}

// 展开 [from, to]（校园日期，含两端）内的课程实例，按开始时刻排序。
// 按“时段 × 周次”直接定位日期，不逐天扫描，工作量只随课表大小与范围内周数增长。
CourseOccurrences courseOccurrences({
  required List<CourseRecord> courses,
  required String? termStartDate,
  required List<BellPeriod> bells,
  required String from,
  required String to,
}) {
  if (termStartDate == null || termStartDate.isEmpty) return const CourseOccurrences([], gap: OccurrenceGap.termStart);
  if (bells.isEmpty) return const CourseOccurrences([], gap: OccurrenceGap.bells);
  final firstWeek = math.max(1, weekIndex(termStartDate, from)), lastWeek = weekIndex(termStartDate, to);
  final monday = parseIsoDate(mondayOf(termStartDate));
  final items = <CourseOccurrence>[];
  var unresolved = 0;
  for (final course in courses) {
    for (final meeting in course.meetings) {
      final dates = [
        for (final week in meeting.weeks)
          if (week >= firstWeek && week <= lastWeek) formatIsoDate(monday.add(Duration(days: (week - 1) * 7 + meeting.weekday - 1))),
      ].where((date) => date.compareTo(from) >= 0 && date.compareTo(to) <= 0);
      if (dates.isEmpty) continue;
      final time = meetingTime(bells, meeting);
      if (time == null) {
        unresolved++;
        continue;
      }
      for (final date in dates) {
        items.add(CourseOccurrence(
          date: date,
          start: campusMoment(date, time.startMinute),
          end: campusMoment(date, time.endMinute),
          course: course,
          meeting: meeting,
        ));
      }
    }
  }
  items.sort((first, second) {
    final byStart = first.start.compareTo(second.start);
    return byStart != 0 ? byStart : first.key.compareTo(second.key);
  });
  return CourseOccurrences(items, gap: items.isEmpty && unresolved > 0 ? OccurrenceGap.bells : null, unresolved: unresolved);
}
