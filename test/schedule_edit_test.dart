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
    final target = CourseMeeting(
      weekday: 2,
      periodStart: 3,
      periodEnd: 4,
      place: '202',
      weeks: [1, 2, 3],
    );
    final edited = changeMeeting(original, 0, target, week: 2);
    expect(edited.meetings.first.weeks, [1, 3]);
    expect(edited.meetings.last.weeks, [2]);
    final restored = changeMeeting(
      edited,
      1,
      original.meetings.single,
      week: 2,
    );
    expect(restored.meetings, hasLength(1));
    expect(fingerprint([restored]), fingerprint([original]));
    expect(original.meetings.single.weeks, [1, 2, 3]);
  });
  test('删除单次、重复时段、最后时段不会误删其他周', () {
    final original = sample();
    final edited = removeMeeting(original, 0, week: 2)!;
    expect(edited.meetings.single.weeks, [1, 3]);
    expect(removeMeeting(edited, 0), isNull);
    expect(removeMeeting(sample(weeks: [2]), 0, week: 2), isNull);
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
