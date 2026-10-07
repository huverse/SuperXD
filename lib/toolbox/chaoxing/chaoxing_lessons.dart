import 'dart:convert';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_client.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_http.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 按学习通课表推断「可能正在签到」：当前节次前后 30 分钟内的课，去它的课程里找刚发起（20 分钟内）的进行中签到。
// 课表来自学习通自己的课表接口，与教务课表无关；本机缓存 7 天（见 chaoxing_store.dart）。
const chaoxingLessonsUri = 'https://kb.chaoxing.com/pc/curriculum/getMyLessons';
const chaoxingLessonWindowMinutes = 30;
const chaoxingFreshActivityWindow = Duration(minutes: 20);

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

// 当前时刻前后半小时内在上的课（按校园时区的星期与钟点）。
List<ChaoxingLesson> chaoxingCurrentLessons(ChaoxingLessonTable table, DateTime now) {
  final local = campusInstant(now);
  final minute = local.hour * 60 + local.minute;
  final week = chaoxingCurrentWeek(table.firstWeekDate, now);
  return [
    for (final lesson in table.lessons)
      if (lesson.dayOfWeek == local.weekday &&
          lesson.weeks.contains(week) &&
          lesson.startMinute - chaoxingLessonWindowMinutes <= minute &&
          minute <= lesson.endMinute + chaoxingLessonWindowMinutes)
        lesson,
  ];
}

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

// 课表里的课落到哪些班级：课表自带班级号就直接用，否则按课名去课程列表里找（同名课可能有多个班）。
List<ChaoxingCourse> chaoxingLessonCourses(List<ChaoxingLesson> lessons, List<ChaoxingCourse> courses) {
  final found = <int, ChaoxingCourse>{};
  for (final lesson in lessons) {
    if (lesson.classId > 0) {
      found[lesson.classId] =
          courses.where((course) => course.classId == lesson.classId).firstOrNull ??
          ChaoxingCourse(courseId: lesson.courseId, classId: lesson.classId, name: lesson.courseName, teacher: lesson.teacher);
      continue;
    }
    for (final course in courses) {
      if (chaoxingCourseNameMatches(lesson.courseName, course.name)) found[course.classId] = course;
    }
  }
  return found.values.toList();
}

// 刚发起的进行中签到：status 为 1，且发起不超过 20 分钟。
bool chaoxingFreshActivity(ChaoxingActivity activity, DateTime now) =>
    activity.ongoing && activity.startTime.add(chaoxingFreshActivityWindow).isAfter(now);
