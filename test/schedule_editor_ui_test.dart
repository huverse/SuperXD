import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/gateway/fixture_gateway.dart';
import 'package:superxd/local/schedule_edit.dart';
import 'package:superxd/local/schedule_store.dart';
import 'package:superxd/page/course_editor_page.dart';
import 'package:superxd/page/schedule_editor_page.dart';
import 'package:superxd/theme/campus_theme.dart';

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
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '手工数学');
    await tapVisible(tester, find.text('添加时段'));
    await tapVisible(tester, find.text('单周'));
    await tapVisible(tester, find.text('确定时段'));
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
    await tapVisible(tester, find.text('编辑'));
    await tester.enterText(find.widgetWithText(TextField, '课程名称'), '手工数学新版');
    await tapVisible(tester, find.text('保存课程'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('手工数学新版'), findsOneWidget);
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
    await tapVisible(tester, find.text('新增课程：手工数学'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('变化：课程名称'), findsOneWidget);
    await tapVisible(tester, find.text('恢复此版本'));
    await tapVisible(tester, find.text('确认恢复'));
    await tester.pumpAndSettle();
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
    expect(find.text('周三 第5–6节 · 第7周'), findsOneWidget);
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
    expect(find.text('周一 第1–2节 · 第1–3周 · 教室'), findsOneWidget);
    expect(find.text('周三 第5–6节 · 第7周'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('保存课程'), 200, scrollable: find.byType(Scrollable).first);
    await tapVisible(tester, find.text('保存课程'));
    await tester.runAsync(() async => await Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final saved = (await tester.runAsync(() => gateway.readSchedule(const ScheduleScope.term(term))))!.data!;
    expect(saved.courses.single.courseName, '数据结构');
    expect(saved.courses.single.meetings.map(meetingLabel), unorderedEquals(['周一 第1–2节 · 第1–3周 · 教室', '周三 第5–6节 · 第7周']));
    expect(tester.takeException(), isNull);
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
    await tapVisible(tester, find.text('确定时段'));
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
