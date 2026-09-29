import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';

const _current = TermRef(xn: '2026', xq: '0', label: '当前学期');
const _source = TermRef(xn: '2025', xq: '1', label: '2025-2026第二学期');
const _student = SessionView(loginId: 'test', name: '', className: '');
GatewayResult<T> _ok<T>(T data) => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: data);

void main() {
  testWidgets('长按勾选后采用作息，页面立即显示时间且弹窗可滚动', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: Scaffold(body: TodayPage(gateway: gateway))));
    await tester.pumpAndSettle();
    expect(find.textContaining('08:00–08:45'), findsNothing);
    await tester.longPress(find.text('同步'));
    await tester.pumpAndSettle();
    expect(find.text('同步内容'), findsOneWidget);
    expect(find.text('同步范围'), findsOneWidget);
    await tester.tap(find.text('课表'));
    await tester.tap(find.text('成绩'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '开始同步'));
    await tester.pumpAndSettle();
    expect(find.text('采用这套作息时间？'), findsOneWidget);
    expect(find.textContaining('08:00–08:45'), findsOneWidget);
    await tester.tap(find.text('用这套'));
    await tester.pumpAndSettle();
    expect(gateway.adopted, isTrue);
    expect(find.text('同步结果'), findsOneWidget);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.textContaining('08:00–08:45'), findsWidgets);
    expect(gateway.scheduleCalls, 0);
    expect(gateway.gradeCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('回到今天分支重新读取开学日，不联网', (tester) async {
    final gateway = _Gateway()..needsStart = true;
    final active = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ValueListenableBuilder<bool>(
      valueListenable: active,
      builder: (context, enabled, child) => TickerMode(enabled: enabled, child: child!),
      child: Scaffold(body: TodayPage(gateway: gateway)),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('设置开学日'), findsOneWidget);
    active.value = false;
    await tester.pump();
    gateway.needsStart = false;
    active.value = true;
    await tester.pumpAndSettle();
    expect(find.text('设置开学日'), findsNothing);
    expect(find.text('测试课'), findsOneWidget);
    expect(gateway.scheduleCalls, 0);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  testWidgets('同步中离开今天页不弹窗，回来提示已中止并列出未处理项，可重新同步', (tester) async {
    final gateway = _Gateway()..scheduleGate = Completer<void>();
    final active = ValueNotifier(true);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: ValueListenableBuilder<bool>(
      valueListenable: active,
      builder: (context, enabled, child) => TickerMode(enabled: enabled, child: child!),
      child: Scaffold(body: TodayPage(gateway: gateway)),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('同步'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '开始同步'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(gateway.scheduleCalls, 1);
    active.value = false;
    await tester.pump();
    gateway.scheduleGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('同步已中止'), findsNothing);
    expect(find.text('同步结果'), findsNothing);
    active.value = true;
    await tester.pumpAndSettle();
    expect(find.text('同步已中止'), findsOneWidget);
    expect(find.text('未处理 · 课表 · 当前学期'), findsOneWidget);
    expect(find.text('未处理 · 作息 · 当前学期'), findsOneWidget);
    expect(find.text('未处理 · 成绩 · 当前学期'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '重新同步'));
    await tester.pumpAndSettle();
    expect(find.text('同步范围'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.scheduleCalls, 1);
    expect(gateway.gradeCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    active.dispose();
  });

  testWidgets('课表页读取同一来源时间，浏览不触发同步且只保留三种范围', (tester) async {
    final gateway = _Gateway()..adopted = true;
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: SchedulePage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('08:00–08:45'), findsOneWidget);
    expect(find.text('周'), findsNothing);
    expect(find.text('天'), findsOneWidget);
    expect(find.text('学期'), findsOneWidget);
    expect(find.text('学年'), findsOneWidget);
    expect(gateway.scheduleCalls, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  bool adopted = false;
  bool needsStart = false;
  int scheduleCalls = 0;
  int gradeCalls = 0;
  Completer<void>? scheduleGate;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => _ok([_current, _source]);
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() => listTerms();
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async {
    if (needsStart) return const GatewayResult(ok: false, source: 'local', fetchedAt: 'stamp', error: GatewayError(code: 'TERM_START_REQUIRED', message: '请选择开学日'));
    final now = campusNow();
    return _ok(ScheduleView(term: scope.term, student: _student, termStartDate: campusToday(), revisionId: 'rev-test', courses: [
      CourseRecord(courseCode: 'C1', courseName: '测试课', sectionId: 'S1', credit: 1, teacherName: '老师', meetings: [CourseMeeting(weekday: now.weekday, periodStart: 1, periodEnd: 1, place: '教室', weeks: [1])]),
    ]));
  }
  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async {
    scheduleCalls++;
    await scheduleGate?.future;
    return readSchedule(ScheduleScope.currentTerm(term));
  }
  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async {
    gradeCalls++;
    return super.syncGrades(term);
  }
  @override
  Future<GatewayResult<BellsView>> syncBells(TermRef term) async => _ok(BellsView(empty: true, message: '', term: term, periods: []));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => _ok(BellsView(
    empty: !adopted && term.key == _current.key, message: '', term: term, sourceTerm: _source,
    periods: adopted || term.key == _source.key ? [const BellPeriod(period: 1, dayPart: '上午', dayPartCode: 'morning', start: '08:00', end: '08:45')] : [],
  ));
  @override
  Future<GatewayResult<TermRef?>> readBellsSource(TermRef term) async => _ok(adopted && term.key == _current.key ? _source : null);
  @override
  Future<GatewayResult<TermRef>> useBellsSource(TermRef target, TermRef source) async {
    adopted = true;
    return _ok(source);
  }
}
