import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/grades_page.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

import 'form_layout_support.dart';

// 学期名与「教务汇总 · 本学期」按分项排（DotSeparatedText，窄处在「学年」后、「·」后换行），按整句找要找这个组件；学期分段里的按钮另找。
Finder _dotText(String text) => find.byWidgetPredicate((widget) => widget is DotSeparatedText && widget.text == text);
Finder _segment(String label) => find.descendant(of: find.byType(CampusSegmented<String>), matching: find.text(label));

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
    testWidgets('成绩筛选区 ×$scale：学年标签不压内容，搜索框与筛选按钮同一行，弹层里的选择标签不裁切', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await loadCampusFonts(tester);
      await tester.pumpWidget(app(GradesPage(gateway: _Gateway()), scale: scale));
      await tester.pumpAndSettle();
      expectFieldLabelsClear(tester, ['学年'], '成绩筛选');
      final filter = find.widgetWithText(FilledButton, '筛选');
      expect(tester.getCenter(filter).dy, closeTo(tester.getCenter(find.byType(TextField)).dy, 1));
      await tester.tap(filter);
      await tester.pumpAndSettle();
      expectChipLabelsUnclipped(tester, '成绩筛选弹层', scope: find.byType(CampusSheetPanel));
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
    // 原始成绩每条一组（第 1 条、第 2 条），每项一行。
    expect(find.text('原始成绩'), findsOneWidget);
    expect(find.text('第 2 条'), findsOneWidget);
    // 多条原始记录全部列出，不再加一句口径说明。
    expect(find.textContaining('不推断重修替代关系'), findsNothing);
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
    expect(find.byIcon(CampusIcons.next), findsWidgets);
    expect(find.textContaining('全年绩点'), findsNothing);
    expect(gateway.yearReads, 1);
    await tester.tap(find.text('学期详情'));
    await tester.pumpAndSettle();
    gateway.hold = Completer<GatewayResult<GradesView>>();
    await tester.tap(_segment('第一学期'));
    await tester.pump();
    await tester.tap(_segment('第二学期'));
    await tester.pumpAndSettle();
    expect(_dotText(second.label), findsOneWidget);
    gateway.hold!.complete(ok(view(first)));
    await tester.pumpAndSettle();
    expect(_dotText(second.label), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('学年只有一个学期时不画单项分段，学期名在标题里', (tester) async {
    await tester.pumpWidget(app(GradesPage(gateway: _Gateway()..onlyFirst = true)));
    await tester.pumpAndSettle();
    expect(find.byType(CampusSegmented<String>), findsNothing);
    expect(_dotText(first.label), findsOneWidget);
    // 自绘顶栏与 AppBar 一致：标题从 56 起。
    expect(tester.getTopLeft(find.text('成绩')).dx, 56);
    await tester.pumpWidget(app(GradesPage(key: const ValueKey('two'), gateway: _Gateway())));
    await tester.pumpAndSettle();
    expect(find.byType(CampusSegmented<String>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('学期详情与学年概览切换淡出淡入：分段立即切换，内容先淡出再淡入、不跳变，学期一行随之收起', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    double opacity() => tester.widgetList<SliverFadeTransition>(find.byType(SliverFadeTransition)).first.opacity.value;
    expect(opacity(), 1);
    await tester.tap(find.text('学年概览'));
    await tester.pump();
    expect(tester.widget<CampusSegmented<bool>>(find.byType(CampusSegmented<bool>)).selected, isTrue);
    final values = <double>[];
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      values.add(opacity());
    }
    final lowest = values.indexOf(values.reduce(math.min));
    expect(values[lowest], lessThan(.05));
    for (var index = 1; index <= lowest; index++) {
      expect(values[index], lessThanOrEqualTo(values[index - 1] + 1e-9));
    }
    for (var index = lowest + 1; index < values.length; index++) {
      expect(values[index], greaterThanOrEqualTo(values[index - 1] - 1e-9));
    }
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    expect(find.byIcon(CampusIcons.next), findsWidgets);
    expect(find.textContaining('全年绩点'), findsNothing);
    expect(_segment('第一学期'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('成绩专页同步默认当前年且不展示课表作息，取消不联网', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '同步'));
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
    await reveal(tester, find.text('测试零分'));
    expect(find.text('0'), findsOneWidget);
    expect(find.text('未公布'), findsNothing);
    await tester.enterText(find.byType(TextField), 'C3');
    await tester.pumpAndSettle();
    await reveal(tester, find.text('测试未公布'));
    expect(find.text('未公布'), findsOneWidget);
    expect(find.text('0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('成绩按行列出、分数在右、读屏整句；筛选弹层点了就生效，按钮写改过几项，原始成绩显示总评', (tester) async {
    await tester.pumpWidget(app(GradesPage(gateway: _Gateway())));
    await tester.pumpAndSettle();
    Finder row(String label) => find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == label && widget.properties.button == true);
    await reveal(tester, find.text('测试数学'));
    expect(row('测试数学，成绩 90，学分 2，绩点 4'), findsOneWidget);
    expect(tester.getCenter(find.text('90')).dx, greaterThan(tester.getCenter(find.text('测试数学')).dx));
    // 不及格：分数用警示色并写明「不及格」，不只靠颜色；「合格」不算。
    await reveal(tester, find.text('测试零分'));
    expect(row('测试零分，成绩 0，学分 1，绩点 教务未提供，不及格'), findsOneWidget);
    expect(tester.widget<Text>(find.text('0')).style!.color, CampusPalette.of(tester.element(find.text('0'))).danger);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && (widget.properties.label ?? '').startsWith('测试体育') && (widget.properties.label ?? '').contains('不及格')), findsNothing);
    await reveal(tester, find.text('测试数学'));
    // 课程代码只在详情里，列表不再单列一行。
    expect(find.text('C1'), findsNothing);
    await reveal(tester, find.widgetWithText(FilledButton, '筛选'));
    await tester.tap(find.widgetWithText(FilledButton, '筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(CampusSheetPanel), matching: find.text('原始成绩')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(CampusSheetPanel), matching: find.text('原始成绩')), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(CampusSheetPanel), matching: find.text('按课程名')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '筛选 2'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '原始成绩 · 显示 2 条'), findsOneWidget);
    expect(row('测试数学，总评 92，学分 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('教务明确没有成绩：空状态卡代替全是空值的汇总，学年概览也不画汇总', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final gateway = _Gateway()
      ..custom = ((term) => GradesView(empty: true, message: '教务明确暂无成绩记录', term: term, student: student, summary: null, effective: const [], original: const []))
      ..overviewEmpty = true;
    await tester.pumpWidget(app(GradesPage(gateway: gateway)));
    await tester.pumpAndSettle();
    expect(find.text('这学期还没有成绩'), findsOneWidget);
    // 图标与说明在卡片里水平居中（卡片内容默认按自身宽度靠左）。
    final emptyCard = tester.getRect(find.ancestor(of: find.text('这学期还没有成绩'), matching: find.byType(CampusSurface)).first);
    expect(tester.getCenter(find.text('这学期还没有成绩')).dx, closeTo(emptyCard.center.dx, 1));
    expect(tester.getCenter(find.byType(CampusIcon).last).dx, closeTo(emptyCard.center.dx, 1));
    expect(_dotText('教务汇总 · 本学期'), findsNothing);
    expect(find.text('教务未提供'), findsNothing);
    expect(find.byType(TextField), findsNothing, reason: '没有成绩时不给搜索筛选');
    await tester.tap(find.text('学年概览'));
    await tester.pumpAndSettle();
    expect(find.text('教务明确暂无成绩'), findsOneWidget);
    expect(_dotText('教务汇总 · 本学期'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (width, scale) in [(360.0, 1.0), (411.0, 1.0), (411.0, 1.4)]) {
    testWidgets('教务汇总缺项 ${width.toInt()}dp ×$scale：缺的写「—」，长文字不把标签挤成一字一行；整份没给时写一行', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final gateway = _Gateway()..custom = (term) => GradesView(empty: false, message: '', term: term, student: student, summary: const GradeSummary(earnedCredit: null, gpa: '教务未单独给出绩点', averageScore: 81.5, weightedAverage: '教务未提供加权平均分'), effective: courses, original: original);
      await tester.pumpWidget(app(GradesPage(gateway: gateway), scale: scale));
      await tester.pumpAndSettle();
      expect(find.text('—'), findsOneWidget);
      expect(find.text('81.5'), findsOneWidget);
      for (final label in ['平均分', '加权平均分', '已获学分']) {
        final size = tester.getSize(find.text(label));
        expect(size.width, greaterThan(size.height * label.length * .6), reason: '$label 被挤成竖排');
      }
      // 绩点大字并排时最宽占一小半、再长按比例缩小，上下排时不超出卡片；两种排法都不压到其余三项。
      final card = tester.getRect(find.ancestor(of: find.text('绩点'), matching: find.byType(CampusSurface)).first);
      final hero = tester.getRect(find.text('教务未单独给出绩点'));
      final label = tester.getRect(find.text('平均分'));
      expect(hero.right <= label.left || hero.bottom <= label.top, isTrue);
      expect(hero.right, lessThanOrEqualTo(card.right));
      if (hero.right <= label.left) expect(hero.width, lessThan(card.width * .5));
      expect(tester.takeException(), isNull);

      gateway.custom = (term) => GradesView(empty: false, message: '', term: term, student: student, summary: null, effective: courses, original: original);
      await tester.tap(_segment('第二学期'));
      await tester.pumpAndSettle();
      expect(_dotText('教务汇总 · 本学期'), findsOneWidget);
      expect(find.text('教务没给本学期汇总'), findsOneWidget);
      expect(find.text('绩点'), findsNothing);
      expect(find.text('—'), findsNothing);
    });
  }

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
  // 新学年刚开学时教务只公布了第一学期。
  bool onlyFirst = false;
  Completer<GatewayResult<GradesView>>? hold;
  // 换掉默认的学期成绩（空学期、汇总缺项）；overviewEmpty 时学年概览里第一学期是教务明确无成绩。
  GradesView Function(TermRef term)? custom;
  bool overviewEmpty = false;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => ok(onlyFirst ? [first] : [first, second]);
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
    return ok(custom?.call(term) ?? view(term));
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
        empty: overviewEmpty,
        summary: overviewEmpty ? const GradeSummary(earnedCredit: null, gpa: null, averageScore: null, weightedAverage: null) : summary,
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
