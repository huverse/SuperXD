import 'package:flutter_test/flutter_test.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/page/schedule_calendar.dart';

void main() {
  test('学期月份按周一归属，跨月的周不重复', () {
    expect(monthsOfTerm('2024-01-03', 2), [1]);
    expect(weeksOfMonth('2024-01-03', 2, 1), [1, 2]);
    expect(weekRailLabel('2024-01-03', 1), '第1周\n1/3');
    expect(dayInWeek(termStartDate: '2024-01-03', week: 1, today: '2024-01-03'), '2024-01-03');
    expect(dayInWeek(termStartDate: '2024-01-03', week: 2, today: '2024-01-03'), '1/8'.replaceAll('1/8', '2024-01-08'));
    expect(semesterDays('2024-01-03', 1).first, '2024-01-03');
    expect(weekDates('2024-01-03').first, '2024-01-01');
    expect(maxCourseWeek([
      CourseRecord(courseCode: 'C', courseName: '课', sectionId: 'S', credit: 1, teacherName: '师', meetings: [
        CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '室', weeks: [3, 18]),
      ]),
    ]), 18);
  });
}
