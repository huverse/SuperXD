import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';

class PeriodSpan {
  const PeriodSpan({
    required this.start,
    required this.end,
    this.course,
    this.meeting,
  });
  final int start;
  final int end;
  final CourseRecord? course;
  final CourseMeeting? meeting;
  bool get empty => course == null;
  String get key => course == null
      ? 'empty:$start-$end'
      : '${courseKey(course!)}:$start-$end';
}

int maxCoursePeriod(List<CourseRecord> courses) {
  var last = 0;
  for (final course in courses) {
    for (final meeting in course.meetings) {
      if (meeting.periodEnd > last) last = meeting.periodEnd;
    }
  }
  return last;
}

// [人工决策-2026-09-25 17:43:48] 白天按采用作息补齐、晚课按当日课程延伸；全天没课仍是空日，不补不存在的钟点。
List<PeriodSpan> periodSpans(
  List<CourseRecord> courses, {
  List<BellPeriod> bells = const [],
  int? termLastPeriod,
}) {
  final occupied = <PeriodSpan>[];
  for (final course in courses) {
    for (final meeting in course.meetings) {
      occupied.add(
        PeriodSpan(
          start: meeting.periodStart,
          end: meeting.periodEnd,
          course: course,
          meeting: meeting,
        ),
      );
    }
  }
  if (occupied.isEmpty) return const [];
  occupied.sort((left, right) => left.start.compareTo(right.start));
  final todayLast = maxCoursePeriod(courses);
  final byPeriod = {for (final bell in bells) bell.period: bell};
  final dayBells = bells
      .where(
        (bell) =>
            bell.dayPartCode == 'morning' || bell.dayPartCode == 'afternoon',
      )
      .toList();
  final bound = dayBells.isNotEmpty
      ? dayBells.map((bell) => bell.period).reduce((a, b) => a > b ? a : b)
      : termLastPeriod ??
            (bells.isEmpty
                ? todayLast
                : bells
                      .map((bell) => bell.period)
                      .reduce((a, b) => a > b ? a : b));
  final last = bound > todayLast ? bound : todayLast;
  final spans = <PeriodSpan>[];
  void addEmpty(int start, int end) {
    var cursor = start;
    while (cursor <= end) {
      if (bells.isNotEmpty && !byPeriod.containsKey(cursor)) {
        cursor++;
        continue;
      }
      var finish = cursor;
      if (cursor.isOdd &&
          cursor < end &&
          (bells.isEmpty ||
              byPeriod[cursor + 1]?.dayPartCode ==
                      byPeriod[cursor]?.dayPartCode &&
                  byPeriod.containsKey(cursor + 1))) {
        finish++;
      }
      spans.add(PeriodSpan(start: cursor, end: finish));
      cursor = finish + 1;
    }
  }

  var cursor = 1;
  for (final span in occupied) {
    if (span.start > cursor) addEmpty(cursor, span.start - 1);
    spans.add(span);
    if (span.end >= cursor) cursor = span.end + 1;
  }
  if (cursor <= last) addEmpty(cursor, last);
  return spans;
}
