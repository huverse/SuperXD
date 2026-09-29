import 'package:superxd/domain/schedule_store.dart';

// 表单的单次工作量有界，周次是实际发生周的唯一依据。
const maxScheduleWeeks = 53;
const maxSchedulePeriods = 30;
const maxScheduleCourses = 500;
const maxCourseMeetings = 100;

class ScheduleValidation implements Exception {
  const ScheduleValidation(this.message);
  final String message;
  @override
  String toString() => message;
}

CourseRecord replaceCourse(
  CourseRecord course, {
  String? name,
  String? teacher,
  num? credit,
  bool clearCredit = false,
  List<CourseMeeting>? meetings,
}) => CourseRecord(
  courseCode: course.courseCode,
  courseName: name ?? course.courseName,
  sectionId: course.sectionId,
  credit: clearCredit ? null : credit ?? course.credit,
  teacherName: teacher ?? course.teacherName,
  meetings:
      meetings ?? course.meetings.map((meeting) => meeting.copy()).toList(),
  localId: course.localId,
);

CourseMeeting replaceMeeting(CourseMeeting meeting, {List<int>? weeks}) =>
    CourseMeeting(
      weekday: meeting.weekday,
      periodStart: meeting.periodStart,
      periodEnd: meeting.periodEnd,
      place: meeting.place,
      weeks: weeks ?? List.of(meeting.weeks),
      parity: 'all',
    );

String meetingKey(CourseMeeting meeting) =>
    '${meeting.weekday}\u0000${meeting.periodStart}\u0000${meeting.periodEnd}\u0000${meeting.place}';

List<CourseRecord> normalizeSchedule(List<CourseRecord> courses) => courses
    .map(
      (course) => replaceCourse(
        course,
        name: course.courseName.trim(),
        teacher: course.teacherName.trim(),
        meetings: course.meetings
            .map(
              (meeting) => CourseMeeting(
                weekday: meeting.weekday,
                periodStart: meeting.periodStart,
                periodEnd: meeting.periodEnd,
                place: meeting.place.trim(),
                weeks: meeting.weeks.toSet().toList()..sort(),
                parity: 'all',
              ),
            )
            .toList(),
      ),
    )
    .toList();

void validateSchedule(List<CourseRecord> courses) {
  if (courses.length > maxScheduleCourses) {
    throw const ScheduleValidation('一个学期最多500门课程');
  }
  final identities = <String>{};
  for (final course in courses) {
    if (course.courseName.trim().isEmpty || course.courseName.length > 200) {
      throw const ScheduleValidation('课程名称须为1–200字');
    }
    if (!identities.add(courseKey(course))) {
      throw const ScheduleValidation('课程标识重复，请重新打开课表');
    }
    if (course.teacherName.length > 200) {
      throw const ScheduleValidation('教师名称不能超过200字');
    }
    if (course.credit != null &&
        (!course.credit!.isFinite ||
            course.credit! < 0 ||
            course.credit! > 100)) {
      throw const ScheduleValidation('学分须在0–100之间');
    }
    if (course.meetings.length > maxCourseMeetings) {
      throw const ScheduleValidation('一门课程最多100个时段');
    }
    final occupied = <String, Set<int>>{};
    for (final meeting in course.meetings) {
      if (meeting.weekday < 1 || meeting.weekday > 7) {
        throw const ScheduleValidation('请选择星期一至星期日');
      }
      if (meeting.periodStart < 1 ||
          meeting.periodEnd < meeting.periodStart ||
          meeting.periodEnd > maxSchedulePeriods) {
        throw const ScheduleValidation('节次须在1–30之间，结束节次不能早于开始');
      }
      if (meeting.weeks.isEmpty ||
          meeting.weeks.any((week) => week < 1 || week > maxScheduleWeeks)) {
        throw const ScheduleValidation('请选择第1–53周内的上课周次');
      }
      if (meeting.place.length > 200) {
        throw const ScheduleValidation('地点不能超过200字');
      }
      final seen = occupied.putIfAbsent(meetingKey(meeting), () => <int>{});
      if (meeting.weeks.any(seen.contains)) {
        throw const ScheduleValidation('同一课程存在重复的上课时段和周次');
      }
      seen.addAll(meeting.weeks);
    }
  }
}

// [人工决策-2026-09-25 00:19:22] 单周调整只移除原时段中的该周；全时段和整门课程操作必须由用户明确选择。
CourseRecord? removeMeeting(CourseRecord course, int index, {int? week}) {
  final meetings = course.meetings.map((meeting) => meeting.copy()).toList();
  final original = meetings[index];
  final remaining = week == null
      ? <int>[]
      : original.weeks.where((value) => value != week).toList();
  if (remaining.isEmpty) {
    meetings.removeAt(index);
  } else {
    meetings[index] = replaceMeeting(original, weeks: remaining);
  }
  return meetings.isEmpty ? null : replaceCourse(course, meetings: meetings);
}

CourseRecord changeMeeting(
  CourseRecord course,
  int index,
  CourseMeeting replacement, {
  int? week,
}) {
  final meetings = course.meetings.map((meeting) => meeting.copy()).toList();
  if (week == null) {
    meetings[index] = replacement;
  } else {
    final remaining = meetings[index].weeks
        .where((value) => value != week)
        .toList();
    if (remaining.isEmpty) {
      meetings.removeAt(index);
    } else {
      meetings[index] = replaceMeeting(meetings[index], weeks: remaining);
    }
    final target = replaceMeeting(replacement, weeks: [week]);
    final existing = meetings.indexWhere(
      (meeting) => meetingKey(meeting) == meetingKey(target),
    );
    if (existing < 0) {
      meetings.add(target);
    } else {
      meetings[existing] = replaceMeeting(
        meetings[existing],
        weeks: {...meetings[existing].weeks, week}.toList()..sort(),
      );
    }
  }
  return replaceCourse(course, meetings: meetings);
}

class CourseOverlap {
  const CourseOverlap(
    this.courseName,
    this.weekday,
    this.start,
    this.end,
    this.weeks,
  );
  final String courseName;
  final int weekday;
  final int start;
  final int end;
  final List<int> weeks;
  String get label =>
      '$courseName · 周${weekdayLabel(weekday)} 第$start–$end节 · ${weeksLabel(weeks)}';
}

List<CourseOverlap> courseOverlaps(
  CourseRecord edited,
  List<CourseRecord> others,
) {
  final results = <CourseOverlap>[];
  final byDay = <int, List<({CourseRecord course, CourseMeeting meeting})>>{};
  for (final course in others) {
    if (courseKey(course) == courseKey(edited)) continue;
    for (final meeting in course.meetings) {
      byDay.putIfAbsent(meeting.weekday, () => []).add((
        course: course,
        meeting: meeting,
      ));
    }
  }
  for (final meeting in edited.meetings) {
    final weeks = meeting.weeks.toSet();
    for (final candidate in byDay[meeting.weekday] ?? const []) {
      final other = candidate.meeting;
      if (meeting.periodEnd < other.periodStart ||
          meeting.periodStart > other.periodEnd) {
        continue;
      }
      final intersection = other.weeks.where(weeks.contains).toSet().toList()
        ..sort();
      if (intersection.isEmpty) continue;
      results.add(
        CourseOverlap(
          candidate.course.courseName,
          meeting.weekday,
          meeting.periodStart > other.periodStart
              ? meeting.periodStart
              : other.periodStart,
          meeting.periodEnd < other.periodEnd
              ? meeting.periodEnd
              : other.periodEnd,
          intersection,
        ),
      );
    }
  }
  return results;
}

String weekdayLabel(int weekday) =>
    const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1];
String weeksLabel(List<int> weeks) {
  final sorted = weeks.toSet().toList()..sort();
  final parts = <String>[];
  for (var index = 0; index < sorted.length; index++) {
    final start = sorted[index];
    var end = start;
    while (index + 1 < sorted.length && sorted[index + 1] == end + 1) {
      end = sorted[++index];
    }
    parts.add(start == end ? '$start' : '$start–$end');
  }
  return '第${parts.join('、')}周';
}

String meetingLabel(CourseMeeting meeting) =>
    '周${weekdayLabel(meeting.weekday)} 第${meeting.periodStart}–${meeting.periodEnd}节 · ${weeksLabel(meeting.weeks)}${meeting.place.isEmpty ? '' : ' · ${meeting.place}'}';

class CourseChange {
  const CourseChange({
    required this.kind,
    this.before,
    this.after,
    this.fields = const [],
  });
  final String kind;
  final CourseRecord? before;
  final CourseRecord? after;
  final List<String> fields;
}

List<CourseChange> scheduleChanges(
  List<CourseRecord> before,
  List<CourseRecord> after,
) {
  final originals = {for (final course in before) courseKey(course): course};
  final changes = <CourseChange>[];
  for (final course in after) {
    final old = originals.remove(courseKey(course));
    if (old == null) {
      changes.add(CourseChange(kind: '新增', after: course));
      continue;
    }
    if (fingerprint([old]) == fingerprint([course])) continue;
    changes.add(
      CourseChange(
        kind: '修改',
        before: old,
        after: course,
        fields: [
          if (old.courseName != course.courseName) '课程名称',
          if (old.teacherName != course.teacherName) '教师',
          if (old.credit != course.credit) '学分',
          if (fingerprint([
                replaceCourse(
                  old,
                  name: course.courseName,
                  teacher: course.teacherName,
                  credit: course.credit,
                  clearCredit: course.credit == null,
                ),
              ]) !=
              fingerprint([course]))
            '上课时段/周次/地点',
        ],
      ),
    );
  }
  for (final course in originals.values) {
    changes.add(CourseChange(kind: '删除', before: course));
  }
  return changes;
}
