import 'dart:convert';

import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/gateway/account_access.dart';

import 'fixture_campus_gateway.dart';

// 整应用页面测试共用的合成账号与教务数据（排版体检 text_layout_test.dart、基准图 golden_test.dart）。
const pageTerm = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const pageStudent = SessionView(loginId: '20260000001', name: '林同学', className: '示例计算机班');

// 合成课表：每天同一组课（测试哪天跑都一样），课名、教室长短不一，含括号与无空格的长地点。
List<Map<String, Object?>> _courses() {
  Map<String, Object?> course(String code, String name, String teacher, int start, String place) => {
    'courseCode': code, 'courseName': name, 'sectionId': '$code-01', 'credit': 2, 'teacherName': teacher,
    'meetings': [for (var weekday = 1; weekday <= 7; weekday++) {'weekday': weekday, 'periodStart': start, 'periodEnd': start + 1, 'place': place, 'weeks': [for (var week = 1; week <= 20; week++) week], 'parity': 'all'}],
  };
  return [
    course('A01', '大学英语（三）', '合成教师甲', 1, '知行楼612室'),
    course('A02', '马克思主义基本原理', '合成教师乙', 3, '知行楼414室'),
    course('A03', '程序设计基础与实践', '合成教师丙', 5, '实验中心B区210'),
    course('A04', '体育（羽毛球）', '合成教师丁', 7, '东区体育馆'),
  ];
}

Map<String, String> pageFixtures() {
  final term = {'xn': pageTerm.xn, 'xq': pageTerm.xq, 'label': pageTerm.label};
  final courses = _courses();
  return {
    'schedule.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {'term': term, 'student': {'loginId': pageStudent.loginId, 'name': pageStudent.name, 'className': pageStudent.className}, 'courses': courses}}),
    'bells.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {'empty': false, 'message': '', 'term': term, 'periods': [
      for (final (index, (start, end)) in [('08:00', '08:45'), ('08:55', '09:40'), ('10:00', '10:45'), ('10:55', '11:40'), ('14:00', '14:45'), ('14:55', '15:40'), ('16:00', '16:45'), ('16:55', '17:40')].indexed)
        {'period': index + 1, 'dayPart': '', 'dayPartCode': '', 'start': start, 'end': end},
    ]}}),
    'grades.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {
      'empty': false, 'message': '', 'term': term, 'student': {'loginId': pageStudent.loginId, 'name': pageStudent.name, 'className': pageStudent.className},
      'summary': {'earnedCredit': 8, 'gpa': 3.5, 'averageScore': 85, 'weightedAverage': 85.5}, 'summaryScope': 'term',
      'effective': [for (final course in courses) {'courseCode': course['courseCode'], 'courseName': course['courseName'], 'credit': 2, 'score': 85, 'earnedCredit': 2, 'gradePoint': 3.5}],
      'original': [for (final course in courses) {'courseCode': course['courseCode'], 'courseName': course['courseName'], 'credit': 2, 'usualScore': 85, 'midtermScore': null, 'finalScore': 85, 'skillScore': null, 'totalScore': 85}],
    }}),
  };
}

class FixtureAccounts extends AccountAccess {
  FixtureAccounts(this.inner, {required this.signedIn});
  final FixtureCampusGateway inner;
  final bool signedIn;
  @override
  int get generation => 1;
  @override
  SessionView? get activeSession => signedIn ? pageStudent : null;
  @override
  AccountIdentity? get activeIdentity => signedIn ? AccountIdentity(source: 'https://school.example', loginId: pageStudent.loginId) : null;
  @override
  Future<GatewayResult<SessionView>> restoreSession() async => GatewayResult(ok: signedIn, source: 'local', fetchedAt: 'stamp', data: signedIn ? pageStudent : null);
  @override
  Future<void> cancelLogin() async {}
  @override
  Future<LegacyImportState> legacyImportState() async => const LegacyImportState(available: false, deferred: false);
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() => inner.listTerms();
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) => inner.readSchedule(scope);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) => inner.readGrades(term);
  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(String year) => inner.readGradeYear(year);
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) => inner.readBells(term);
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) => inner.readBellsSource(term);
  @override
  Future<GatewayResult<ReminderSetting>> readReminderSetting(TermRef term) => inner.readReminderSetting(term);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
