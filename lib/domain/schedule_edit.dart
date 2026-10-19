import 'dart:math' as math;

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

// [人工决策-2026-10-19 16:08:42] 管理课程按课名合并（用户选定，同 WakeUp 课程表、超级课程表）：教务把同一门课的不同老师拆成几个教学班，
// 管理时同名的合成一门，老师写在每个时段上，改课名、删整门课一次作用于全部；存储仍按教学班一条记录，教务同步、提醒、小组件与私信分享都不变。
// [人工决策-2026-10-19 17:55:48] 合并后的各门课按最早的上课时段排（星期、再节次，同课表的阅读顺序），没有时段的排最后，同一时刻按课名（用户选定）；
// 以前按教务原始顺序、新增的排最后，找一门课要从头翻。
List<List<CourseRecord>> courseGroups(List<CourseRecord> courses) {
  final groups = <String, List<CourseRecord>>{};
  for (final course in courses) {
    groups.putIfAbsent(course.courseName.trim(), () => []).add(course);
  }
  int earliest(List<CourseRecord> group) => group.expand((course) => course.meetings).fold(1 << 20, (first, meeting) => math.min(first, meeting.weekday * 100 + meeting.periodStart));
  return groups.values.toList()..sort((left, right) {
    final order = earliest(left).compareTo(earliest(right));
    return order != 0 ? order : left.first.courseName.compareTo(right.first.courseName);
  });
}

// 合并后的一个上课时段：时段本身、这个时段的老师，以及原来属于哪个教学班（courseKey，新加的为空），保存时据此分回去。
class CourseSlot {
  const CourseSlot({required this.meeting, required this.teacher, this.origin});
  final CourseMeeting meeting;
  final String teacher;
  final String? origin;

  CourseSlot withMeeting(CourseMeeting meeting) => CourseSlot(meeting: meeting, teacher: teacher, origin: origin);
}

List<CourseSlot> courseSlots(List<CourseRecord> group) => [
  for (final course in group)
    for (final meeting in course.meetings) CourseSlot(meeting: meeting.copy(), teacher: course.teacherName, origin: courseKey(course)),
];

String slotLabel(CourseSlot slot) => slot.teacher.isEmpty ? meetingLabel(slot.meeting) : '${meetingLabel(slot.meeting)} · ${slot.teacher}';

String _slotKey(CourseSlot slot) => '${meetingKey(slot.meeting)}\u0000${slot.teacher}';

// [人工决策-2026-09-25 00:19:22] 单周调整只移除原时段中的该周；全时段和整门课程操作必须由用户明确选择。
List<CourseSlot> removeSlot(List<CourseSlot> slots, int index, {int? week}) {
  final next = [...slots];
  final original = next[index];
  final remaining = week == null ? <int>[] : original.meeting.weeks.where((value) => value != week).toList();
  if (remaining.isEmpty) {
    next.removeAt(index);
  } else {
    next[index] = original.withMeeting(replaceMeeting(original.meeting, weeks: remaining));
  }
  return next;
}

// 只改某一周：从原时段移出这一周，再并进同时段、同老师的那条，没有就新起一条。
List<CourseSlot> changeSlot(List<CourseSlot> slots, int index, CourseSlot replacement, {int? week}) {
  if (week == null) return [...slots]..[index] = replacement;
  final next = removeSlot(slots, index, week: week);
  final target = replacement.withMeeting(replaceMeeting(replacement.meeting, weeks: [week]));
  final existing = next.indexWhere((slot) => _slotKey(slot) == _slotKey(target));
  if (existing < 0) {
    next.add(target);
  } else {
    next[existing] = next[existing].withMeeting(replaceMeeting(next[existing].meeting, weeks: {...next[existing].meeting.weeks, week}.toList()..sort()));
  }
  return next;
}

// 保存时按老师分回教学班：老师没变的时段回原教学班；改了老师的并进同老师的教学班，没有就先占用原来有时段、现在一个不剩的教学班
// （保住教务的教学班标识），再没有才新建本地课程。原来有时段、现在一个不剩的教学班删掉，原本就没有时段的照旧保留。
// 课名对整组生效；credit 为空表示没改学分，各教学班保留自己的。
List<CourseRecord> regroupCourse(
  List<CourseRecord> group, {
  required String name,
  required List<CourseSlot> slots,
  required String Function() newLocalId,
  ({num? value})? credit,
}) {
  final byKey = {for (final course in group) courseKey(course): course};
  final targets = <String, ({CourseRecord base, String teacher, List<CourseMeeting> meetings})>{};
  final pending = <CourseSlot>[];
  for (final slot in slots) {
    final origin = byKey[slot.origin];
    if (origin != null && origin.teacherName == slot.teacher) {
      targets.putIfAbsent(slot.origin!, () => (base: origin, teacher: slot.teacher, meetings: [])).meetings.add(slot.meeting);
    } else {
      pending.add(slot);
    }
  }
  final created = <CourseRecord>[];
  for (final slot in pending) {
    final key = targets.entries.where((entry) => entry.value.teacher == slot.teacher).firstOrNull?.key ??
        group.where((course) => !targets.containsKey(courseKey(course)) && course.teacherName == slot.teacher).map(courseKey).firstOrNull ??
        group.where((course) => !targets.containsKey(courseKey(course)) && course.meetings.isNotEmpty).map(courseKey).firstOrNull;
    if (key != null) {
      targets.putIfAbsent(key, () => (base: byKey[key]!, teacher: slot.teacher, meetings: [])).meetings.add(slot.meeting);
      continue;
    }
    final course = CourseRecord(
      courseCode: group.firstOrNull?.courseCode ?? '',
      courseName: name,
      sectionId: '',
      credit: group.firstOrNull?.credit,
      teacherName: slot.teacher,
      meetings: [],
      localId: newLocalId(),
    );
    created.add(course);
    targets[courseKey(course)] = (base: course, teacher: slot.teacher, meetings: [slot.meeting]);
  }
  CourseRecord finish(CourseRecord course, {String? teacher, List<CourseMeeting>? meetings}) => replaceCourse(
    course,
    name: name.trim(),
    teacher: teacher,
    credit: credit?.value,
    clearCredit: credit != null && credit.value == null,
    meetings: meetings,
  );
  return [
    for (final course in [...group, ...created])
      if (targets[courseKey(course)] case final target?)
        finish(target.base, teacher: target.teacher, meetings: target.meetings)
      else if (course.meetings.isEmpty)
        finish(course),
  ];
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

// 节次文案的唯一写法：“第1–2节”，只有一节时“第3节”（不写“第3–3节”）；页面、提醒、小组件与读屏都经这里。
String periodLabel(int start, int end) => start == end ? '第$start节' : '第$start–$end节';

// 学分文案：整数不带小数（“5”不写“5.0”），其余照原样（“2.5”）。
String creditLabel(num credit) => credit == credit.truncate() ? '${credit.toInt()}' : '$credit';

String meetingLabel(CourseMeeting meeting) =>
    '周${weekdayLabel(meeting.weekday)} ${periodLabel(meeting.periodStart, meeting.periodEnd)} · ${weeksLabel(meeting.weeks)}${meeting.place.isEmpty ? '' : ' · ${meeting.place}'}';

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
