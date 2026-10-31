import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/edu/parse_schedule.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/date_rail.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/term_start_dialog.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/dot_separated_text.dart';

import 'fixture_campus_gateway.dart';

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

  test('此刻只对今天：上课中与课间的进度和剩余时长，秒向上取整，时长按小时分钟', () {
    final spans = periodSpans([course(1, 2), course(3, 4)]);
    final first = spanIdentity(spans.first), second = spanIdentity(spans.last);
    // 08:44:30 第1–2节上课中（08:00–09:40）。
    final during = classMoment(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 24, 0, 44, 30));
    expect(during.ongoing, isTrue);
    expect(during.focus!.start, 1);
    expect(during.remainingMinutes, 56);
    expect(during.fraction, closeTo(2670 / 6000, 1e-9));
    expect(during.progress[first], closeTo(2670 / 6000, 1e-9));
    expect(during.progress.containsKey(second), isFalse);
    expect((during.fromLabel, during.targetLabel), ('08:00', '09:40'));
    // 09:40 第一节刚下课：课间从上一节下课画到下一节上课。
    final gap = classMoment(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 24, 1, 40));
    expect(gap.ongoing, isFalse);
    expect(gap.focus!.start, 3);
    expect(gap.remainingMinutes, 20);
    expect(gap.fraction, 0);
    expect(gap.progress[first], 1);
    expect((gap.fromLabel, gap.targetLabel), ('09:40', '10:00'));
    // 06:50 第一节课前没有起点，只给剩余时长。
    final early = classMoment(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 23, 22, 50));
    expect(early.focus!.start, 1);
    expect(classDuration(early.remainingMinutes), '1小时10分');
    expect(early.fraction, isNull);
    expect(early.progress, isEmpty);
    final over = classMoment(spans, bells, '2026-09-24', DateTime.utc(2026, 9, 24, 4));
    expect(over.focus, isNull);
    expect(over.progress.values, [1, 1]);
    expect(classMoment(spans, bells, '2026-09-23', DateTime.utc(2026, 9, 24)).focus, isNull);
    expect(classMoment(spans, bells, '2026-09-23', DateTime.utc(2026, 9, 24)).progress, isEmpty);
    expect(classMoment(spans, [], '2026-09-24', DateTime.utc(2026, 9, 24)).focus, isNull);
    expect([1, 45, 60, 65, 125].map(classDuration), ['1分钟', '45分钟', '1小时', '1小时05分', '2小时05分']);
  });

  // 虚线拼成一条路径一次画完：Impeller 没有栅格缓存，逐段画每帧都要多次提交（10-27 iPhone 日志里滑动卡顿）。
  testWidgets('空档的虚线框与虚线竖条每个只画一次', (tester) async {
    await tester.pumpWidget(app(CourseDayCards(spans: periodSpans([course(3, 4)]), bells: bells, date: '2026-09-21')));
    await tester.pumpAndSettle();
    final painters = [
      for (final paint in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
        if (paint.painter case final painter? when ['_GapBackdropPainter', '_DashPainter'].contains(painter.runtimeType.toString())) painter,
    ];
    expect(painters.map((painter) => painter.runtimeType.toString()).toSet(), {'_GapBackdropPainter', '_DashPainter'});
    for (final painter in painters) {
      final canvas = _CountingCanvas();
      painter.paint(canvas, const Size(343, 120));
      expect([canvas.paths, canvas.lines], [1, 0], reason: '${painter.runtimeType}');
    }
  });

  testWidgets('空档与正课同宽（触区不低于48、比正课矮），大字不溢出，详情可点空白关闭', (tester) async {
    final spans = periodSpans([course(3, 4)]);
    String? detail;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, update) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.4)), child: CourseDayCards(
      spans: spans, bells: bells, date: '2026-09-21', detailKey: detail, onDetail: (key) => update(() => detail = key),
    )))));
    await tester.pumpAndSettle();
    final empty = find.byKey(ValueKey('course-card-${spanIdentity(spans.first)}'));
    final normal = find.byKey(ValueKey('course-card-${spanIdentity(spans.last)}'));
    expect(tester.getSize(empty).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(empty).height, lessThan(tester.getSize(normal).height));
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

  testWidgets('空档按时长加高：3小时40分的空当比1小时40分高，时刻列上开始下结束、标题写时长', (tester) async {
    Future<double> gapHeight(List<PeriodSpan> spans) async {
      await tester.pumpWidget(app(CourseDayCards(key: UniqueKey(), spans: spans, bells: bells, date: '2026-09-21')));
      await tester.pumpAndSettle();
      return tester.getSize(find.byKey(ValueKey('course-card-${spanIdentity(spans.first)}'))).height;
    }
    final short = await gapHeight(periodSpans([course(3, 4)]));
    expect(find.text('早八没课哦~'), findsOneWidget);
    expect(tester.getTopLeft(find.text('08:00')).dy, lessThan(tester.getTopLeft(find.text('09:40')).dy));
    final long = await gapHeight([const PeriodSpan(start: 1, end: 4), ...periodSpans([course(5, 6)]).where((span) => !span.empty)]);
    expect(find.text('3小时40分 · 第1–4节'), findsOneWidget);
    expect(long, greaterThan(short));
    expect(tester.takeException(), isNull);
  });
  testWidgets('空档标题窄处只在「没课」与时长之间折行，时长不拆开，读屏读整句', (tester) async {
    await tester.pumpWidget(app(Center(child: SizedBox(width: 270, height: 800, child: CourseDayCards(spans: periodSpans([course(1, 2), course(5, 6)]), bells: bells, date: '2026-09-21')))));
    await tester.pumpAndSettle();
    expect(find.text('1小时40分'), findsOneWidget);
    expect(tester.getTopLeft(find.text('1小时40分')).dx, tester.getTopLeft(find.text('没课 ')).dx);
    expect(tester.getTopLeft(find.text('1小时40分')).dy, greaterThan(tester.getTopLeft(find.text('没课 ')).dy));
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '没课 1小时40分'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('说明行按“ · ”分项、学期名在“学年”后切开，读屏读整句', (tester) async {
    await tester.pumpWidget(app(const DotSeparatedText('完成 · 课表 · 2026-2027学年第一学期', style: TextStyle(fontSize: 14))));
    expect(tester.widgetList<Text>(find.byType(Text)).map((text) => text.data), ['完成\u00A0· ', '课表\u00A0· ', '2026-2027学年', '第一学期']);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '完成 · 课表 · 2026-2027学年第一学期'), findsOneWidget);
  });

  testWidgets('传入 onOpen 时单击有课卡回调该课，空档单击不回调；已下课整卡淡化', (tester) async {
    final spans = periodSpans([course(1, 2, name: '早课'), course(3, 4)]);
    final opened = <PeriodSpan>[];
    // 2026-09-21 周一 09:50（校园时区）：第1–2节已下课，第3–4节没开始。
    // 用固定时钟：真实 LiveClock 的整分计时器赶上 pumpAndSettle 时会把时间改回今天，曾在 CI 上偶发失败。
    final clock = ValueNotifier(DateTime.utc(2026, 9, 21, 1, 50));
    addTearDown(clock.dispose);
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-21', onOpen: opened.add))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('课程'));
    expect(opened.map((span) => span.course!.courseName), ['课程']);
    double opacityOf(String name) => tester.widget<AnimatedOpacity>(find.ancestor(of: find.text(name), matching: find.byType(AnimatedOpacity)).first).opacity;
    expect(opacityOf('早课'), .55);
    expect(opacityOf('课程'), 1);
    opened.clear();
    await tester.pumpWidget(app(CourseDayCards(spans: periodSpans([course(3, 4)]), bells: bells, date: '2026-09-21', onOpen: opened.add)));
    await tester.tap(find.text('早八没课哦~'));
    expect(opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('教室单独一行带定位图标；时刻列开始前上课时刻大、开始后下课时刻大，切换有过渡；不是今天上课时刻大', (tester) async {
    final spans = periodSpans([course(1, 2, name: '早课'), course(3, 4)]);
    // 2026-09-21 周一 09:50（校园时区）：第1–2节已下课，第3–4节没开始。
    final clock = ValueNotifier(DateTime.utc(2026, 9, 21, 1, 50));
    addTearDown(clock.dispose);
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-21'))));
    await tester.pumpAndSettle();
    double? sizeOf(String label) => tester.renderObject<RenderParagraph>(find.text(label)).text.style!.fontSize;
    expect(find.byIcon(CampusIcons.place), findsNWidgets(2));
    expect(tester.widget<Text>(find.text('教室').first).style!.fontSize, 16);
    expect((sizeOf('08:00'), sizeOf('09:40')), (14, 20));
    expect((sizeOf('10:00'), sizeOf('11:40')), (20, 14));
    // 10:00 开课：下课时刻放大，中途是过渡值，不是一步跳变。
    clock.value = DateTime.utc(2026, 9, 21, 2);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(sizeOf('11:40'), allOf(greaterThan(14), lessThan(20)));
    await tester.pumpAndSettle();
    expect((sizeOf('10:00'), sizeOf('11:40')), (14, 20));
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-22'))));
    await tester.pumpAndSettle();
    expect((sizeOf('08:00'), sizeOf('09:40')), (20, 14));
    expect(tester.takeException(), isNull);
  });

  testWidgets('刚开课（进度为 0）的卡片照常显示，不因竖条固有高度布局失败', (tester) async {
    final clock = ValueNotifier(DateTime.utc(2026, 9, 21, 2));
    addTearDown(clock.dispose);
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: periodSpans([course(3, 4)]), bells: bells, date: '2026-09-21'))));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text('课程')).height, greaterThan(0));
  });

  testWidgets('今天页有课卡按下有反馈、读屏整卡一句并标为按钮；课表页不变', (tester) async {
    final spans = periodSpans([course(1, 2, name: '早课'), course(3, 4)]);
    final opened = <PeriodSpan>[];
    // 10:20：第1–2节已下课，第3–4节上课中已过 20%。
    final clock = ValueNotifier(DateTime.utc(2026, 9, 21, 2, 20));
    addTearDown(clock.dispose);
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-21', onOpen: opened.add))));
    await tester.pumpAndSettle();
    Finder card(String label) => find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == label && widget.properties.button == true);
    expect(card('早课，教室，08:00到09:40，第1–2节，老师，已下课'), findsOneWidget);
    expect(card('课程，教室，10:00到11:40，第3–4节，老师，上课中，已过20%'), findsOneWidget);
    tester.widget<Semantics>(card('早课，教室，08:00到09:40，第1–2节，老师，已下课')).properties.onTap!();
    expect(opened.single.course!.courseName, '早课');
    expect(find.descendant(of: find.byKey(ValueKey('course-card-${spanIdentity(spans.first)}')), matching: find.byType(InkWell)), findsOneWidget);
    // 课表页不传 onOpen：仍只认长按，不加按压反馈与按钮语义。
    await tester.pumpWidget(app(LiveClock.fixed(clock, child: CourseDayCards(spans: spans, bells: bells, date: '2026-09-21'))));
    await tester.pumpAndSettle();
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.button == true && (widget.properties.label ?? '').startsWith('早课')), findsNothing);
    expect(find.descendant(of: find.byKey(ValueKey('course-card-${spanIdentity(spans.first)}')), matching: find.byType(InkWell)), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('打开今天时正在上的课在可见区外就首帧停在它的上沿；放得下或不是今天页不动', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const evening = [
      ...bells,
      BellPeriod(period: 5, dayPart: '', dayPartCode: '', start: '14:00', end: '14:45'), BellPeriod(period: 6, dayPart: '', dayPartCode: '', start: '14:55', end: '15:40'),
      BellPeriod(period: 7, dayPart: '', dayPartCode: '', start: '16:00', end: '16:45'), BellPeriod(period: 8, dayPart: '', dayPartCode: '', start: '16:55', end: '17:40'),
      BellPeriod(period: 9, dayPart: '', dayPartCode: '', start: '19:00', end: '19:45'), BellPeriod(period: 10, dayPart: '', dayPartCode: '', start: '19:55', end: '20:40'),
    ];
    final spans = periodSpans([for (var start = 1; start <= 9; start += 2) course(start, start + 1, name: '课程$start')]);
    final focus = find.byKey(ValueKey('course-card-${spanIdentity(spans[3])}'));
    // 16:20：第7–8节上课中，排在第四张，540 高的屏放不下。
    final clock = ValueNotifier(DateTime.utc(2026, 9, 21, 8, 20));
    addTearDown(clock.dispose);
    Widget cards({bool revealNow = true, List<PeriodSpan>? list}) => app(LiveClock.fixed(clock, child: CourseDayCards(spans: list ?? spans, bells: evening, date: '2026-09-21', obscuredBottom: 100, revealNow: revealNow)));
    double offset() => tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    await tester.pumpWidget(cards());
    final opening = offset();
    expect(opening, greaterThan(0));
    expect(tester.getTopLeft(focus).dy, greaterThanOrEqualTo(0));
    expect(tester.getBottomRight(focus).dy, lessThanOrEqualTo(540 - 100));
    await tester.pumpAndSettle();
    expect(offset(), opening);
    // 课表页（不传 revealNow）照旧从顶部开始，这节课压在遮挡区里。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(cards(revealNow: false));
    expect(offset(), 0);
    expect(tester.getBottomRight(focus).dy, greaterThan(540 - 100));
    // 放得下时不动。
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(cards(list: spans.take(2).toList()));
    expect(offset(), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('读屏：日期栏每项可点；课表页有课卡读整句、长按展开，展开后编辑入口单独可达', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(app(Align(alignment: Alignment.topCenter, child: DateRail(first: '2026-09-01', last: '2026-12-31', selected: '2026-09-01', onSelect: picked.add))));
    await tester.pumpAndSettle();
    final day = find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '2026-09-02 周三');
    tester.widget<Semantics>(day).properties.onTap!();
    expect(picked, ['2026-09-02']);
    final spans = periodSpans([course(3, 4)]);
    final occupied = spans.firstWhere((span) => !span.empty);
    String? detail;
    await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) => CourseDayCards(spans: spans, bells: bells, date: '2026-09-22', detailKey: detail, onDetail: (key) => setState(() => detail = key), onEdit: (_) {}))));
    await tester.pumpAndSettle();
    final sentence = find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '课程，教室，10:00到11:40，第3–4节，老师');
    expect(tester.widget<Semantics>(sentence).properties.hintOverrides?.onLongPressHint, '展开详情');
    tester.widget<Semantics>(sentence).properties.onLongPress!();
    await tester.pumpAndSettle();
    expect(detail, spanIdentity(occupied));
    expect(sentence, findsNothing);
    expect(find.text('编辑课程'), findsOneWidget);
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
    // 预填的本周时段带上这门课的老师（时段卡整卡是一个按钮，读屏读整句）。
    final slot = find.bySemanticsLabel('周${weekdayLabel(weekdayOf(date))} 第1–2节 · 第${weekIndex('2026-08-31', date)}周 · 老师');
    await tester.scrollUntilVisible(slot, 200, scrollable: find.byType(Scrollable).first);
    expect(slot, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表顶栏在窄屏特大字号下不溢出：今天胶囊与两个玻璃圆按钮都在屏内', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final font in ['Maple Mono NF CN', 'Noto Serif SC']) {
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(font),
        theme: campusTheme(fontFamily: font),
        locale: const Locale('zh', 'CN'), supportedLocales: const [Locale('zh', 'CN')], localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: MediaQuery(data: const MediaQueryData(size: Size(360, 700), textScaler: TextScaler.linear(1.4)), child: Scaffold(body: SchedulePage(gateway: _EveryDayGateway()))),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: font);
      for (final target in [find.widgetWithText(TextButton, '今天'), find.byTooltip('管理课程'), find.byTooltip('更多操作')]) {
        final rect = tester.getRect(target);
        expect(rect.left, greaterThanOrEqualTo(0), reason: font);
        expect(rect.right, lessThanOrEqualTo(360), reason: font);
      }
    }
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

  testWidgets('三门课加空档默认字号完整容纳首屏，有课卡等高，空档一行也显示对应时间', (tester) async {
    await tester.binding.setSurfaceSize(const Size(380, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final spans = periodSpans([course(3, 4, name: '高等数学'), course(5, 6, name: '大学英语'), course(7, 8, name: '大学物理')]);
    await tester.pumpWidget(app(CourseDayCards(spans: spans, bells: bells, date: '2026-09-21')));
    await tester.pumpAndSettle();
    final heights = <double>[];
    for (final span in spans) {
      final card = find.byKey(ValueKey('course-card-${spanIdentity(span)}'));
      expect(tester.getBottomRight(card).dy, lessThanOrEqualTo(540));
      if (!span.empty) heights.add(tester.getSize(card).height);
    }
    expect(heights.toSet(), hasLength(1));
    final position = tester.state<ScrollableState>(find.byType(Scrollable)).position;
    expect(position.maxScrollExtent, 0);
    // 有课卡左列开始、结束时刻，右列课名、教室与节次；缺作息的节次在同一行注明。
    expect(find.text('10:00'), findsOneWidget);
    expect(tester.getTopLeft(find.text('10:00')).dx, lessThan(tester.getTopLeft(find.textContaining('第3–4节')).dx));
    // 空档沿用卡片三列网格：开始时刻与卡片时刻列左对齐，内容与课名同起点，写空闲时长与节次。
    expect(find.text('1小时40分 · 第1–2节'), findsOneWidget);
    expect(tester.getTopLeft(find.text('08:00')).dx, tester.getTopLeft(find.text('10:00')).dx);
    expect(tester.getTopLeft(find.text('早八没课哦~')).dx, tester.getTopLeft(find.text('高等数学')).dx);
    expect(find.textContaining('作息时间未设置', findRichText: true), findsNWidgets(2));
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

  // 10-31 用户要日期栏上下留白短一点（同课表左侧栏收窄）：高度按两行字量，留白固定，不再随字号放大。
  testWidgets('日期栏高度按两行字量：大字号下日期格上下仍各留 8、外边距 8，不再随字号放大留白', (tester) async {
    for (final scale in [1.0, 1.3, 1.6]) {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      await tester.pumpWidget(app(Align(alignment: Alignment.topCenter, child: DateRail(key: ValueKey(scale), first: '2026-09-01', last: '2026-12-31', selected: '2026-09-01', onSelect: (_) {}))));
      await tester.pumpAndSettle();
      final rail = tester.getRect(find.byKey(const ValueKey('date-rail')));
      final tile = tester.getRect(find.ancestor(of: find.text('9/1'), matching: find.byType(Material)).first);
      final date = tester.getRect(find.text('9/1'));
      final weekday = tester.getRect(find.text('周二').first);
      expect(tile.top - rail.top, closeTo(8, .5), reason: '×$scale 外边距');
      expect(rail.bottom - tile.bottom, closeTo(8, .5), reason: '×$scale 外边距');
      expect(date.top - tile.top, closeTo(8, 1), reason: '×$scale 日期格上沿留白');
      expect(tile.bottom - weekday.bottom, closeTo(8, 1), reason: '×$scale 日期格下沿留白');
      // 格宽也按内容量：测试字体是方块字，以前日期会折成两行、在矮了的格子里溢出。
      expect(tester.takeException(), isNull, reason: '×$scale 不溢出');
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
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

  testWidgets('没课只说一次：没有顶部卡片时居中写“这天没课”，有顶部卡片时中间不再重复', (tester) async {
    await tester.pumpWidget(app(const CourseDayCards(spans: [], bells: [], date: '2026-09-24')));
    final title = find.text('这天没课');
    expect(tester.getCenter(title).dx, closeTo(400, 1));
    expect(find.textContaining('放假'), findsNothing);
    await tester.pumpWidget(app(const CourseDayCards(spans: [], bells: [], date: '2026-09-24', header: Text('顶部卡片'))));
    expect(find.text('顶部卡片'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表页单击有课卡看只读详情、可进编辑；标题写第几周，学期视图展开本月并标出本周', (tester) async {
    await tester.pumpWidget(app(SchedulePage(gateway: _EveryDayGateway())));
    await tester.pumpAndSettle();
    // 所看日期：今天在学期里就是今天，否则是学期第一天（第 1 周）。
    final today = campusToday();
    final inTerm = today.compareTo('2026-08-31') >= 0 && today.compareTo(weekRange('2026-08-31', 18).end) <= 0;
    final week = inTerm ? weekIndex('2026-08-31', today) : 1;
    expect(find.text('第$week周'), findsOneWidget);
    await tester.tap(find.text('课程').first);
    await tester.pumpAndSettle();
    expect(find.text('上课时段'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '编辑课程'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学期'));
    await tester.pumpAndSettle();
    final selected = find.byWidgetPredicate((widget) => widget is Text && (widget.data ?? '').startsWith('第$week周\n'));
    expect(selected, findsOneWidget);
    expect(tester.widget<Text>(selected).data!.endsWith('\n本周'), inTerm);
    // 自动展开的这一层不算钻取：返回键直接离开课表，不先收起它。
    expect(tester.widget<PopScope>(find.byWidgetPredicate((widget) => widget is PopScope).first).canPop, isTrue);
  });

  // 10-31 用户反馈横条是硬切（左侧栏是滑入滑出、展开收起）：三处都要有过渡。窄窗口让学期视图用横条（测试字体是方块字，比真字体宽）。
  testWidgets('学期视图收成横条时同左侧栏一样有过渡：切天与学期时横条展开收起、点月份各周横向展开、选别的周滑过去', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(SchedulePage(gateway: _EveryDayGateway())));
    await tester.pumpAndSettle();
    final pages = find.byType(PageView);
    final dayTop = tester.getTopLeft(pages).dy;
    // 横条里月份格子露在裁剪区里的那一块。天视图里要整个藏住：10-31 用户 iPhone 截图里日期栏下面露出一排格子的顶边
    // （收起后还按 16 高裁，横条上内边距只有 12，格子顶上 4 露在外面）。
    Rect shownTile() => find.ancestor(of: find.text('9月'), matching: find.byType(ClipRect)).evaluate()
        .map((clip) { final box = clip.renderObject! as RenderBox; return box.localToGlobal(Offset.zero) & box.size; })
        .fold(tester.getRect(find.ancestor(of: find.text('9月'), matching: find.byType(Material)).first), (shown, clip) => shown.intersect(clip));
    expect(shownTile().isEmpty, isTrue, reason: '天视图里横条不露出格子');

    // 切到学期：横条从上方展开，课程卡跟着往下移，中间有过渡帧；切回天视图同样收起。
    await tester.tap(find.text('学期'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    final midTop = tester.getTopLeft(pages).dy;
    await tester.pumpAndSettle();
    final termTop = tester.getTopLeft(pages).dy;
    expect(find.textContaining('月'), findsWidgets);
    // 横条打开后所看的那周滑进屏幕（10-31 模拟器上第一次打开时停在开头没滑：天视图里各周收着，格子还没建出来就当成滚过了）。
    final today = campusToday();
    final inTerm = today.compareTo('2026-08-31') >= 0 && today.compareTo(weekRange('2026-08-31', 18).end) <= 0;
    final selectedWeek = tester.getRect(find.textContaining(RegExp('^第${inTerm ? weekIndex('2026-08-31', today) : 1}周 ')));
    expect(selectedWeek.left, greaterThanOrEqualTo(0));
    expect(selectedWeek.right, lessThanOrEqualTo(320));
    expect(midTop, greaterThan(dayTop));
    expect(midTop, lessThan(termTop));
    expect(shownTile().height, tester.getSize(find.ancestor(of: find.text('9月'), matching: find.byType(Material)).first).height, reason: '学期视图里格子整个露出');
    await tester.tap(find.text('天'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.getTopLeft(pages).dy, inExclusiveRange(dayTop, termTop));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pages).dy, dayTop);
    expect(shownTile().isEmpty, isTrue, reason: '切回天视图横条整个收起');
    await tester.tap(find.text('学期'));
    await tester.pumpAndSettle();

    // 本月展开着时点右边的 11 月：本月各周收起把 11 月往左挤出屏幕，展开完它滑回屏幕里。
    await tester.ensureVisible(find.text('11月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('11月'));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('11月')).left, greaterThanOrEqualTo(0));

    // 点右边的 12 月、再点回左边的 11 月：两个方向都是新月份的各周横向展开、旧月份的收起，中间帧宽度在 0 与展开后之间
    // （10-31 用户 iPhone 上切月份没过渡：选中月份格子挂的键跟着选中项挪，行里两者之间那段被拆掉重建，一侧的展开或收起直接跳）。
    final strip = find.ancestor(of: find.text('9月'), matching: find.byType(Scrollable)).first;
    // 某个月后面那段各周的宽（收起时为 0）：紧挨在月份格子右边（格子外留 8）的那个 AnimatedSize。
    double weeksWidth(String month) {
      final start = tester.getRect(find.ancestor(of: find.text(month), matching: find.byType(Material)).first).right + 8;
      return find.descendant(of: strip, matching: find.byType(AnimatedSize)).evaluate().map((element) => element.renderObject! as RenderBox)
          .firstWhere((box) => (box.localToGlobal(Offset.zero).dx - start).abs() < .5).size.width;
    }
    Future<void> switchMonth(String from, String to) async {
      await tester.ensureVisible(find.text(to));
      await tester.pumpAndSettle();
      final expanded = weeksWidth(from);
      await tester.tap(find.text(to));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final midFrom = weeksWidth(from), midTo = weeksWidth(to);
      await tester.pumpAndSettle();
      expect(midFrom, inExclusiveRange(0, expanded), reason: '$from 的各周收起有过渡');
      expect(midTo, inExclusiveRange(0, weeksWidth(to)), reason: '$to 的各周展开有过渡');
      // 左边原来展开的月份收起会把点的月份往左挤，展开完它滑回屏幕里。
      expect(tester.getRect(find.text(to)).left, greaterThanOrEqualTo(0));
    }
    await switchMonth('11月', '12月');
    await switchMonth('12月', '11月');

    // 展开着学期中间的 11 月，选它的第一周：横条滑到它居中，中间帧在原位与终点之间（选两头的月份会先碰到滚动边界）。
    final position = tester.state<ScrollableState>(find.ancestor(of: find.text('11月'), matching: find.byType(Scrollable)).first).position;
    final before = position.pixels;
    await tester.tap(find.textContaining(RegExp(r'^第\d+周 11/')).first);
    // 滑动在这一帧画完后开始，滚动动画的计时从下一帧算起。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));
    final midScroll = position.pixels;
    await tester.pumpAndSettle();
    final after = position.pixels;
    expect(after, isNot(before));
    expect(midScroll, inExclusiveRange(math.min(before, after), math.max(before, after)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动画时横条直接换：切学期、点月份、选周都没有过渡，也不报错', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    addTearDown(tester.view.reset);
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(app(SchedulePage(gateway: _EveryDayGateway())));
    await tester.pumpAndSettle();
    final pages = find.byType(PageView);
    await tester.tap(find.text('学期'));
    await tester.pump();
    await tester.pump();
    final termTop = tester.getTopLeft(pages).dy;
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(pages).dy, termTop, reason: '第一帧就到位');
    await tester.ensureVisible(find.text('11月'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('11月'));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^第\d+周 11/')), findsWidgets);
    // 左边本月的各周一下收起，11 月被挤出屏幕，随即跳回可见区（没有滑动过程）。
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(find.text('11月')).left, greaterThanOrEqualTo(0));
    await tester.tap(find.textContaining(RegExp(r'^第\d+周 11/')).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // 10-31：左侧栏的月份展开原来在减少动画时用了时长为 0 的 AnimatedSize，点月份报「RenderAnimatedSize was mutated in its own performLayout」。
  testWidgets('减少动画时左侧栏点月份直接展开收起，不报错', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(app(SchedulePage(gateway: _EveryDayGateway())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('学期'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^第\d+周\n')), findsWidgets, reason: '宽窗口是左侧栏');
    await tester.tap(find.text('9月'));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^第\d+周\n9/')), findsWidgets);
    await tester.tap(find.text('9月'));
    await tester.pump();
    expect(find.textContaining(RegExp(r'^第\d+周\n9/')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没同步的学期原地给「去同步」，带上这一学年', (tester) async {
    String? requested;
    await tester.pumpWidget(app(SchedulePage(gateway: _UnsyncedGateway(), onSync: (year) => requested = year)));
    await tester.pumpAndSettle();
    expect(find.text('这个学期还没有同步'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '去同步'));
    await tester.pumpAndSettle();
    expect(requested, '2026');
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
    // 学期视图一打开就展开所看日期那个月，12 月可能被挤到下面。
    // 月份列滚动时 9 月会滚出去，先把这个滚动区记成具体的控件（查找器是惰性的）。
    final months = find.byWidget(tester.widget(find.ancestor(of: find.text('9月'), matching: find.byType(Scrollable)).first));
    await tester.scrollUntilVisible(find.text('12月'), 80, scrollable: months);
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

  testWidgets('开学日初始保存值，取消不改，保存后提示条写第1周从哪天开始', (tester) async {
    final gateway = _Gateway();
    await tester.pumpWidget(app(Builder(builder: (context) => TextButton(onPressed: () => editTermStart(context, gateway, term, '2026-08-31'), child: const Text('编辑')))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    final picker = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
    expect(picker.initialDate, DateTime(2026, 8, 31));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(gateway.savedStart, '2026-08-31');
    // 成功只出提示条、不弹要点“知道了”的弹窗，也不再附周次算法的长说明。
    expect(find.text('开学日已保存 · 第1周从 8月31日 开始'), findsOneWidget);
    expect(find.text('知道了'), findsNothing);
    expect(find.textContaining('所在周的周一'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // iOS 上开学日用系统日期选择（theme/native_glass.dart 的 showNativeDatePicker）：交给原生的是保存值与校园时区，取消不改，原生回的日期照样保存。
  testWidgets('iOS 开学日用系统日期选择，取消不改，选好照样保存', (tester) async {
    const nativeUi = MethodChannel('superxd/native_ui');
    final messenger = tester.binding.defaultBinaryMessenger;
    final dates = <Object?>[];
    String? reply;
    messenger.setMockMethodCallHandler(nativeUi, (call) async {
      if (call.method != 'date') return null;
      dates.add(call.arguments);
      return reply;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async => null);
    addTearDown(() {
      messenger.setMockMethodCallHandler(nativeUi, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
    final gateway = _Gateway();
    await tester.pumpWidget(app(Builder(builder: (context) => TextButton(onPressed: () => editTermStart(context, gateway, term, '2026-08-31'), child: const Text('编辑')))));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(dates.single, {'title': '选择开学日', 'confirm': '保存', 'initial': '2026-08-31', 'first': '2000-01-01', 'last': '2100-01-01', 'timeZone': campusTimeZone});
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(gateway.savedStart, isNull);
    reply = '2026-09-07';
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(gateway.savedStart, '2026-09-07');
    expect(find.text('开学日已保存 · 第1周从 9月7日 开始'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  test('字号设置关闭重开仍保留', () async {
    sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('display-setting-');
    final path = '${dir.path}/display.db';
    var settings = await DisplaySettings.open(databasePath: path);
    await settings.setTextSize(1.25); await settings.close();
    settings = await DisplaySettings.open(databasePath: path);
    expect(settings.textSize, 1.25);
    await settings.close(); await dir.delete(recursive: true);
  });
}

class _Gateway extends FixtureCampusGateway {
  _Gateway() : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  String? savedStart;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => const GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: [term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: '2026-08-31', revisionId: 'rev-test', courses: [course(3, 4)]));
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: BellsView(empty: false, message: '', term: term, periods: bells));
  @override
  Future<GatewayResult<TermRef>> setTermStart(TermRef term, String date) async { savedStart = date; return GatewayResult(ok: true, source: 'user', fetchedAt: 'stamp', data: term); }
}

// 学期列表里有，但还没同步过课表（没有版本）。
class _UnsyncedGateway extends _Gateway {
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: term, student: const SessionView(loginId: 'test', name: '', className: ''), courses: const []));
}

// 每天第3–4节有课，任何运行日期都有第1–2节无课卡。
class _EveryDayGateway extends _Gateway {
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async => GatewayResult(ok: true, source: 'local', fetchedAt: 'stamp', data: ScheduleView(term: term, student: const SessionView(loginId: 'test', name: '', className: ''), termStartDate: '2026-08-31', revisionId: 'rev-test', courses: [
    CourseRecord(courseCode: 'C3', courseName: '课程', sectionId: 'S3', credit: 1, teacherName: '老师', meetings: [
      for (var weekday = 1; weekday <= 7; weekday++) CourseMeeting(weekday: weekday, periodStart: 3, periodEnd: 4, place: '教室', weeks: [for (var week = 1; week <= 18; week++) week]),
    ]),
  ]));
}

class _CountingCanvas implements Canvas {
  int paths = 0, lines = 0;
  @override
  void drawPath(Path path, Paint paint) => paths++;
  @override
  void drawLine(Offset p1, Offset p2, Paint paint) => lines++;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
