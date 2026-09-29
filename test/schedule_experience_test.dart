import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/gateway/fixture_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/date_rail.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/term_start_dialog.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const term = TermRef(xn: '2026', xq: '0', label: '2026–2027第一学期');
const bells = [
  BellPeriod(period: 1, dayPart: '', dayPartCode: '', start: '08:00', end: '08:45'),
  BellPeriod(period: 2, dayPart: '', dayPartCode: '', start: '08:55', end: '09:40'),
  BellPeriod(period: 3, dayPart: '', dayPartCode: '', start: '10:00', end: '10:45'),
  BellPeriod(period: 4, dayPart: '', dayPartCode: '', start: '10:55', end: '11:40'),
];
CourseRecord course(int start, int end, {String name = '课程'}) => CourseRecord(courseCode: 'C$start', courseName: name, sectionId: 'S$start', credit: 1, teacherName: '老师', meetings: [CourseMeeting(weekday: 1, periodStart: start, periodEnd: end, place: '教室', weeks: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18])]);
Widget app(Widget child) => MaterialApp(theme: campusTheme(), locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')], localizationsDelegates: GlobalMaterialLocalizations.delegates, home: Scaffold(body: child));

void main() {
  test('12课程13教学班完整保留，不再用行数判定失败', () {
    String row(int code, int section) => '<tr>${['S$section', '班', '[C$code]课程$code', '32', '1', '初修', '[T]老师', '选中', '否', '是', '1-18周 一[1-2] 教室', ''].map((value) => '<td>$value</td>').join()}</tr>';
    final html = '<h1>学生个人课表</h1><p>课程门数：12</p><table><thead><tr><th>上课时间地点</th></tr></thead><tbody>${List.generate(12, (i) => row(i, i)).join()}${row(9, 13)}</tbody></table>';
    final parsed = parseScheduleHtml(html);
    expect(parsed.courses, hasLength(13));
    expect(parsed.courses.map((item) => item.courseCode).toSet(), hasLength(12));
    expect(parsed.courses.last.sectionId, 'S13');
  });

  test('倒计时只对今天当前和下一节；秒向上取整且边界明确', () {
    final spans = periodSpans([course(1, 2), course(3, 4)]);
    final countdown = courseCountdowns(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 24, 0, 44, 30));
    expect(countdown.values, contains('距离下课还有56分钟'));
    expect(countdown.values, contains('距离上课还有76分钟'));
    expect(courseCountdowns(spans, bells, '2026-09-23', DateTime.utc(2026, 9, 24)), isEmpty);
    expect(courseCountdowns(spans, [], '2026-09-24', DateTime.utc(2026, 9, 24)), isEmpty);
    final atEnd = courseCountdowns(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 24, 1, 40));
    expect(atEnd.values, ['距离上课还有20分钟']);
  });

  testWidgets('空课与正课等高，大字不溢出，详情可点空白关闭', (tester) async {
    final spans = periodSpans([course(3, 4)]);
    String? detail;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, update) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: CourseDayCards(
      spans: spans, bells: bells, date: '2026-09-21', detailKey: detail, onDetail: (key) => update(() => detail = key),
    )))));
    await tester.pumpAndSettle();
    final empty = find.byKey(ValueKey('course-card-${spanIdentity(spans.first)}'));
    final normal = find.byKey(ValueKey('course-card-${spanIdentity(spans.last)}'));
    expect(tester.getSize(empty).height, tester.getSize(normal).height);
    expect(tester.getSize(empty).width, tester.getSize(normal).width);
    await tester.longPress(find.text('课程'));
    await tester.pumpAndSettle();
    expect(find.textContaining('学分'), findsOneWidget);
    await tester.tapAt(const Offset(790, 580));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无课卡长按展开新增与安排已有课程，点击收起；未接入时长按无反应', (tester) async {
    final spans = periodSpans([course(3, 4)]);
    String? detail;
    PeriodSpan? created;
    PeriodSpan? arranged;
    Widget cards({required bool editable}) => StatefulBuilder(builder: (context, update) => CourseDayCards(
      spans: spans, bells: bells, date: '2026-09-21', detailKey: detail, onDetail: (key) => update(() => detail = key), onEdit: (_) {},
      onCreate: editable ? (span) => created = span : null, onArrange: editable ? (span) => arranged = span : null,
    ));
    await tester.pumpWidget(app(cards(editable: false)));
    await tester.longPress(find.text('早八没课哦~'));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    expect(find.text('新增课程'), findsNothing);
    await tester.pumpWidget(app(cards(editable: true)));
    await tester.tap(find.text('早八没课哦~'));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    await tester.longPress(find.text('早八没课哦~'));
    await tester.pumpAndSettle();
    expect(detail, spanIdentity(spans.first));
    await tester.tap(find.text('新增课程'));
    await tester.tap(find.text('安排已有课程'));
    expect([created?.start, created?.end, arranged?.start, arranged?.end], [1, 2, 1, 2]);
    await tester.tap(find.text('早八没课哦~'));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    expect(find.text('新增课程'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有课卡单击不展开，长按展开编辑入口，展开后单击收起', (tester) async {
    final spans = periodSpans([course(3, 4)]);
    String? detail;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, update) => CourseDayCards(
      spans: spans, bells: bells, date: '2026-09-21', detailKey: detail, onDetail: (key) => update(() => detail = key), onEdit: (_) {},
    ))));
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    expect(find.text('编辑课程'), findsNothing);
    await tester.longPress(find.text('课程'));
    await tester.pumpAndSettle();
    expect(detail, spanIdentity(spans.last));
    expect(find.text('编辑课程'), findsOneWidget);
    await tester.tap(find.text('课程'));
    await tester.pumpAndSettle();
    expect(detail, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表页长按无课卡安排已有课程，预填当天星期节次且仅本周', (tester) async {
    await tester.pumpWidget(app(SchedulePage(gateway: _EveryDayGateway())));
    await tester.pumpAndSettle();
    final today = campusToday();
    final date = today.compareTo('2026-08-31') < 0 || today.compareTo('2027-01-03') > 0 ? '2026-08-31' : today;
    await tester.longPress(find.text('早八没课哦~'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('安排已有课程'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程 · 老师'));
    await tester.pumpAndSettle();
    expect(find.text('编辑课程'), findsOneWidget);
    final slot = find.text('周${weekdayLabel(weekdayOf(date))} 第1–2节 · 第${weekIndex('2026-08-31', date)}周');
    await tester.scrollUntilVisible(slot, 200, scrollable: find.byType(Scrollable).first);
    expect(slot, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('玻璃栏遮挡区：放得下时按可见区排布且不可滚动，不影响切日手势', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final spans = periodSpans([course(3, 4, name: '高等数学'), course(5, 6, name: '大学英语'), course(7, 8, name: '大学物理')]);
    await tester.pumpWidget(app(CourseDayCards(spans: spans, bells: bells, date: '2026-09-21', obscuredBottom: 60)));
    await tester.pumpAndSettle();
    for (final span in spans) {
      expect(tester.getBottomRight(find.byKey(ValueKey('course-card-${spanIdentity(span)}'))).dy, lessThanOrEqualTo(540 - 60));
    }
    expect(tester.state<ScrollableState>(find.byType(Scrollable)).position.maxScrollExtent, 0);
    expect(tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade)).top, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('玻璃栏遮挡区：溢出时末项可滚到遮挡区之上，顶部淡出只随滚动出现', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final spans = periodSpans([for (var start = 1; start <= 9; start += 2) course(start, start + 1, name: '课程$start')]);
    await tester.pumpWidget(app(CourseDayCards(spans: spans, bells: const [], date: '2026-09-21', obscuredBottom: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade)).top, 0);
    await tester.drag(find.byType(Scrollable), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(tester.getBottomRight(find.byKey(ValueKey('course-card-${spanIdentity(spans.last)}'))).dy, lessThanOrEqualTo(540 - 100));
    expect(tester.widget<ScrollEdgeFade>(find.byType(ScrollEdgeFade)).top, 24);
    expect(tester.takeException(), isNull);
  });

  testWidgets('高对比度下不渐隐内容', (tester) async {
    await tester.pumpWidget(MaterialApp(home: MediaQuery(data: const MediaQueryData(highContrast: true), child: ScrollEdgeFade(top: 24, bottom: 100, child: const SizedBox.expand()))));
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('四张课程卡默认字号完整容纳首屏，空课也显示对应时间', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final spans = periodSpans([course(3, 4, name: '高等数学'), course(5, 6, name: '大学英语'), course(7, 8, name: '大学物理')]);
    await tester.pumpWidget(app(CourseDayCards(spans: spans, bells: bells, date: '2026-09-21')));
    await tester.pumpAndSettle();
    final heights = <double>[];
    for (final span in spans) {
      final card = find.byKey(ValueKey('course-card-${spanIdentity(span)}'));
      expect(tester.getBottomRight(card).dy, lessThanOrEqualTo(540));
      heights.add(tester.getSize(card).height);
    }
    expect(heights.toSet(), hasLength(1));
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.maxScrollExtent, 0);
    expect(find.text('08:00–09:40'), findsOneWidget);
    expect(tester.getTopLeft(find.text('第1–2节')).dy, lessThan(tester.getTopLeft(find.text('08:00–09:40')).dy));
    expect(find.text('作息时间未设置'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('已选今天只滑远日期栏，重复点击今天仍强制回位；减弱动画同样有效', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var request = 0;
    var reduceMotion = false;
    late StateSetter update;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
      update = setState;
      return MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion), child: Column(children: [
        TextButton(onPressed: () => setState(() => request++), child: const Text('今天')),
        DateRail(first: '2026-09-01', last: '2026-12-31', selected: '2026-09-24', recenterRequest: request, onSelect: (_) {}),
      ]));
    })));
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('date-rail'));
    for (final reduced in [false, true]) {
      update(() => reduceMotion = reduced);
      await tester.pumpAndSettle();
      await tester.drag(rail, const Offset(-1500, 0));
      await tester.pumpAndSettle();
      expect(find.text('9/24').hitTestable(), findsNothing);
      await tester.tap(find.text('今天'));
      await tester.pumpAndSettle();
      expect(find.text('9/24').hitTestable(), findsOneWidget);
      expect(tester.getCenter(find.text('9/24')).dx, closeTo(190, 1));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('底栏拖动预览不切页，松手只提交一次', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(app(Align(alignment: Alignment.bottomCenter, child: DragNavigationBar(selected: 0, onSelected: changes.add))));
    final start = tester.getCenter(find.text('今天'));
    final end = tester.getCenter(find.text('我的'));
    final gesture = await tester.startGesture(start);
    await gesture.moveTo(end);
    await tester.pump(const Duration(milliseconds: 100));
    expect(changes, isEmpty);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, [3]);
  });

  testWidgets('日期栏可横滑，浏览不改变课程日期，点击才选择', (tester) async {
    final selected = <String>[];
    await tester.pumpWidget(app(Align(alignment: Alignment.topCenter, child: DateRail(first: '2026-09-01', last: '2026-12-31', selected: '2026-09-01', onSelect: selected.add))));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('date-rail')), const Offset(-420, 0));
    await tester.pumpAndSettle();
    expect(selected, isEmpty);
    final visible = find.byType(InkWell).hitTestable().first;
    await tester.tap(visible);
    expect(selected, hasLength(1));
    expect(selected.single, isNot('2026-09-01'));
  });

  testWidgets('底栏拖出边界正常松手，提交横坐标最近模块', (tester) async {
    final changes = <int>[];
    await tester.pumpWidget(app(Align(alignment: Alignment.bottomCenter, child: DragNavigationBar(selected: 0, onSelected: changes.add))));
    final gesture = await tester.startGesture(tester.getCenter(find.text('今天')));
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.moveTo(const Offset(400, 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(changes, [2]);
  });

  testWidgets('无课标题与指定文案居中且大字号仍可读', (tester) async {
    await tester.pumpWidget(app(const CourseDayCards(spans: [], bells: [], date: '2026-09-24')));
    final title = find.text('这天没课');
    expect(tester.getCenter(title).dx, closeTo(400, 1));
    expect(find.text('是放假了还是?反正今天一定很爽啦!'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('12月选周不触发中间月份，日期栏节点高度稳定', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(SchedulePage(gateway: gateway)));
    await tester.pumpAndSettle();
    final rail = find.byKey(const ValueKey('date-rail'));
    final element = tester.element(rail);
    final height = tester.getSize(rail).height;
    await tester.tap(find.text('学期'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('12月'));
    await tester.pumpAndSettle();
    final week = find.text('第15周\n12/7');
    await tester.ensureVisible(week);
    await tester.tap(week);
    for (var index = 0; index < 5; index++) {
      await tester.pump(const Duration(milliseconds: 60));
      expect(identical(tester.element(rail), element), isTrue);
      expect(tester.getSize(rail).height, height);
      expect(find.text('第11周\n11/9'), findsNothing);
    }
    expect(find.textContaining('课程'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('开学日初始保存值，取消不改，保存显示成功', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(Builder(builder: (context) => TextButton(onPressed: () => editTermStart(context, gateway, term, '2026-08-31'), child: const Text('编辑')))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final picker = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(picker.initialDate, DateTime(2026, 8, 31));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.savedStart, '2026-08-31');
    expect(find.text('开学日已保存'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('字号设置关闭重开仍保留', () async {
    sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('display-setting-');
    final path = '${dir.path}/display.db';
    var settings = await DisplaySettings.open(databasePath: path);
    await settings.setScale(1.25); await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.scale, 1.25);
    await settings.close(); await dir.delete(recursive: true);
  });
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  String? savedStart;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: [term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: '2026-08-31', courses: [course(3, 4)]));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: false, message: '', term: term, periods: bells));
  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) async { savedStart = date; return GatewayResult(ok: true, source: 'user', fetchedAt: 'stamp', data: term); }
}

// 每天第3–4节有课，任何运行日期都有第1–2节无课卡。
class _EveryDayGateway extends _Gateway {
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: '2026-08-31', courses: [
    CourseRecord(courseCode: 'C3', courseName: '课程', sectionId: 'S3', credit: 1, teacherName: '老师', meetings: [
      for (var weekday = 1; weekday <= 7; weekday++) CourseMeeting(weekday: weekday, periodStart: 3, periodEnd: 4, place: '教室', weeks: [for (var week = 1; week <= 18; week++) week]),
    ]),
  ]));
}
