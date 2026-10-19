import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_cards.dart';

CourseRecord sample({
  String id = 'a',
  String name = '数学',
  List<int> weeks = const [1, 2, 3],
}) => CourseRecord(
  courseCode: '',
  courseName: name,
  sectionId: '',
  credit: 2,
  teacherName: '老师',
  localId: id,
  meetings: [
    CourseMeeting(
      weekday: 1,
      periodStart: 1,
      periodEnd: 2,
      place: '101',
      weeks: weeks,
    ),
  ],
);

void main() {
  test('修改名称不改变localId，手工同时间课程卡片key不冲突', () {
    final original = sample();
    final renamed = replaceCourse(original, name: '改名');
    expect(courseKey(renamed), courseKey(original));
    final spans = periodSpans([renamed, sample(id: 'b')]);
    expect(spans.map(spanIdentity).toSet(), hasLength(2));
  });
  test('单周调课仅拆分该周，回到原地点时合并周次', () {
    final original = sample();
    final slots = courseSlots([original]);
    final target = CourseSlot(
      meeting: CourseMeeting(weekday: 2, periodStart: 3, periodEnd: 4, place: '202', weeks: [1, 2, 3]),
      teacher: '老师',
      origin: courseKey(original),
    );
    final edited = changeSlot(slots, 0, target, week: 2);
    expect(edited.first.meeting.weeks, [1, 3]);
    expect(edited.last.meeting.weeks, [2]);
    final restored = changeSlot(edited, 1, slots.single, week: 2);
    expect(restored.single.meeting.weeks, [1, 2, 3]);
    expect(original.meetings.single.weeks, [1, 2, 3]);
    // 这一周换了老师：不并进原老师的同一时段，另起一条。
    final handedOver = changeSlot(edited, 1, CourseSlot(meeting: slots.single.meeting, teacher: '代课老师'), week: 2);
    expect(handedOver.map((slot) => slot.teacher), ['老师', '代课老师']);
  });
  test('删除单次、重复时段、最后时段不会误删其他周', () {
    final edited = removeSlot(courseSlots([sample()]), 0, week: 2);
    expect(edited.single.meeting.weeks, [1, 3]);
    expect(removeSlot(edited, 0), isEmpty);
    expect(removeSlot(courseSlots([sample(weeks: [2])]), 0, week: 2), isEmpty);
  });
  test('管理课程按最早的上课时段排，没有时段的排最后', () {
    CourseRecord course(String name, List<(int, int)> meetings) => CourseRecord(courseCode: '', courseName: name, sectionId: '', credit: 2, teacherName: '', localId: name,
      meetings: [for (final (weekday, period) in meetings) CourseMeeting(weekday: weekday, periodStart: period, periodEnd: period + 1, place: '', weeks: const [1])]);
    final groups = courseGroups([course('空课', []), course('周三早', [(3, 1)]), course('周一下午', [(1, 5), (4, 1)]), course('周一早', [(2, 3), (1, 1)])]);
    expect(groups.map((group) => group.single.courseName), ['周一早', '周一下午', '周三早', '空课']);
  });
  test('同名教学班合成一门，保存时按老师分回原教学班', () {
    CourseMeeting meeting(int weekday) => CourseMeeting(weekday: weekday, periodStart: 1, periodEnd: 2, place: '101', weeks: [1, 2]);
    final a = CourseRecord(courseCode: 'C1', courseName: '数据结构', sectionId: 'S1', credit: 3, teacherName: '甲', meetings: [meeting(1)]);
    final b = CourseRecord(courseCode: 'C1', courseName: '数据结构 ', sectionId: 'S2', credit: 3, teacherName: '乙', meetings: [meeting(3)]);
    final groups = courseGroups([a, sample(), b]);
    // 按最早的上课时段排，同一时刻（都在周一第 1 节）按课名。
    expect(groups.map((group) => group.first.courseName.trim()), ['数学', '数据结构']);
    expect(groups.map((group) => group.length), [1, 2]);
    final group = groups.last;
    final slots = courseSlots(group);
    expect(slots.map(slotLabel), ['周一 第1–2节 · 第1–2周 · 101 · 甲', '周三 第1–2节 · 第1–2周 · 101 · 乙']);
    // 改课名对整组生效，时段各回原教学班。
    final renamed = regroupCourse(group, name: '数据结构与算法', slots: slots, newLocalId: () => 'new');
    expect(renamed.map(courseKey), [courseKey(a), courseKey(b)]);
    expect(renamed.map((course) => course.courseName).toSet(), {'数据结构与算法'});
    expect(renamed.map((course) => course.teacherName), ['甲', '乙']);
    // 乙的时段改给甲：并进甲的教学班，乙的教学班没有时段了就删掉。
    final moved = regroupCourse(group, name: '数据结构', slots: [slots[0], CourseSlot(meeting: slots[1].meeting, teacher: '甲', origin: slots[1].origin)], newLocalId: () => 'new');
    expect(moved.single.sectionId, 'S1');
    expect(moved.single.meetings, hasLength(2));
    // 乙整班改成丙（改错字）：沿用乙的教学班标识，不新建课程。
    final corrected = regroupCourse(group, name: '数据结构', slots: [slots[0], CourseSlot(meeting: slots[1].meeting, teacher: '丙', origin: slots[1].origin)], newLocalId: () => 'new');
    expect(corrected.map((course) => course.sectionId), ['S1', 'S2']);
    expect(corrected.last.teacherName, '丙');
    // 新加一位老师的时段：新建本地课程、带上课程代码；改过的学分对整组生效。
    final added = regroupCourse(group, name: '数据结构', slots: [...slots, CourseSlot(meeting: meeting(5), teacher: '丁')], newLocalId: () => 'new', credit: (value: 4));
    expect(added.last.localId, 'new');
    expect(added.last.courseCode, 'C1');
    expect(added.last.teacherName, '丁');
    expect(added.map((course) => course.credit).toSet(), {4});
    // 没改学分时各教学班保留自己的。
    expect(regroupCourse([a, replaceCourse(b, credit: 1)], name: '数据结构', slots: courseSlots([a, b]), newLocalId: () => 'new').map((course) => course.credit), [3, 1]);
    // 原本就没有时段的教学班照旧保留；时段删光时原来有时段的都删掉。
    final unscheduled = CourseRecord(courseCode: 'C1', courseName: '数据结构', sectionId: 'S3', credit: 3, teacherName: '戊', meetings: []);
    expect(regroupCourse([a, unscheduled], name: '数据结构', slots: courseSlots([a]), newLocalId: () => 'new').map((course) => course.sectionId), ['S1', 'S3']);
    expect(regroupCourse(group, name: '数据结构', slots: const [], newLocalId: () => 'new'), isEmpty);
  });
  test('规范化排序去重且单双周标记不制造虚假版本', () {
    final original = sample(weeks: [3, 1, 1]);
    final normalized = normalizeSchedule([original]);
    expect(normalized.single.meetings.single.weeks, [1, 3]);
    final marked = replaceCourse(
      original,
      meetings: [
        CourseMeeting(
          weekday: 1,
          periodStart: 1,
          periodEnd: 2,
          place: '101',
          weeks: [1, 3],
          parity: 'odd',
        ),
      ],
    );
    expect(fingerprint(normalized), fingerprint([marked]));
    expect(weeksLabel([1, 2, 3, 5, 7, 8]), '第1–3、5、7–8周');
  });
  test('校验非法内容及重复同周时段', () {
    expect(
      () => validateSchedule([replaceCourse(sample(), name: ' ')]),
      throwsA(isA<ScheduleValidation>()),
    );
    expect(
      () => validateSchedule([sample(weeks: [])]),
      throwsA(isA<ScheduleValidation>()),
    );
    expect(
      () => validateSchedule([
        sample(weeks: [54]),
      ]),
      throwsA(isA<ScheduleValidation>()),
    );
    final original = sample();
    expect(
      () => validateSchedule([
        replaceCourse(
          original,
          meetings: [original.meetings.single, original.meetings.single.copy()],
        ),
      ]),
      throwsA(isA<ScheduleValidation>()),
    );
    expect(
      () => validateSchedule([original, original.copy()]),
      throwsA(isA<ScheduleValidation>()),
    );
  });
  test('跨课程冲突按真实交叉周次，不误报单双周分离', () {
    expect(
      courseOverlaps(sample(weeks: [1, 3]), [
        sample(id: 'b', weeks: [2, 4]),
      ]),
      isEmpty,
    );
    expect(
      courseOverlaps(sample(weeks: [1, 3]), [
        sample(id: 'b', weeks: [2, 3]),
      ]).single.weeks,
      [3],
    );
  });
  test('差异按稳定身份识别改名和教师字段，不误判成删除新增', () {
    final original = sample();
    final changes = scheduleChanges(
      [original],
      [replaceCourse(original, name: '新名', teacher: '新教师')],
    );
    expect(changes.single.kind, '修改');
    expect(changes.single.fields, ['课程名称', '教师']);
    expect(scheduleChanges([original], []).single.kind, '删除');
    expect(scheduleChanges([], [original]).single.kind, '新增');
  });
  test('无变化不新增，人工恢复教务旧版仍须覆盖确认', () {
    const term = TermRef(xn: '2026', xq: '0');
    final store = ScheduleStore();
    final baseline = store.commitSync(
      term,
      [sample()],
      confirm: false,
      now: '2026-01-01T00:00:00Z',
    )!;
    expect(
      store.edit(term, [sample()], '无变化', '2026-01-01T00:00:00Z').id,
      baseline.id,
    );
    store.edit(term, [sample(name: '改名')], '修改', '2026-01-01T00:00:00Z');
    final restored = store.restore(term, baseline.id, '2026-01-01T00:00:00Z');
    expect(restored.source, 'user');
    expect(restored.restoredFromId, baseline.id);
    expect(store.planSync(term, [sample(name: '新教务')]).conflict, isTrue);
    expect(store.revisionsOf(term), hasLength(3));
    expect(
      () =>
          store.restore(const TermRef(xn: '2025', xq: '0'), baseline.id, 'now'),
      throwsStateError,
    );
  });
}
