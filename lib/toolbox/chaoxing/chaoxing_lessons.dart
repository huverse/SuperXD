import 'dart:convert';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 按课表推断「可能正在签到」：先拿到今天的课（本应用课表或学习通课表，见 ChaoxingLessonSource），
// 当前时刻在某节课前后半小时内时，这节课的时段里发起、仍在进行的签到就算（人工决策见 chaoxingLessonActivity）。
const chaoxingLessonsUri = 'https://kb.chaoxing.com/pc/curriculum/getMyLessons';
const chaoxingLessonWindowMinutes = 30;
const _lessonWindow = Duration(minutes: chaoxingLessonWindowMinutes);

// 学习通课表为空（多半是没在学习通里导入课表）时，隔这么久才再拉一次，别每次刷新都多发一个请求；有课的照旧缓存 7 天。
const chaoxingEmptyLessonsRetry = Duration(hours: 6);

// 推断用哪份课表：设置里存的键与取值（主源；用不了时自动改用另一份）。
const chaoxingLessonSourceKey = 'lesson_source';

// [人工决策-2026-10-17 22:47:20] 课表推断「主源加自动备用」，默认本应用课表（用户选定，未选默认学习通、只用所选一份、两份合并）：
// 主源用不了（本应用：没登录教务、没有学期、缺开学日或作息；学习通：读不到或为空）才改用另一份，主源今天没课不算用不了；
// 代签账号不看设置，只用它自己的学习通课表（本应用课表是本人的，谁的数据跟着谁）。
enum ChaoxingLessonSource {
  app('本应用课表'),
  chaoxing('学习通课表');

  const ChaoxingLessonSource(this.label);
  final String label;
}

class ChaoxingLesson {
  const ChaoxingLesson({
    required this.courseId,
    required this.classId,
    required this.courseName,
    required this.dayOfWeek,
    required this.startMinute,
    required this.endMinute,
    required this.weeks,
    this.teacher = '',
    this.location = '',
  });
  final int courseId;
  final int classId;
  final String courseName;

  // 1 = 周一 … 7 = 周日。
  final int dayOfWeek;
  final int startMinute;
  final int endMinute;
  final Set<int> weeks;
  final String teacher;
  final String location;
}

class ChaoxingLessonTable {
  const ChaoxingLessonTable({required this.lessons, this.firstWeekDate});
  final List<ChaoxingLesson> lessons;

  // 第一周所在的绝对时刻（学习通给毫秒）；没有时按第一周算。
  final DateTime? firstWeekDate;
}

// 今天的一节课：哪门课（课名、老师，学习通课表还可能带班级号）与上课的起止时刻（UTC）。两份课表都换成它再推断。
class ChaoxingLessonSlot {
  const ChaoxingLessonSlot({
    required this.courseName,
    required this.start,
    required this.end,
    this.teacher = '',
    this.classId = 0,
    this.courseId = 0,
  });
  final String courseName;
  final String teacher;
  final int classId;
  final int courseId;
  final DateTime start;
  final DateTime end;
}

// 一次推断的课表：实际用的那份（都用不了时为空）、它今天的课，以及读过但用不了的那份的原因。
class ChaoxingLessonPlan {
  const ChaoxingLessonPlan({this.used, this.slots = const [], this.appProblem, this.chaoxingProblem, this.otherUser = false});
  final ChaoxingLessonSource? used;
  final List<ChaoxingLessonSlot> slots;
  final String? appProblem;
  final String? chaoxingProblem;
  // 代签账号：只用它自己的学习通课表，不看设置。
  final bool otherUser;
}

// 本应用课表用不了的原因（签到设置里写给用户看）。
String chaoxingTimetableProblem(TimetableGap gap) => switch (gap) {
  TimetableGap.signedOut => '没登录教务',
  TimetableGap.noTerm => '本应用里还没有课表',
  TimetableGap.noTermStart => '本应用课表缺开学日',
  TimetableGap.noBells => '本应用课表缺作息',
};

// 签到设置里只读的一行：这次按哪份课表推断；改用了另一份时先说主源为什么用不了。
String chaoxingLessonPlanText(ChaoxingLessonPlan plan, ChaoxingLessonSource preferred) {
  if (plan.otherUser) {
    return plan.used == null ? '代签账号用它自己的学习通课表：${plan.chaoxingProblem}' : '代签账号用它自己的学习通课表';
  }
  final problems = {ChaoxingLessonSource.app: plan.appProblem, ChaoxingLessonSource.chaoxing: plan.chaoxingProblem};
  final used = plan.used;
  if (used == null) {
    final other = ChaoxingLessonSource.values.firstWhere((source) => source != preferred);
    return '${[?problems[preferred], ?problems[other]].join('，')}，推断不了正在上的课';
  }
  return used == preferred ? '这次按${used.label}推断' : '${problems[preferred]}，这次按${used.label}推断';
}

// 拉学习通课表，返回 data 段原文（缓存原文，解析在读的时候做，接口加字段不影响缓存）。
Future<String> chaoxingFetchLessons(ChaoxingClient client) async {
  final response = await client.http.get(
    Uri.parse(chaoxingLessonsUri).replace(queryParameters: {'curTime': '${DateTime.now().millisecondsSinceEpoch}'}),
  );
  final data = chaoxingData(response.body);
  chaoxingParseLessons(data);
  return jsonEncode(data);
}

// 课表段按外部输入解析：节次时间是「08:00-08:45」这样的串，认不出的课跳过。
ChaoxingLessonTable chaoxingParseLessons(Map<String, Object?> data) {
  final curriculum = data['curriculum'];
  final lessonArray = data['lessonArray'];
  if (curriculum is! Map || lessonArray is! List) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '学习通课表解析失败');
  }
  final times = curriculum['lessonTimeConfigArray'];
  if (times is! List) {
    throw const ChaoxingFailure(ChaoxingFailureCode.invalidResponse, '学习通课表节次解析失败');
  }
  final sectionTimes = [for (final item in times) '$item'];
  int? minuteOf(int section, {required bool start}) {
    if (section < 1 || section > sectionTimes.length) return null;
    final parts = sectionTimes[section - 1].split('-');
    if (parts.length != 2) return null;
    return clockMinutes((start ? parts[0] : parts[1]).trim());
  }

  final lessons = <ChaoxingLesson>[];
  for (final item in lessonArray) {
    if (item is! Map) continue;
    final name = chaoxingString(item['name']).trim();
    final dayOfWeek = chaoxingInt(item['dayOfWeek']);
    final begin = chaoxingInt(item['beginNumber']);
    if (name.isEmpty || dayOfWeek <= 0 || dayOfWeek > 7 || begin <= 0) continue;
    final length = chaoxingInt(item['length']) > 0 ? chaoxingInt(item['length']) : 1;
    final startMinute = minuteOf(begin, start: true);
    final endMinute = minuteOf(begin + length - 1, start: false);
    if (startMinute == null || endMinute == null) continue;
    lessons.add(
      ChaoxingLesson(
        courseId: chaoxingInt(item['courseId']),
        classId: chaoxingInt(item['classId']),
        courseName: name,
        dayOfWeek: dayOfWeek,
        startMinute: startMinute,
        endMinute: endMinute,
        weeks: {for (final week in chaoxingString(item['weeks']).split(',')) ?int.tryParse(week.trim())},
        teacher: chaoxingString(item['teacherName']),
        location: chaoxingString(item['location']),
      ),
    );
  }
  final firstWeek = chaoxingInt(curriculum['firstWeekDate']);
  return ChaoxingLessonTable(
    lessons: lessons,
    firstWeekDate: firstWeek > 0 ? DateTime.fromMillisecondsSinceEpoch(firstWeek, isUtc: true) : null,
  );
}

// 第几周按校园时区的日界算：第一周那天到今天差几天，整除 7 加 1。
int chaoxingCurrentWeek(DateTime? firstWeekDate, DateTime now) {
  if (firstWeekDate == null) return 1;
  final first = campusInstant(firstWeekDate);
  final today = campusInstant(now);
  final days = DateTime.utc(today.year, today.month, today.day).difference(DateTime.utc(first.year, first.month, first.day)).inDays;
  return days ~/ 7 + 1;
}

// 学习通课表里今天（校园时区的星期与本周）的课，换成起止时刻。
List<ChaoxingLessonSlot> chaoxingTableSlots(ChaoxingLessonTable table, DateTime now) {
  final local = campusInstant(now);
  final today = formatCampusDate(local);
  final week = chaoxingCurrentWeek(table.firstWeekDate, now);
  return [
    for (final lesson in table.lessons)
      if (lesson.dayOfWeek == local.weekday && lesson.weeks.contains(week))
        ChaoxingLessonSlot(
          courseName: lesson.courseName,
          teacher: lesson.teacher,
          classId: lesson.classId,
          courseId: lesson.courseId,
          start: campusMoment(today, lesson.startMinute),
          end: campusMoment(today, lesson.endMinute),
        ),
  ];
}

// 本应用课表今天的课（组合根交来的课程实例）换成同样的时段；没有学习通的班级号，只能按课名对。
List<ChaoxingLessonSlot> chaoxingTimetableSlots(CampusTimetable timetable) => [
  for (final item in timetable.items)
    ChaoxingLessonSlot(courseName: item.course.courseName, teacher: item.course.teacherName, start: item.start, end: item.end),
];

// 当前时刻在开课前半小时到下课后半小时之间的课。
List<ChaoxingLessonSlot> chaoxingCurrentSlots(List<ChaoxingLessonSlot> slots, DateTime now) => [
  for (final slot in slots)
    if (!now.isBefore(slot.start.subtract(_lessonWindow)) && !now.isAfter(slot.end.add(_lessonWindow))) slot,
];

// 课程名归一化：全角转半角、去空白与常见括号标点、去掉末尾的「一/二/Ⅱ/2」这类序号。
String chaoxingNormalizeCourseName(String name) {
  final halfWidth = String.fromCharCodes(name.runes.map((rune) => rune >= 0xFF01 && rune <= 0xFF5E ? rune - 0xFEE0 : rune));
  const punctuation = '()（）[]【】《》<>·．._-—~、，,';
  final cleaned = halfWidth.toLowerCase().split('').where((char) => char.trim().isNotEmpty && !punctuation.contains(char)).join();
  return cleaned.replaceFirst(RegExp(r'(一|二|三|四|五|六|七|八|九|十|\d+|i{1,3}|iv|v)+$'), '');
}

double _bigramSimilarity(String first, String second) {
  if (first.length < 2 || second.length < 2) return 0;
  Set<String> bigrams(String value) => {for (var index = 0; index < value.length - 1; index++) value.substring(index, index + 2)};
  final left = bigrams(first);
  final right = bigrams(second);
  return 2 * left.intersection(right).length / (left.length + right.length);
}

// 课表里的课名与课程列表里的课名对得上：互相包含，或二元组相似度不低于 0.5。
bool chaoxingCourseNameMatches(String lessonName, String courseName) {
  final lesson = chaoxingNormalizeCourseName(lessonName);
  final course = chaoxingNormalizeCourseName(courseName);
  if (lesson.isEmpty || course.isEmpty) return false;
  if (course.contains(lesson) || lesson.contains(course)) return true;
  return _bigramSimilarity(lesson, course) >= 0.5;
}

// 两边写的老师有没有同一个人：按常见分隔符拆开，任一个名字出现在另一边就算（教务写「甲、乙」，学习通可能只写「甲」）。
bool chaoxingTeacherOverlaps(String first, String second) {
  final names = first.split(RegExp(r'[,，、;；/\s]+')).where((name) => name.isNotEmpty);
  return second.trim().isNotEmpty && names.any(second.contains);
}

// 今天的课落到哪些班级（连同这节课的时段）：课表自带班级号就直接用（课程列表里没有时组一个），
// 否则按课名去课程列表里找；同名课对上好几个班时，老师也对得上的优先，都对不上就都算。
List<({ChaoxingCourse course, ChaoxingLessonSlot slot})> chaoxingSlotCourses(List<ChaoxingLessonSlot> slots, List<ChaoxingCourse> courses) {
  final found = <({ChaoxingCourse course, ChaoxingLessonSlot slot})>[];
  for (final slot in slots) {
    if (slot.classId > 0) {
      found.add((
        course: courses.where((course) => course.classId == slot.classId).firstOrNull ??
            ChaoxingCourse(courseId: slot.courseId, classId: slot.classId, name: slot.courseName, teacher: slot.teacher),
        slot: slot,
      ));
      continue;
    }
    final named = [for (final course in courses) if (chaoxingCourseNameMatches(slot.courseName, course.name)) course];
    final taught = [for (final course in named) if (chaoxingTeacherOverlaps(slot.teacher, course.teacher)) course];
    for (final course in taught.isNotEmpty ? taught : named) {
      found.add((course: course, slot: slot));
    }
  }
  return found;
}

// [人工决策-2026-10-17 22:47:20] 「可能正在签到」按这节课算（用户选定，取代参考项目的「发起后 20 分钟内」）：
// 这节课的时段里（开课前半小时到下课后半小时）发起、仍在进行的签到都算，一直算到下课后半小时；不知道发起时刻的不算。
bool chaoxingLessonActivity(ChaoxingActivity activity, ChaoxingLessonSlot slot) {
  final start = activity.startTime;
  return activity.ongoing && start != null && !start.isBefore(slot.start.subtract(_lessonWindow)) && !start.isAfter(slot.end.add(_lessonWindow));
}
