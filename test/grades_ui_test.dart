import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/gateway/campus_gateway.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/page/grades_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'form_layout_support.dart';

const first = TermRef(xn: '2025', xq: '0', label: '2025-2026学年第一学期');
const second = TermRef(xn: '2025', xq: '1', label: '2025-2026学年第二学期');
const student = SessionView(loginId: 'synthetic', name: '', className: '');
const courses = [
  GradeCourse(
    courseCode: 'C1',
    courseName: '测试数学',
    credit: 2,
    score: 90,
    gradePoint: 4,
  ),
  GradeCourse(courseCode: 'C2', courseName: '测试零分', credit: 1, score: 0),
  GradeCourse(courseCode: 'C3', courseName: '测试未公布', credit: 1),
  GradeCourse(courseCode: 'C4', courseName: '测试体育', credit: 1, score: '合格'),
];
const original = [
  GradeCourse(
    courseCode: 'C1',
    courseName: '测试数学',
    credit: 2,
    usualScore: 95,
    finalScore: 88,
    totalScore: 90,
  ),
  GradeCourse(courseCode: 'C1', courseName: '测试数学', credit: 2, totalScore: 92),
];
const summary = GradeSummary(
  earnedCredit: 5,
  gpa: 3.25,
  averageScore: 81.5,
  weightedAverage: 82.1,
);
GradesView view(TermRef term) => GradesView(
  empty: false,
  message: '',
  term: term,
  student: student,
  summary: summary,
  effective: courses,
  original: original,
);
GatewayResult<T> ok<T>(T data) => GatewayResult(
  ok: true,
  source: 'local',
  fetchedAt: '2026-01-01T00:00:00Z',
  data: data,
);
Widget app(Widget child, {double scale = 1}) => MaterialApp(
  theme: campusTheme(),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);
Future<void> reveal(WidgetTester tester, Finder finder) async {
  for (
    var attempt = 0;
    attempt < 12 && finder.hitTestable().evaluate().isEmpty;
    attempt++
  ) {
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [1.0, 1.4, 2.8]) {
    testWidgets('成绩筛选区 ×$scale：学年、搜索、排序标签不压筛选标签，筛选标签不裁切', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await loadCampusFonts(tester);
      await tester.pumpWidget(app(GradesPage(gateway: _Gateway()), scale: scale));
      await tester.pumpAndSettle();
      expectFieldLabelsClear(tester, ['学年', '搜索课程名称或代码', '排序'], '成绩筛选');
      expectChipLabelsUnclipped(tester, '成绩筛选');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('本地打开、搜索筛选不重算汇总，原始多条记录可查看', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(gateway.syncs, 0);
    expect(find.text('3.25'), findsOneWidget);
    final search = find.byType(TextField);
    await reveal(tester, search);
    await tester.enterText(search, '数学');
    await tester.pumpAndSettle();
    final name = find.text('测试数学');
    await reveal(tester, name);
    await tester.tap(name);
    await tester.pumpAndSettle();
    expect(find.text('原始成绩记录 · 2'), findsOneWidget);
    expect(find.textContaining('不推断重修替代关系'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('关闭详情'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 2200));
    await tester.pumpAndSettle();
    expect(find.text('3.25'), findsOneWidget);
    expect(gateway.syncs, 0);
  });
  testWidgets('学年按学期并列，切换期末迟到响应不覆盖新学期', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学年概览'));
    await tester.pumpAndSettle();
    expect(find.text('各学期独立展示，不计算未经教务提供的全年绩点。'), findsOneWidget);
    expect(gateway.yearReads, 1);
    await tester.tap(find.text('学期详情'));
    await tester.pumpAndSettle();
    gateway.hold = Completer<GatewayResult<GradesView>>();
    await tester.tap(find.text('第一学期'));
    await tester.pump();
    await tester.tap(find.text('第二学期'));
    await tester.pumpAndSettle();
    expect(find.text(second.label), findsOneWidget);
    gateway.hold!.complete(ok(view(first)));
    await tester.pumpAndSettle();
    expect(find.text(second.label), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('成绩专页同步默认当前年且不展示课表作息，取消不联网', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '同步'));
    await tester.pumpAndSettle();
    expect(find.text('同步范围'), findsOneWidget);
    expect(find.text('课表'), findsNothing);
    expect(find.text('作息'), findsNothing);
    final boxes = tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    );
    expect(boxes.every((box) => box.value == true), isTrue);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(gateway.syncs, 0);
  });
  testWidgets('360窄屏与1.4字号布局可滚动，0分和未公布不混同', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway), scale: 1.4));
    await tester.pumpAndSettle();
    await reveal(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '零分');
    await tester.pumpAndSettle();
    await reveal(tester, find.text('有效成绩：0'));
    expect(find.text('有效成绩：0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('未知缓存错误显示重试，不伪造暂无成绩', (tester) async {
    final gateway = _Gateway()..failed = true;
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('成绩缓存内容损坏'), findsOneWidget);
    expect(find.text('教务明确暂无成绩记录，不代表0分。'), findsNothing);
    expect(find.text('重新读取本地成绩'), findsOneWidget);
  });
}

class _Gateway implements CampusGateway {
  int syncs = 0;
  int yearReads = 0;
  bool failed = false;
  Completer<GatewayResult<GradesView>>? hold;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => ok([first, second]);
  @override
  Future<GatewayResult<GradesView>> readGrades(TermRef term) async {
    if (failed) {
      return const GatewayResult(
        ok: false,
        source: 'local',
        fetchedAt: '',
        error: GatewayError(code: 'GRADE_DATA_INVALID', message: '成绩缓存内容损坏'),
      );
    }
    if (term.key == first.key && hold != null) return hold!.future;
    return ok(view(term));
  }

  @override
  Future<GatewayResult<List<GradeTermOverview>>> readGradeYear(
    String year,
  ) async {
    yearReads++;
    return ok([
      GradeTermOverview(
        term: first,
        cached: true,
        summary: summary,
        summaryScope: 'term',
      ),
      const GradeTermOverview(term: second, cached: false),
    ]);
  }

  @override
  Future<GatewayResult<GradesView>> syncGrades(TermRef term) async {
    syncs++;
    return ok(view(term));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
