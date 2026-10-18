import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/application/campus_timetable.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/schedule_store.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
];

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) async => '');
  List<TermRef> terms = [_term];
  String? start = '2026-09-07';
  List<BellPeriod> bells = _bells;
  // 合成课程：周二第 1–2 节、第 1–3 周。
  final courses = [
    CourseRecord(courseCode: 'MATH', courseName: '高等数学', sectionId: 'MATH-1', credit: 2, teacherName: '王老师', meetings: [
      CourseMeeting(weekday: 2, periodStart: 1, periodEnd: 2, place: '', weeks: const [1, 2, 3]),
    ]),
  ];
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: terms);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp',
    data: ScheduleView(term: _term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: start, revisionId: 'rev', courses: courses));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: bells.isEmpty, message: '', term: term, periods: bells));
}

void main() {
  test('本应用课表今天的课：按校园日只展开今天，用不了时给原因', () async {
    final gateway = _Gateway();
    // 2026-09-08 周二 07:00（校园时间），当天的课还没开始。
    final tuesday = DateTime.utc(2026, 9, 7, 23);
    final today = await campusTimetableToday(gateway, signedIn: true, now: tuesday);
    expect(today.gap, isNull);
    expect(today.items.map((item) => [item.course.courseName, item.start, item.end]), [
      ['高等数学', DateTime.utc(2026, 9, 8), DateTime.utc(2026, 9, 8, 1, 40)],
    ]);
    // 周三没有这门课。
    expect((await campusTimetableToday(gateway, signedIn: true, now: tuesday.add(const Duration(days: 1)))).items, isEmpty);
    expect((await campusTimetableToday(gateway, signedIn: false, now: tuesday)).gap, TimetableGap.signedOut);
    gateway.terms = [];
    expect((await campusTimetableToday(gateway, signedIn: true, now: tuesday)).gap, TimetableGap.noTerm);
    gateway.terms = [_term];
    gateway.start = null;
    expect((await campusTimetableToday(gateway, signedIn: true, now: tuesday)).gap, TimetableGap.noTermStart);
    gateway.start = '2026-09-07';
    gateway.bells = [];
    expect((await campusTimetableToday(gateway, signedIn: true, now: tuesday)).gap, TimetableGap.noBells);
  });
}
