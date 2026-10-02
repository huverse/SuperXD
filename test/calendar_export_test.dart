import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/course_occurrence.dart';
import 'package:superxd/domain/ical.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
];

CourseRecord _course(String name, {int start = 1, int end = 2, List<int> weeks = const [1], String teacher = '张老师', String place = '知敬楼405室'}) =>
    CourseRecord(courseCode: name, courseName: name, sectionId: name, credit: 2, teacherName: teacher, meetings: [CourseMeeting(weekday: 1, periodStart: start, periodEnd: end, place: place, weeks: weeks)]);

// 开学日 2026-09-07 为周一。
List<CourseOccurrence> _occurrences(List<CourseRecord> courses) =>
    courseOccurrences(courses: courses, termStartDate: '2026-09-07', bells: _bells, from: '2026-09-07', to: '2027-01-31').items;

String _ical(List<CourseRecord> courses, {TermRef term = _term, DateTime? stamp}) =>
    buildIcal(term: term, occurrences: _occurrences(courses), stamp: stamp ?? DateTime.utc(2026, 10, 3, 4, 5, 6));

List<String> _uids(String ical) => [for (final line in ical.split('\r\n')) if (line.startsWith('UID:')) line];

void main() {
  test('日历结构完整、全部 CRLF 换行，时刻按校园时区换算为 UTC', () {
    final ical = _ical([_course('高等数学', weeks: [1, 2])]);
    expect(ical, startsWith('BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'));
    expect(ical, endsWith('END:VCALENDAR\r\n'));
    expect(RegExp(r'(?<!\r)\n').hasMatch(ical), isFalse);
    expect(RegExp('BEGIN:VEVENT').allMatches(ical), hasLength(2));
    expect(ical, contains('\r\nDTSTAMP:20261003T040506Z\r\n'));
    expect(ical, contains('\r\nDTSTART:20260907T000000Z\r\nDTEND:20260907T014000Z\r\n'));
    expect(ical, contains('\r\nDTSTART:20260914T000000Z\r\n'));
    expect(ical, contains('\r\nSUMMARY:高等数学\r\nLOCATION:知敬楼405室\r\nDESCRIPTION:第1–2节 · 教师：张老师\r\n'));
  });

  test('文本转义反斜杠、分号、逗号与换行；空地点不写 LOCATION', () {
    final ical = _ical([_course('A,B;C\\D\nE', place: '', teacher: '')]);
    expect(ical, contains(r'SUMMARY:A\,B\;C\\D\nE' '\r\n'));
    expect(ical, isNot(contains('LOCATION')));
    expect(ical, contains('DESCRIPTION:第1–2节\r\n'));
  });

  test('超过 75 个八位组折行，续行以空格开头，不切断多字节字符，展开后还原', () {
    final name = '课' * 200;
    final ical = _ical([_course(name)]);
    final lines = ical.split('\r\n')..removeLast();
    for (final line in lines) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(75), reason: line);
    }
    expect(lines.where((line) => line.startsWith(' ')), isNotEmpty);
    expect(ical.replaceAll('\r\n ', ''), contains('\r\nSUMMARY:$name\r\n'));
    final exact = 'A' * (75 - 'SUMMARY:'.length);
    expect(_ical([_course(exact)]), contains('\r\nSUMMARY:$exact\r\n'));
    expect(_ical([_course('${exact}B')]), contains('\r\nSUMMARY:$exact\r\n B\r\n'));
  });

  test('UID 只由学期、课程、日期与节次决定：重复导出不变，学期之间不撞', () {
    final courses = [_course('高等数学', weeks: [1, 2, 3]), _course('英语', start: 2, end: 2, weeks: [1])];
    final first = _uids(_ical(courses));
    expect(first, hasLength(4));
    expect(first.toSet(), hasLength(4));
    expect(_uids(_ical(courses, stamp: DateTime.utc(2027))), first);
    expect(_uids(_ical(courses, term: const TermRef(xn: '2026', xq: '1', label: ''))).toSet().intersection(first.toSet()), isEmpty);
    expect(first.every((uid) => RegExp(r'^UID:[0-9a-f]{32}@superxd$').hasMatch(uid)), isTrue);
  });

  test('超过单次上限拒绝生成', () {
    final occurrence = _occurrences([_course('高等数学')]).single;
    expect(() => buildIcal(term: _term, occurrences: List.filled(icalEventLimit + 1, occurrence), stamp: DateTime.utc(2026)), throwsArgumentError);
  });

  group('课表页导出', () {
    Future<_Open> open(WidgetTester tester, _Gateway gateway, {Object? failure}) async {
      final calendar = _Open(failure);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')], localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: SchedulePage(key: ObjectKey(gateway), gateway: gateway, openCalendar: calendar.call))));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('课前提醒'), findsNothing);
      await tester.tap(find.text('导出到日历'));
      await tester.pumpAndSettle();
      return calendar;
    }

    testWidgets('导出当前学期全部上课时段，文件名带学期', (tester) async {
      final calendar = await open(tester, _Gateway(courses: [_course('高等数学', weeks: [1, 2, 3, 4])]));
      expect(calendar.calls, hasLength(1));
      expect(calendar.calls.single.fileName, 'SuperXD_课表_2026-2027学年第一学期.ics');
      expect(RegExp('BEGIN:VEVENT').allMatches(calendar.calls.single.content), hasLength(4));
      expect(tester.takeException(), isNull);
    });

    testWidgets('缺作息或开学日时说明原因，不导出', (tester) async {
      var calendar = await open(tester, _Gateway(courses: [_course('高等数学')], bells: const []));
      expect(find.text('缺少作息时间，同步作息后才能导出。'), findsOneWidget);
      expect(calendar.calls, isEmpty);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      calendar = await open(tester, _Gateway(courses: [_course('高等数学')], start: null));
      expect(find.text('请先设置开学日。'), findsOneWidget);
      expect(calendar.calls, isEmpty);
    });

    testWidgets('作息里找不到的节次不猜时刻，导出前说明数量，可取消', (tester) async {
      final gateway = _Gateway(courses: [_course('高等数学'), _course('晚课', start: 9, end: 10)]);
      var calendar = await open(tester, gateway);
      expect(find.text('有 1 个时段的节次不在作息时间里，无法确定上课时间。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calendar.calls, isEmpty);
      calendar = await open(tester, _Gateway(courses: gateway.courses));
      await tester.tap(find.text('继续导出'));
      await tester.pumpAndSettle();
      expect(RegExp('BEGIN:VEVENT').allMatches(calendar.calls.single.content), hasLength(1));
      expect(calendar.calls.single.content, isNot(contains('晚课')));
    });

    testWidgets('交给日历失败时提示', (tester) async {
      await open(tester, _Gateway(courses: [_course('高等数学')]), failure: const FileSystemException('disk full'));
      expect(find.text('无法打开日历，请稍后再试。'), findsOneWidget);
    });
  });
}

class _Open {
  _Open(this.failure);
  final Object? failure;
  final calls = <({String fileName, String content})>[];
  Future<void> call(String fileName, String content) async {
    calls.add((fileName: fileName, content: content));
    if (failure case final failure?) throw failure;
  }
}

class _Gateway extends FixtureCampusGateway {
  _Gateway({required this.courses, this.bells = _bells, this.start = '2026-09-07'}) : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  final List<CourseRecord> courses;
  final List<BellPeriod> bells;
  final String? start;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: [_term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp',
    data: ScheduleView(term: _term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: start, revisionId: 'rev-test', courses: courses));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: bells.isEmpty, message: '', term: term, periods: bells));
}
