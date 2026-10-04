import 'dart:math' as math;

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';

// 好友课表与自己课表的“共同空闲”：按好友那一周的日期对齐双方周次，逐日逐节标出谁有课，合并连续的共同空闲节次。
// 工作量只随两份课表的时段数增长（每个时段只看一次），与学期长度无关。

// 某一周每天被占用的节次：weekday(1–7) → 节次集合。
Map<int, Set<int>> busyPeriods(List<CourseRecord> courses, int week) {
  final busy = <int, Set<int>>{};
  for (final course in courses) {
    for (final meeting in course.meetings) {
      if (!meeting.weeks.contains(week)) continue;
      final day = busy.putIfAbsent(meeting.weekday, () => <int>{});
      for (var period = meeting.periodStart; period <= meeting.periodEnd; period++) {
        day.add(period);
      }
    }
  }
  return busy;
}

class FreeSpan {
  const FreeSpan({required this.weekday, required this.periodStart, required this.periodEnd, this.time});
  final int weekday;
  final int periodStart;
  final int periodEnd;
  final MeetingTime? time;
  String get periods => periodStart == periodEnd ? '第$periodStart节' : '第$periodStart–$periodEnd节';
  String get label => '周${weekdayLabel(weekday)} $periods${time == null ? '' : ' ${time!.label}'}';
}

// 双方课表对齐到同一周的结果。mine 为 null 表示没有自己的同学期课表，只能看对方的。
class WeekComparison {
  const WeekComparison({required this.theirWeek, required this.myWeek, required this.theirs, required this.mine, required this.periodCount, required this.weekdays, required this.alignedByDate});
  final int theirWeek;
  final int? myWeek;
  final Map<int, Set<int>> theirs;
  final Map<int, Set<int>>? mine;
  // 网格的节次数：作息与双方课程里最大的节次。
  final int periodCount;
  // 显示的星期：周一到周五，任一方周末有课时加上周末。
  final List<int> weekdays;
  // 双方都有开学日、按日期对齐；否则按相同周次对比。
  final bool alignedByDate;

  bool theirBusy(int weekday, int period) => theirs[weekday]?.contains(period) ?? false;
  bool? myBusy(int weekday, int period) => mine == null ? null : mine![weekday]?.contains(period) ?? false;

  // 双方都没课的连续节次；没有自己的课表时为空。
  List<FreeSpan> commonFree(List<BellPeriod> bells) {
    if (mine == null) return const [];
    final spans = <FreeSpan>[];
    for (final weekday in weekdays) {
      int? start;
      for (var period = 1; period <= periodCount + 1; period++) {
        final free = period <= periodCount && !theirBusy(weekday, period) && !myBusy(weekday, period)!;
        if (free) {
          start ??= period;
        } else if (start != null) {
          spans.add(FreeSpan(weekday: weekday, periodStart: start, periodEnd: period - 1, time: periodTime(bells, start, period - 1)));
          start = null;
        }
      }
    }
    return spans;
  }
}

// 学期内的最大周次：双方课表里出现过的最大周，至少 1。
int termWeekCount(List<CourseRecord> courses) => courses.expand((course) => course.meetings).expand((meeting) => meeting.weeks).fold(1, math.max);

WeekComparison compareWeek({
  required List<CourseRecord> theirCourses,
  required String? theirStart,
  required int theirWeek,
  required List<CourseRecord>? myCourses,
  required String? myStart,
  required List<BellPeriod> bells,
}) {
  final aligned = theirStart != null && myStart != null;
  int? myWeek;
  if (myCourses != null) {
    myWeek = aligned ? weekIndex(myStart, formatIsoDate(parseIsoDate(mondayOf(theirStart)).add(Duration(days: (theirWeek - 1) * 7)))) : theirWeek;
  }
  final theirs = busyPeriods(theirCourses, theirWeek);
  final mine = myCourses == null || myWeek == null ? null : busyPeriods(myCourses, myWeek);
  final lastPeriod = [
    for (final bell in bells) bell.period,
    for (final day in [...theirs.values, ...?mine?.values]) ...day,
  ].fold(0, math.max);
  final weekend = [6, 7].any((day) => (theirs[day]?.isNotEmpty ?? false) || (mine?[day]?.isNotEmpty ?? false));
  return WeekComparison(
    theirWeek: theirWeek,
    myWeek: myWeek,
    theirs: theirs,
    mine: mine,
    // 没有作息又没课时给常见的 12 节，网格不至于空成一行。
    periodCount: lastPeriod == 0 ? 12 : lastPeriod,
    weekdays: weekend ? const [1, 2, 3, 4, 5, 6, 7] : const [1, 2, 3, 4, 5],
    alignedByDate: aligned,
  );
}
