import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/schedule_store.dart';

// 本应用课表今天的课：读本机的当前学期、课表与作息，展开成今天的课程实例，交给百宝箱的学习通签到推断正在上的课。
// 只读本地、从不联网；未登录教务、没有学期、缺开学日或作息时给原因，由学习通那边改用学习通课表。
Future<CampusTimetable> campusTimetableToday(CampusGateway gateway, {required bool signedIn, DateTime? now}) async {
  if (!signedIn) return const CampusTimetable([], gap: TimetableGap.signedOut);
  final terms = await gateway.listTerms();
  final term = terms.ok ? terms.data?.firstOrNull : null;
  if (term == null) return const CampusTimetable([], gap: TimetableGap.noTerm);
  final schedule = await gateway.readSchedule(ScheduleScope.term(term));
  final bells = await gateway.readBells(term);
  final today = formatCampusDate(campusInstant((now ?? DateTime.now()).toUtc()));
  final occurrences = courseOccurrences(
    courses: schedule.data?.courses ?? const [],
    termStartDate: schedule.data?.termStartDate,
    bells: bells.data?.periods ?? const [],
    from: today,
    to: today,
  );
  return switch (occurrences.gap) {
    OccurrenceGap.termStart => const CampusTimetable([], gap: TimetableGap.noTermStart),
    OccurrenceGap.bells => const CampusTimetable([], gap: TimetableGap.noBells),
    null => CampusTimetable(occurrences.items),
  };
}
