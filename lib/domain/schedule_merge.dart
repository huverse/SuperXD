import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';

// 好友分享的课表与自己的课表逐项合并（人工决策见 page/schedule_import.dart）：两边按课名配成一门（同管理课程按课名合并），
// 配上的那门课按时段比出差异，每一处差异是一项可单独勾选的改动；勾了的套到自己的时段上，再按老师分回教学班（同管理课程保存，regroupCourse）。

// 一项改动改的是什么：教室、周次、教师按时段比（一样的改动合成一项，作用在几个时段上）；上课时间是两边各剩一个的时段对上（改了时间，整个时段换成TA的）；
// 加上、去掉是只有一边有的时段；学分对整门课。顺序即页面里的排列顺序。
enum MergeField { slot, place, weeks, teacher, addSlot, removeSlot, credit }

class MergeItem {
  const MergeItem({required this.id, required this.field, required this.scope, required this.before, required this.after, this.targets = const [], this.theirs, this.text, this.weeks, this.credit});
  // 在整份合并里唯一，页面按它记勾选。
  final String id;
  final MergeField field;
  // 这一项只作用在这门课的部分时段上时写是哪几个时段（「周一 第1–2节」），作用在整门课上为空串。
  final String scope;
  // 自己现在的样子与TA的样子；加上时段没有 before、去掉时段没有 after（空串）。
  final String before;
  final String after;
  // 作用在自己这门课的哪几个时段上（courseSlots 的下标）。
  final List<int> targets;
  // 上课时间与加上时段：TA的那个时段。
  final CourseSlot? theirs;
  // 教室、教师的新值。
  final String? text;
  final List<int>? weeks;
  final num? credit;
}

// 两边都有的一门课：自己的教学班、TA的教学班、有没有同一个教学班（课程代码与教学班号都一样，同班同学的课表多半是对的），以及有差异的各项。
class CourseMerge {
  const CourseMerge({required this.name, required this.mine, required this.theirs, required this.sameClass, required this.items});
  final String name;
  final List<CourseRecord> mine;
  final List<CourseRecord> theirs;
  final bool sameClass;
  final List<MergeItem> items;
}

class ScheduleMerge {
  const ScheduleMerge({required this.changed, required this.added, required this.removed, required this.same});
  // 两边都有、有差异的课。
  final List<CourseMerge> changed;
  // TA有自己没有、自己有TA没有的课，按课名一组（同名的几个教学班在一起）。
  final List<List<CourseRecord>> added;
  final List<List<CourseRecord>> removed;
  // 两边一样的课有几门。
  final int same;
  bool get identical => changed.isEmpty && added.isEmpty && removed.isEmpty;
}

// 两边按课名配对，逐门比出差异。每门课的工作量只随这门课的时段数增长（课表上限 500 门、每门 100 个时段）。
ScheduleMerge planScheduleMerge(List<CourseRecord> mine, List<CourseRecord> theirs) {
  final own = {for (final group in courseGroups(mine)) group.first.courseName.trim(): group};
  final changed = <CourseMerge>[];
  final added = <List<CourseRecord>>[];
  var same = 0;
  for (final group in courseGroups(theirs)) {
    final name = group.first.courseName.trim();
    final mineGroup = own.remove(name);
    if (mineGroup == null) {
      added.add(group);
      continue;
    }
    final items = _diffCourse(name, mineGroup, group);
    if (items.isEmpty) {
      same++;
      continue;
    }
    final keys = {for (final course in mineGroup) courseKey(course)};
    changed.add(CourseMerge(name: name, mine: mineGroup, theirs: group, sameClass: group.any((course) => keys.contains(courseKey(course))), items: items));
  }
  return ScheduleMerge(changed: changed, added: added, removed: own.values.toList(), same: same);
}

String _shown(String value) => value.trim().isEmpty ? '未填写' : value.trim();
String _time(CourseMeeting meeting) => '周${weekdayLabel(meeting.weekday)} ${periodLabel(meeting.periodStart, meeting.periodEnd)}';
bool _sameWeeks(List<int> left, List<int> right) => left.toSet().length == right.toSet().length && left.toSet().containsAll(right);
bool _samePosition(CourseMeeting left, CourseMeeting right) => left.weekday == right.weekday && left.periodStart == right.periodStart && left.periodEnd == right.periodEnd;
bool _sameSlot(CourseSlot left, CourseSlot right) =>
    _samePosition(left.meeting, right.meeting) && _sameWeeks(left.meeting.weeks, right.meeting.weeks) && left.meeting.place.trim() == right.meeting.place.trim() && left.teacher.trim() == right.teacher.trim();
// 配对的偏好：周次一样最像同一个时段，其次教室、教师。
int _likeness(CourseSlot left, CourseSlot right) =>
    (_sameWeeks(left.meeting.weeks, right.meeting.weeks) ? 4 : 0) + (left.meeting.place.trim() == right.meeting.place.trim() ? 2 : 0) + (left.teacher.trim() == right.teacher.trim() ? 1 : 0);

List<MergeItem> _diffCourse(String name, List<CourseRecord> mineGroup, List<CourseRecord> theirGroup) {
  final mine = courseSlots(mineGroup), theirs = courseSlots(theirGroup);
  final freeMine = [for (var index = 0; index < mine.length; index++) index];
  final freeTheirs = [for (var index = 0; index < theirs.length; index++) index];
  // 1. 完全一样的时段两边都划掉。
  for (final other in [...freeTheirs]) {
    final match = freeMine.where((index) => _sameSlot(mine[index], theirs[other])).firstOrNull;
    if (match == null) continue;
    freeMine.remove(match);
    freeTheirs.remove(other);
  }
  // 每次取最像的一对（同样像时按时段顺序），限定条件下配完为止。
  Iterable<(int, int)> pairs(bool Function(CourseSlot mine, CourseSlot theirs) allowed) sync* {
    while (true) {
      (int, int)? best;
      var bestScore = -1;
      for (final left in freeMine) {
        for (final right in freeTheirs) {
          if (!allowed(mine[left], theirs[right])) continue;
          final score = _likeness(mine[left], theirs[right]);
          if (score > bestScore) {
            best = (left, right);
            bestScore = score;
          }
        }
      }
      if (best == null) return;
      freeMine.remove(best.$1);
      freeTheirs.remove(best.$2);
      yield best;
    }
  }

  // 2. 同一上课时间（星期与节次）的配成一对，比周次、教室、教师；一样的改动合成一项。
  final changes = <String, ({MergeField field, String before, String after, List<int> targets, String? text, List<int>? weeks})>{};
  void change(MergeField field, String before, String after, int target, {String? text, List<int>? weeks}) =>
      changes.putIfAbsent('${field.name}\u0000$before\u0000$after', () => (field: field, before: before, after: after, targets: <int>[], text: text, weeks: weeks)).targets.add(target);
  for (final (left, right) in pairs((mine, theirs) => _samePosition(mine.meeting, theirs.meeting)).toList()) {
    final current = mine[left], other = theirs[right];
    if (!_sameWeeks(current.meeting.weeks, other.meeting.weeks)) change(MergeField.weeks, weeksLabel(current.meeting.weeks), weeksLabel(other.meeting.weeks), left, weeks: [...other.meeting.weeks]);
    if (current.meeting.place.trim() != other.meeting.place.trim()) change(MergeField.place, _shown(current.meeting.place), _shown(other.meeting.place), left, text: other.meeting.place.trim());
    if (current.teacher.trim() != other.teacher.trim()) change(MergeField.teacher, _shown(current.teacher), _shown(other.teacher), left, text: other.teacher.trim());
  }
  final items = <MergeItem>[];
  var count = 0;
  String id(MergeField field) => '$name\u0000${field.name}\u0000${count++}';
  String scope(List<int> targets) => targets.length == mine.length ? '' : targets.map((index) => _time(mine[index].meeting)).toSet().join('、');
  // 3. 两边各剩下的时段：配成「上课时间」改动（整个时段换成TA的），配不上的分别是加上、去掉。
  for (final (left, right) in pairs((_, _) => true).toList()) {
    items.add(MergeItem(id: id(MergeField.slot), field: MergeField.slot, scope: '', before: slotLabel(mine[left]), after: slotLabel(theirs[right]), targets: [left], theirs: theirs[right]));
  }
  for (final entry in changes.values) {
    items.add(MergeItem(id: id(entry.field), field: entry.field, scope: scope(entry.targets), before: entry.before, after: entry.after, targets: entry.targets, text: entry.text, weeks: entry.weeks));
  }
  for (final right in freeTheirs) {
    items.add(MergeItem(id: id(MergeField.addSlot), field: MergeField.addSlot, scope: '', before: '', after: slotLabel(theirs[right]), theirs: theirs[right]));
  }
  for (final left in freeMine) {
    items.add(MergeItem(id: id(MergeField.removeSlot), field: MergeField.removeSlot, scope: '', before: slotLabel(mine[left]), after: '', targets: [left]));
  }
  // 学分对整门课；TA没写学分时不提议清掉自己的。
  final myCredit = mineGroup.map((course) => course.credit).nonNulls.firstOrNull, theirCredit = theirGroup.map((course) => course.credit).nonNulls.firstOrNull;
  if (theirCredit != null && theirCredit != myCredit) {
    items.add(MergeItem(id: id(MergeField.credit), field: MergeField.credit, scope: '', before: myCredit == null ? '未填写' : creditLabel(myCredit), after: creditLabel(theirCredit), credit: theirCredit));
  }
  return items..sort((left, right) => left.field.index.compareTo(right.field.index));
}

// 按勾选生成合并后的课表：勾了的改动套到自己这门课的时段上再分回教学班，勾了的「TA有我没有」整门加进来（课程标识和自己撞了的另起本地课程），
// 勾了的「我有TA没有」整门删掉；其余原样、顺序不变。added、removed 是课名。
List<CourseRecord> applyScheduleMerge(ScheduleMerge plan, List<CourseRecord> mine, {required Set<String> items, required Set<String> added, required Set<String> removed, required String Function() newLocalId}) {
  final replaced = <String, List<CourseRecord>>{
    for (final course in plan.changed)
      if (course.items.where((item) => items.contains(item.id)).toList() case final picked when picked.isNotEmpty) course.name: _applyCourse(course, picked, newLocalId),
  };
  final result = <CourseRecord>[];
  final placed = <String>{};
  for (final course in mine) {
    final name = course.courseName.trim();
    if (removed.contains(name)) continue;
    if (replaced[name] case final next?) {
      if (placed.add(name)) result.addAll(next);
    } else {
      result.add(course);
    }
  }
  final keys = {for (final course in result) courseKey(course)};
  for (final group in plan.added) {
    if (!added.contains(group.first.courseName.trim())) continue;
    for (final course in group) {
      final copy = keys.contains(courseKey(course))
          ? CourseRecord(courseCode: course.courseCode, courseName: course.courseName, sectionId: course.sectionId, credit: course.credit, teacherName: course.teacherName, meetings: course.meetings.map((meeting) => meeting.copy()).toList(), localId: newLocalId())
          : course.copy();
      keys.add(courseKey(copy));
      result.add(copy);
    }
  }
  return result;
}

List<CourseRecord> _applyCourse(CourseMerge course, List<MergeItem> picked, String Function() newLocalId) {
  final slots = <CourseSlot?>[...courseSlots(course.mine)];
  final extra = <CourseSlot>[];
  ({num? value})? credit;
  CourseMeeting moved(CourseMeeting meeting, {String? place, List<int>? weeks}) => CourseMeeting(
    weekday: meeting.weekday,
    periodStart: meeting.periodStart,
    periodEnd: meeting.periodEnd,
    place: place ?? meeting.place,
    weeks: weeks ?? List.of(meeting.weeks),
    parity: meeting.parity,
  );
  for (final item in picked) {
    for (final target in item.targets) {
      final slot = slots[target];
      if (slot == null) continue;
      slots[target] = switch (item.field) {
        MergeField.place => slot.withMeeting(moved(slot.meeting, place: item.text)),
        MergeField.weeks => slot.withMeeting(moved(slot.meeting, weeks: item.weeks)),
        MergeField.teacher => CourseSlot(meeting: slot.meeting, teacher: item.text!, origin: slot.origin),
        MergeField.slot => CourseSlot(meeting: item.theirs!.meeting.copy(), teacher: item.theirs!.teacher, origin: slot.origin),
        MergeField.removeSlot => null,
        MergeField.addSlot || MergeField.credit => slot,
      };
    }
    if (item.field == MergeField.addSlot) extra.add(CourseSlot(meeting: item.theirs!.meeting.copy(), teacher: item.theirs!.teacher));
    if (item.field == MergeField.credit) credit = (value: item.credit);
  }
  return regroupCourse(course.mine, name: course.name, slots: [...slots.nonNulls, ...extra], newLocalId: newLocalId, credit: credit);
}
