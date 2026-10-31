import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/domain/account.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/gateway/account_access.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/main.dart';
import 'package:superxd/page/shell_page.dart';

import 'fixture_campus_gateway.dart';
import 'form_layout_support.dart';
import 'text_fit_support.dart';
import 'toolbox_test_support.dart';

// 主要页面在窄屏大字号、宋体加系统「粗体文本」与宽屏标准三种条件下排版不出错：不裁字、不剩一行标点，课程与提示不留孤字。
// 10-27 用户真机截图（iPhone 系统字体下「09:40」缺半个 0，360dp 安卓学期视图课名一两个字一行、同意行换行留大空行）后加。
const _term = TermRef(xn: '2026', xq: '0', label: '2026-2027学年第一学期');
const _student = SessionView(loginId: '20260000001', name: '林同学', className: '示例计算机班');

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

Map<String, String> _fixtures() {
  final term = {'xn': _term.xn, 'xq': _term.xq, 'label': _term.label};
  final courses = _courses();
  return {
    'schedule.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {'term': term, 'student': {'loginId': _student.loginId, 'name': _student.name, 'className': _student.className}, 'courses': courses}}),
    'bells.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {'empty': false, 'message': '', 'term': term, 'periods': [
      for (final (index, (start, end)) in [('08:00', '08:45'), ('08:55', '09:40'), ('10:00', '10:45'), ('10:55', '11:40'), ('14:00', '14:45'), ('14:55', '15:40'), ('16:00', '16:45'), ('16:55', '17:40')].indexed)
        {'period': index + 1, 'dayPart': '', 'dayPartCode': '', 'start': start, 'end': end},
    ]}}),
    'grades.json': jsonEncode({'fetchedAt': '2026-09-01T00:00:00.000Z', 'data': {
      'empty': false, 'message': '', 'term': term, 'student': {'loginId': _student.loginId, 'name': _student.name, 'className': _student.className},
      'summary': {'earnedCredit': 8, 'gpa': 3.5, 'averageScore': 85, 'weightedAverage': 85.5}, 'summaryScope': 'term',
      'effective': [for (final course in courses) {'courseCode': course['courseCode'], 'courseName': course['courseName'], 'credit': 2, 'score': 85, 'earnedCredit': 2, 'gradePoint': 3.5}],
      'original': [for (final course in courses) {'courseCode': course['courseCode'], 'courseName': course['courseName'], 'credit': 2, 'usualScore': 85, 'midtermScore': null, 'finalScore': 85, 'skillScore': null, 'totalScore': 85}],
    }}),
  };
}

class _Accounts extends AccountAccess {
  _Accounts(this.inner, {required this.signedIn});
  final FixtureCampusGateway inner;
  final bool signedIn;
  @override
  int get generation => 1;
  @override
  SessionView? get activeSession => signedIn ? _student : null;
  @override
  AccountIdentity? get activeIdentity => signedIn ? AccountIdentity(source: 'https://school.example', loginId: _student.loginId) : null;
  @override
  Future<GatewayResult<SessionView>> restoreSession() async => GatewayResult(ok: signedIn, source: 'local', fetchedAt: 'stamp', data: signedIn ? _student : null);
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

// 这一屏的问题（只算错的种类）；orphan 只在 checkOrphans 时算（今天页的「此刻」卡随真实时刻变，不查孤字）。
List<String> _problems(WidgetTester tester, {bool checkOrphans = true}) => [
  for (final issue in scanTexts(tester))
    if (issue.kind != 'truncate' && (checkOrphans || issue.kind != 'orphan')) '$issue',
];

void main() {
  for (final (font, width, system, app, bold) in [
    ('maple', 360.0, 1.3, 1.0, false),
    ('maple', 360.0, 1.0, 1.3, false),
    ('serif', 360.0, 1.0, 1.4, true),
    ('maple', 411.0, 1.0, 1.0, false),
    ('maple', 360.0, 1.0, 1.0, false),
    ('maple', 360.0, 1.0, .8, false),
  ]) {
    testWidgets('排版：$font ${width.toInt()}dp 系统×$system 应用×$app${bold ? ' 粗体文本' : ''}：不裁字、不剩一行标点、课名与提示不留孤字', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = system;
      if (bold) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(boldText: true);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await loadCampusFonts(tester);
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      final fixtures = _fixtures();
      final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
      // 开学日取八周前的周一，今天总在学期中间。
      final today = parseIsoDate(campusToday());
      await inner.setTermStart(_term, formatIsoDate(today.subtract(Duration(days: today.weekday - 1 + 56))));
      final display = DisplaySettings.memory();
      await display.setFont(font);
      // 应用字号是实际显示大小：标准时跟随系统（系统字号照常生效），其余直接给大小（人工决策见 display_settings.dart 的 textSizeMin）。
      await display.setTextSize(app == 1 ? null : app);
      // 学期视图左侧栏按最宽的一项定宽，Maple 标准字号在 360dp 上放得下（人工决策见 schedule_page.dart 的 semesterRailFits），再大就收成横条。
      // 跟随系统时最多到推荐上限，也就是左侧栏放得下的最大字号（人工决策见 display_settings.dart 的 textSizeMin），系统 130% 也照样是左侧栏；
      // 自己选的大字号才收成横条。
      final rail = app <= 1;

      final loggedOut = AppSession(_Accounts(inner, signedIn: false));
      await loggedOut.restore();
      await tester.pumpWidget(SuperXdApp(session: loggedOut, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '登录页');
      // 同意行：「用户协议 和 隐私政策」整组在同一行，换行后行距按文字排，不按 48 的按钮触区撑开。
      expect(tester.getTopLeft(find.text('隐私政策')).dy, closeTo(tester.getTopLeft(find.text('用户协议')).dy, 1));
      expect(tester.getTopLeft(find.text('用户协议')).dy - tester.getTopLeft(find.text('我已阅读并同意')).dy, lessThan(40 * system * app));
      // 登录按钮的图标紧挨着文字（以前按「正在登录」占位，图标与「登录」之间空出两个字宽）。
      final icon = find.descendant(of: find.byType(FilledButton), matching: find.byType(Icon)).first;
      expect(tester.getTopLeft(find.text('登录')).dx - tester.getCenter(icon).dx, closeTo(12 + 8, 1));
      await tester.pumpWidget(const SizedBox());
      loggedOut.dispose();

      final session = AppSession(_Accounts(inner, signedIn: true));
      await session.restore();
      await tester.pumpWidget(SuperXdApp(session: session, display: display, toolbox: fixture.runtime, backgroundPhase: .18));
      await tester.pumpAndSettle();
      expect(_problems(tester, checkOrphans: false), isEmpty, reason: '今天');
      final router = GoRouter.of(tester.element(find.byType(ShellPage)));
      unawaited(router.push('/schedule'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '课表·天');
      await tester.tap(find.text('学期'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '课表·学期');
      // [人工决策] 见 lib/page/schedule_page.dart 的 semesterRailFits：窄屏大字号下月份周次收成卡片上方的一行横条，宽屏照旧竖栏。
      expect(find.textContaining(RegExp(r'^第\d+周 \d+/\d+ · 本周$')), rail ? findsNothing : findsOneWidget);
      expect(find.textContaining(RegExp(r'^第\d+周\n\d+/\d+\n本周$')), rail ? findsOneWidget : findsNothing);
      await tester.tap(find.byTooltip('返回'));
      await tester.pumpAndSettle();
      unawaited(router.push('/grades'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '成绩');
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.runAsync(fixture.close);
    });
  }
}
