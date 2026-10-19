import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_editor_page.dart';
import 'package:superxd/page/schedule_editor_page.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';

const term = TermRef(xn: '2090', xq: '0', label: '测试学期');
Widget app(Widget page, {double scale = 1}) => MaterialApp(
  theme: campusTheme(),
  locale: const Locale('zh', 'CN'),
  supportedLocales: const [Locale('zh', 'CN')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: page,
);

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('手工加课、多时段、保存、删课撤销与版本恢复完整闭环', (tester) async {
    final fixtures = {
      for (final name in [
        'schedule.json',
        'grades.json',
        'bells.json',
        'grades.empty.json',
        'bells.empty.json',
      ])
        name: File('assets/fixtures/$name').readAsStringSync(),
    };
    final gateway = FixtureCampusGateway(
      readText: (name) async => fixtures[name]!,
    );
    await tester.pumpWidget(
      app(ScheduleEditorPage(gateway: gateway, term: term)),
    );
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    await tapVisible(tester, find.text('新增课程'));
    // 字数计数平时不显示，剩 20 字以内才出现。
    expect(find.text('0/200'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '课' * 185);
    await tester.pump();
    expect(find.text('185/200'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '手工数学');
    await tapVisible(tester, find.text('添加时段'));
    await tapVisible(tester, find.text('单周'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '确定'));
    await tapVisible(tester, find.text('保存课程'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('手工数学'), findsOneWidget);
    final saved = (await tester.runAsync(
      () => gateway.readSchedule(const ScheduleScope.term(term)),
    ))!.data!;
    expect(
      saved.courses.single.meetings.single.weeks.every((week) => week.isOdd),
      isTrue,
    );
    expect(saved.courses.single.localId, isNotEmpty);
    // 整卡可点进编辑；删除在卡片右上 ⋯ 菜单里。
    await tapVisible(tester, find.text('手工数学'));
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '手工数学新版');
    await tapVisible(tester, find.text('保存课程'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('手工数学新版'), findsOneWidget);
    // 二级页标题统一从 56 起（返回图标对齐内容左边距 16）。
    expect(tester.getTopLeft(find.text('管理课程')).dx, 56);
    await tapVisible(tester, find.byTooltip('课程操作'));
    // ⋯ 菜单里的删除是警示色。
    expect(tester.widget<Text>(find.text('删除')).style?.color, CampusPalette.of(tester.element(find.text('删除'))).danger);
    await tapVisible(tester, find.text('删除'));
    await tapVisible(tester, find.text('整门课程（所有时段和周次）'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '删除'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('手工数学新版'), findsNothing);
    await tapVisible(tester, find.text('撤销'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('手工数学新版'), findsOneWidget);
    await tester.tap(find.byTooltip('历史版本'));
    await tester.pumpAndSettle();
    // 时间线按日期分组，当前在用的标「当前」；筛「教务同步」时这几条本地修改都不显示。
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('当前'), findsOneWidget);
    await tapVisible(tester, find.text('教务同步'));
    expect(find.text('新增课程：手工数学'), findsNothing);
    expect(find.text('这一类还没有版本'), findsOneWidget);
    await tapVisible(tester, find.text('我的修改'));
    await tapVisible(tester, find.text('新增课程：手工数学'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    // 写清恢复后和现在比会怎样：改回课程名称，旧 → 新。
    expect(find.text('恢复到这个版本，和现在相比：'), findsOneWidget);
    expect(find.text('会改回 1 门'), findsOneWidget);
    expect(find.text('课程名称：手工数学新版 → 手工数学'), findsOneWidget);
    await tapVisible(tester, find.text('恢复到这个版本'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '恢复'));
    await tester.pumpAndSettle();
    // 列表里多出一条恢复，写恢复到哪个时刻的样子，不写版本序号。
    expect(find.textContaining(RegExp(r'^恢复到 \d+月\d+日 \d\d:\d\d 的样子$')), findsOneWidget);
    final restored = (await tester.runAsync(
      () => gateway.readSchedule(const ScheduleScope.term(term)),
    ))!.data!;
    expect(restored.courses.single.courseName, '手工数学');
    expect(restored.courses.single.localId, saved.courses.single.localId);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无课时段新增课程预填星期节次且仅本周，未改动返回不提示', (tester) async {
    final fixtures = {
      for (final name in ['schedule.json', 'bells.json', 'bells.empty.json'])
        name: File('assets/fixtures/$name').readAsStringSync(),
    };
    final gateway = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
    Future<void> settle() async {
      await tester.runAsync(() async => await Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }
    Widget page(int generation) => ScheduleEditorPage(
      key: ValueKey(generation), gateway: gateway, term: term,
      slot: CourseMeeting(weekday: 3, periodStart: 5, periodEnd: 6, place: '', weeks: [7]),
    );
    await tester.pumpWidget(app(page(1)));
    await settle();
    expect(find.bySemanticsLabel('周三 第5–6节 · 第7周'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存修改？'), findsNothing);
    expect(find.text('管理课程'), findsOneWidget);
    await tester.pumpWidget(app(page(2)));
    await settle();
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '补课');
    await tapVisible(tester, find.text('保存课程'));
    await settle();
    final saved = (await tester.runAsync(() => gateway.readSchedule(const ScheduleScope.term(term))))!.data!;
    expect(saved.courses.single.courseName, '补课');
    expect(saved.courses.single.meetings.map(meetingLabel), ['周三 第5–6节 · 第7周']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('安排已有课程把本周时段追加到所选课程，原时段不变', (tester) async {
    final fixtures = {
      for (final name in ['schedule.json', 'bells.json', 'bells.empty.json'])
        name: File('assets/fixtures/$name').readAsStringSync(),
    };
    final gateway = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
    final seed = CourseRecord(courseCode: 'C1', courseName: '数据结构', sectionId: 'S1', credit: 2, teacherName: '王老师', meetings: [
      CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '教室', weeks: [1, 2, 3]),
    ]);
    await tester.runAsync(() => gateway.saveScheduleRevision(term, [seed], '种子', expectedRevisionId: null));
    await tester.pumpWidget(app(ScheduleEditorPage(
      gateway: gateway, term: term, courseId: courseKey(seed),
      slot: CourseMeeting(weekday: 3, periodStart: 5, periodEnd: 6, place: '', weeks: [7]),
    )));
    await tester.runAsync(() async => await Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('编辑课程'), findsOneWidget);
    // 预填的本周时段带上这门课的老师。
    expect(find.bySemanticsLabel('周一 第1–2节 · 第1–3周 · 教室 · 王老师'), findsOneWidget);
    expect(find.bySemanticsLabel('周三 第5–6节 · 第7周 · 王老师'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('保存课程'), 200, scrollable: find.byType(Scrollable).first);
    await tapVisible(tester, find.text('保存课程'));
    await tester.runAsync(() async => await Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(() => gateway.readSchedule(const ScheduleScope.term(term))))!.data!;
    expect(saved.courses.single.courseName, '数据结构');
    expect(saved.courses.single.meetings.map(meetingLabel), unorderedEquals(['周一 第1–2节 · 第1–3周 · 教室', '周三 第5–6节 · 第7周']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('同名不同老师的教学班合成一门：一张卡、整门改名与删除，点时段直接改、范围在弹窗里选', (tester) async {
    final fixtures = {
      for (final name in ['schedule.json', 'bells.json', 'bells.empty.json'])
        name: File('assets/fixtures/$name').readAsStringSync(),
    };
    final gateway = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
    Future<void> settle() async {
      await tester.runAsync(() async => await Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
    }
    final lecture = CourseRecord(courseCode: 'C1', courseName: '数据结构', sectionId: 'S1', credit: 3, teacherName: '甲老师', meetings: [
      CourseMeeting(weekday: 1, periodStart: 1, periodEnd: 2, place: '一教', weeks: [1, 2, 3]),
    ]);
    final lab = CourseRecord(courseCode: 'C1', courseName: '数据结构', sectionId: 'S2', credit: 3, teacherName: '乙老师', meetings: [
      CourseMeeting(weekday: 3, periodStart: 5, periodEnd: 6, place: '实验楼', weeks: [2, 4]),
    ]);
    await tester.runAsync(() => gateway.saveScheduleRevision(term, [lecture, lab], '种子', expectedRevisionId: null));
    await tester.pumpWidget(app(ScheduleEditorPage(gateway: gateway, term: term)));
    await settle();
    // 一张卡，老师写在各自的时段后面；右侧只有⋯、没有箭头，⋯里只有删除。
    expect(find.text('数据结构'), findsOneWidget);
    expect(find.byTooltip('课程操作'), findsOneWidget);
    // 整卡是一个按钮，读屏把课名与各时段合成一句。
    expect(find.bySemanticsLabel(RegExp('数据结构.*周一 第1–2节 · 第1–3周 · 一教 · 甲老师.*周三 第5–6节 · 第2、4周 · 实验楼 · 乙老师', dotAll: true)), findsOneWidget);
    expect(find.byIcon(CampusIcons.next), findsNothing);
    await tapVisible(tester, find.byTooltip('课程操作'));
    expect(find.text('编辑'), findsNothing);
    expect(find.text('删除'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // 点卡片编辑整门课：改课名；点时段卡直接进弹窗，在顶部选「只改某一周」，把第 2 周挪到周五。
    await tapVisible(tester, find.text('数据结构'));
    expect(find.text('编辑课程'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '数据结构与算法');
    await tapVisible(tester, find.bySemanticsLabel('周三 第5–6节 · 第2、4周 · 实验楼 · 乙老师'));
    expect(find.text('全部周次'), findsOneWidget);
    await tapVisible(tester, find.text('只改某一周'));
    await tapVisible(tester, find.text('第2周'));
    await tapVisible(tester, find.text('周五'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '确定'));
    expect(find.bySemanticsLabel('周三 第5–6节 · 第4周 · 实验楼 · 乙老师'), findsOneWidget);
    expect(find.bySemanticsLabel('周五 第5–6节 · 第2周 · 实验楼 · 乙老师'), findsOneWidget);
    await tapVisible(tester, find.text('保存课程'));
    await settle();
    final saved = (await tester.runAsync(() => gateway.readSchedule(const ScheduleScope.term(term))))!.data!;
    // 存储仍按教学班：两条都改了名，各自的老师与教学班标识不变。
    expect(saved.courses.map((course) => course.sectionId), ['S1', 'S2']);
    expect(saved.courses.map((course) => course.courseName).toSet(), {'数据结构与算法'});
    expect(saved.courses.map((course) => course.teacherName), ['甲老师', '乙老师']);
    expect(saved.courses.last.meetings.map(meetingLabel), unorderedEquals(['周三 第5–6节 · 第4周 · 实验楼', '周五 第5–6节 · 第2周 · 实验楼']));
    // 删除整门课一次删掉两个教学班。
    await tapVisible(tester, find.byTooltip('课程操作'));
    await tapVisible(tester, find.text('删除'));
    await tapVisible(tester, find.text('整门课程（所有时段和周次）'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '删除'));
    await settle();
    expect((await tester.runAsync(() => gateway.readSchedule(const ScheduleScope.term(term))))!.data!.courses, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('周次是等宽网格；快捷选周只亮正好匹配的一项，点格子单独增减', (tester) async {
    await tester.pumpWidget(app(Builder(builder: (context) => Scaffold(body: TextButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CourseEditorPage(courses: const [], bells: const [], onSave: (course) async => null))),
      child: const Text('打开编辑'),
    )))));
    await tapVisible(tester, find.text('打开编辑'));
    await tapVisible(tester, find.text('添加时段'));
    bool preset(String label) => tester.widget<CampusGlassChip>(find.widgetWithText(CampusGlassChip, label)).selected;
    Finder cell(int number) => find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '第$number周');
    bool week(int number) => tester.widget<Semantics>(cell(number)).properties.selected == true;
    await tapVisible(tester, find.text('单周'));
    expect([preset('全选'), preset('单周'), preset('双周'), preset('清空')], [false, true, false, false]);
    expect([week(1), week(2), week(3)], [true, false, true]);
    // 各格同宽，一行一行对齐。
    expect(tester.getSize(cell(1)), tester.getSize(cell(2)));
    await tapVisible(tester, cell(2));
    expect(week(2), isTrue);
    expect(preset('单周'), isFalse);
  });

  testWidgets('窄屏大字周次表单可滚动，失败保留草稿，返回须确认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var calls = 0;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CourseEditorPage(
                    courses: const [],
                    bells: const [],
                    onSave: (course) async {
                      calls++;
                      return '测试存储失败';
                    },
                  ),
                ),
              ),
              child: const Text('打开编辑'),
            ),
          ),
        ),
        scale: 1.4,
      ),
    );
    await tapVisible(tester, find.text('打开编辑'));
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '保留草稿');
    await tapVisible(tester, find.text('添加时段'));
    await tapVisible(tester, find.widgetWithText(FilledButton, '确定'));
    await tapVisible(tester, find.text('保存课程'));
    expect(calls, 1);
    expect(find.text('测试存储失败'), findsOneWidget);
    expect(find.widgetWithText(TextField, '保留草稿'), findsOneWidget);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存修改？'), findsOneWidget);
    await tapVisible(tester, find.text('取消'));
    expect(find.text('编辑课程'), findsNothing);
    expect(find.text('新增课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
