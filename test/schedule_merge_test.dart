import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/schedule_merge.dart';
import 'package:superxd/domain/schedule_store.dart';

CourseMeeting _meeting(int weekday, int start, {String place = '合成楼101', List<int> weeks = const [1, 2, 3, 4]}) =>
    CourseMeeting(weekday: weekday, periodStart: start, periodEnd: start + 1, place: place, weeks: [...weeks]);

CourseRecord _course(String code, String name, List<CourseMeeting> meetings, {String section = 'S1', String teacher = '合成甲', num? credit = 2}) =>
    CourseRecord(courseCode: code, courseName: name, sectionId: section, credit: credit, teacherName: teacher, meetings: meetings);

void main() {
  var ids = 0;
  String newId() => 'new-${ids++}';
  setUp(() => ids = 0);

  test('按课名配对：一样的算相同，只有一边有的分别是新课与要删的课', () {
    final mine = [
      _course('A', '高等数学', [_meeting(1, 1)]),
      _course('B', '大学英语', [_meeting(2, 3)]),
    ];
    final theirs = [
      _course('A', '高等数学', [_meeting(1, 1)]),
      _course('C', '合成选修', [_meeting(3, 9)]),
    ];
    final plan = planScheduleMerge(mine, theirs);
    expect(plan.same, 1);
    expect(plan.changed, isEmpty);
    expect(plan.added.map((group) => group.first.courseName), ['合成选修']);
    expect(plan.removed.map((group) => group.first.courseName), ['大学英语']);
    expect(planScheduleMerge(mine, mine).identical, isTrue);
  });

  test('同一上课时间的时段比出教室、周次、教师；只改了一个时段时写是哪个时段', () {
    final mine = [_course('A', '高等数学', [_meeting(1, 1), _meeting(3, 3)])];
    final theirs = [_course('A', '高等数学', [_meeting(1, 1, place: '合成楼203', weeks: [1, 2]), _meeting(3, 3)], teacher: '合成乙')];
    final course = planScheduleMerge(mine, theirs).changed.single;
    expect(course.sameClass, isTrue);
    final byField = {for (final item in course.items) item.field: item};
    expect(byField.keys, [MergeField.place, MergeField.weeks, MergeField.teacher]);
    expect(byField[MergeField.place]!.scope, '周一 第1–2节');
    expect(byField[MergeField.place]!.before, '合成楼101');
    expect(byField[MergeField.place]!.after, '合成楼203');
    expect(byField[MergeField.weeks]!.after, '第1–2周');
    // 两个时段的教师都从甲换成乙：合成一项、作用在整门课上。
    expect(byField[MergeField.teacher]!.scope, '');
    expect(byField[MergeField.teacher]!.targets, hasLength(2));
  });

  test('两边各剩一个时段时配成「上课时间」改动，多出来的分别是加上、去掉；学分对整门课', () {
    final mine = [_course('A', '高等数学', [_meeting(1, 1), _meeting(2, 1)])];
    final theirs = [_course('A', '高等数学', [_meeting(4, 5), _meeting(1, 1)], credit: 3), _course('A', '高等数学', [_meeting(5, 7)], section: 'S2', teacher: '合成乙')];
    final items = planScheduleMerge(mine, theirs).changed.single.items;
    expect(items.map((item) => item.field), [MergeField.slot, MergeField.addSlot, MergeField.credit]);
    // 同教师同教室的最像：周二那节配到周四那节（改了时间），周五那节（另一位老师）是加上的。
    expect(items.first.before, startsWith('周二 第1–2节'));
    expect(items.first.after, startsWith('周四 第5–6节'));
    expect(items[1].after, contains('合成乙'));
    expect(items.last.before, '2');
    expect(items.last.after, '3');
  });

  test('同名但教学班不同不算同一个教学班；TA没写学分不提议清掉', () {
    final mine = [_course('A', '体育', [_meeting(1, 1)], section: 'S1')];
    final theirs = [_course('A', '体育', [_meeting(2, 3)], section: 'S9', credit: null)];
    final course = planScheduleMerge(mine, theirs).changed.single;
    expect(course.sameClass, isFalse);
    expect(course.items.map((item) => item.field), [MergeField.slot]);
  });

  test('只套勾了的项：改了教室、不改教师；老师没变的时段回原教学班', () {
    final mine = [_course('A', '高等数学', [_meeting(1, 1), _meeting(3, 3)])];
    final theirs = [_course('A', '高等数学', [_meeting(1, 1, place: '合成楼203'), _meeting(3, 3)], teacher: '合成乙')];
    final plan = planScheduleMerge(mine, theirs);
    final place = plan.changed.single.items.firstWhere((item) => item.field == MergeField.place);
    final merged = applyScheduleMerge(plan, mine, items: {place.id}, added: {}, removed: {}, newLocalId: newId);
    expect(merged, hasLength(1));
    expect(courseKey(merged.single), courseKey(mine.single));
    expect(merged.single.teacherName, '合成甲');
    expect(merged.single.meetings.map((meeting) => meeting.place), ['合成楼203', '合成楼101']);
  });

  test('勾了教师就按老师分回教学班；上课时间、加上、去掉、学分都照勾选套用', () {
    final mine = [_course('A', '高等数学', [_meeting(1, 1), _meeting(2, 1), _meeting(3, 1)])];
    final theirs = [_course('A', '高等数学', [_meeting(1, 1), _meeting(4, 5)], teacher: '合成甲', credit: 3)];
    final plan = planScheduleMerge(mine, theirs);
    final items = plan.changed.single.items;
    expect(items.map((item) => item.field), [MergeField.slot, MergeField.removeSlot, MergeField.credit]);
    final merged = applyScheduleMerge(plan, mine, items: {for (final item in items) item.id}, added: {}, removed: {}, newLocalId: newId);
    final meetings = merged.single.meetings.map((meeting) => (meeting.weekday, meeting.periodStart)).toSet();
    expect(meetings, {(1, 1), (4, 5)});
    expect(merged.single.credit, 3);
  });

  test('加进来的课和自己的课程标识撞了就另起本地课程；删掉的整门去掉，其余顺序不变', () {
    final mine = [
      _course('A', '高等数学', [_meeting(1, 1)]),
      _course('B', '大学英语', [_meeting(2, 3)]),
      _course('D', '线性代数', [_meeting(5, 1)]),
    ];
    // TA把同一个教学班（课程代码与教学班号相同）叫了别的名字，按课名是一门新课。
    final theirs = [_course('A', '高等数学', [_meeting(1, 1)]), _course('B', '英语听说', [_meeting(4, 3)]), _course('D', '线性代数', [_meeting(5, 1)])];
    final plan = planScheduleMerge(mine, theirs);
    expect(plan.added.single.first.courseName, '英语听说');
    final both = applyScheduleMerge(plan, mine, items: {}, added: {'英语听说'}, removed: {}, newLocalId: newId);
    expect(both.map((course) => course.courseName), ['高等数学', '大学英语', '线性代数', '英语听说']);
    expect(both.last.localId, 'new-0');
    expect(both.map(courseKey).toSet(), hasLength(4));
    // 同时删掉自己那门就不再撞，照原样加进来。
    final swapped = applyScheduleMerge(plan, mine, items: {}, added: {'英语听说'}, removed: {'大学英语'}, newLocalId: newId);
    expect(swapped.map((course) => course.courseName), ['高等数学', '线性代数', '英语听说']);
    expect(swapped.last.localId, isNull);
  });
}
