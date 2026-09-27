import 'package:flutter_test/flutter_test.dart';
import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/local/period_spans.dart';
import 'package:superxd/local/schedule_store.dart';

CourseRecord course(int start, int end) => CourseRecord(courseCode: '$start', courseName: '课程$start', sectionId: '$end', credit: 1, teacherName: '', meetings: [CourseMeeting(weekday: 1, periodStart: start, periodEnd: end, place: '', weeks: [1])]);
final bells = [for (var period = 1; period <= 10; period++) BellPeriod(period: period, dayPart: '', dayPartCode: period <= 4 ? 'morning' : period <= 8 ? 'afternoon' : 'evening', start: '08:00', end: '08:45')];

void main() {
  test('最后课程到6节仍补7–8，不虚填9–10晚间空课', () {
    final spans = periodSpans([course(1, 2), course(3, 4), course(5, 6)], bells: bells, termLastPeriod: 10);
    expect(spans.map((span) => (span.start, span.end, span.empty)), [(1, 2, false), (3, 4, false), (5, 6, false), (7, 8, true)]);
  });
  test('只上3–4课补所有白天分组；全天无课保持空日', () {
    final spans = periodSpans([course(3, 4)], bells: bells);
    expect(spans.map((span) => (span.start, span.end)), [(1, 2), (3, 4), (5, 6), (7, 8)]);
    expect(periodSpans([], bells: bells), isEmpty);
  });
  test('有晚课才延伸；无作息按学期边界；重叠课保留', () {
    expect(periodSpans([course(3, 4), course(9, 10)], bells: bells).last.end, 10);
    expect(periodSpans([course(3, 4)], termLastPeriod: 8).last.end, 8);
    expect(periodSpans([course(1, 4), course(3, 6)], bells: bells).where((span) => !span.empty), hasLength(2));
    final gap = periodSpans([course(1, 2)], bells: bells.where((bell) => bell.period != 6).toList());
    expect(gap.where((span) => span.empty).any((span) => span.start <= 6 && span.end >= 6), isFalse);
  });
  test('第一张课不是第 1 节时，前面留出空节', () {
    final courses = [
      CourseRecord(
        courseCode: 'C',
        courseName: 'Java程序设计',
        sectionId: 'S',
        credit: 2,
        teacherName: '董福宪',
        meetings: [CourseMeeting(weekday: 3, periodStart: 3, periodEnd: 4, place: '知勤庭311室', weeks: const [1])],
      ),
    ];
    final spans = periodSpans(courses);
    expect(spans.first.empty, isTrue);
    expect(spans.first.start, 1);
    expect(spans.first.end, 2);
    expect(spans[1].course!.courseName, 'Java程序设计');
  });
}
