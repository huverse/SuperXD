import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_theme.dart';

import 'fixture_campus_gateway.dart';

const _term = TermRef(xn: '2026', xq: '0');
const _student = SessionView(loginId: 'fixture', name: '', className: '');
final _initial = DateTime.utc(2026, 9, 25, 4);
GatewayResult<T> _ok<T>(T data) =>
    GatewayResult(ok: true, source: 'local', fetchedAt: 'fixture', data: data);

class _Gateway extends FixtureCampusGateway {
  _Gateway({
    this.empty = false,
    this.start = '2026-09-01',
    this.weeks = 8,
    this.periods = 8,
  }) : super(readText: (name) => File('assets/fixtures/$name').readAsString());
  final bool empty;
  String? start;
  final int weeks;
  final int periods;
  bool known = true;
  bool failed = false;
  int? emptyWeekday;
  Set<int> emptyWeekdays = {};
  int reads = 0;
  int network = 0;
  Completer<GatewayResult<ScheduleView>>? pending;
  @override
  Future<GatewayResult<List<TermRef>>> listTerms() async => _ok([_term]);
  @override
  Future<GatewayResult<ScheduleView>> readSchedule(ScheduleScope scope) async {
    reads++;
    if (scope.kind != 'term') throw StateError('翻日不应逐日读库');
    final delayed = pending;
    if (delayed != null) {
      pending = null;
      return delayed.future;
    }
    if (failed) {
      return const GatewayResult(
        ok: false,
        source: 'local',
        fetchedAt: '',
        error: GatewayError(code: 'READ_FAILED', message: '读取失败'),
      );
    }
    return result();
  }

  GatewayResult<ScheduleView> result() => _ok(
    ScheduleView(
      term: _term,
      student: _student,
      termStartDate: start,
      message: known ? '' : '还没有课表',
      revisionId: known ? 'rev-test' : null,
      courses: [
        if (!empty && known)
          for (var weekday = 1; weekday <= 7; weekday++)
            if (weekday != emptyWeekday && !emptyWeekdays.contains(weekday))
              CourseRecord(
                courseCode: 'C$weekday',
                courseName: '星期$weekday的课',
                sectionId: 'S$weekday',
                credit: 1,
                teacherName: '老师',
                meetings: [
                  CourseMeeting(
                    weekday: weekday,
                    periodStart: 1,
                    periodEnd: 2,
                    place: '教室',
                    weeks: List.generate(weeks, (index) => index + 1),
                  ),
                  if (periods > 8)
                    CourseMeeting(
                      weekday: weekday,
                      periodStart: periods - 1,
                      periodEnd: periods,
                      place: '晚课教室',
                      weeks: List.generate(weeks, (index) => index + 1),
                    ),
                ],
              ),
      ],
    ),
  );
  @override
  Future<GatewayResult<BellsView>> readBells(TermRef term) async => _ok(
    BellsView(
      empty: false,
      message: '',
      term: term,
      periods: [
        for (var period = 1; period <= periods; period++)
          BellPeriod(
            period: period,
            dayPart: '',
            dayPartCode: period <= 4
                ? 'morning'
                : period <= 8
                ? 'afternoon'
                : 'evening',
            start: '${7 + period}:00',
            end: '${7 + period}:45',
          ),
      ],
    ),
  );
  @override
  Future<GatewayResult<List<TermRef>>> syncTerms() async {
    network++;
    return listTerms();
  }

  @override
  Future<GatewayResult<ScheduleView>> syncSchedule(TermRef term) async {
    network++;
    return result();
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Gateway gateway, {
  DateTime Function()? now,
  bool reduced = false,
  double scale = 1,
  Size size = const Size(390, 850),
  ValueNotifier<bool>? active,
  double bottomPadding = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final page = TodayPage(gateway: gateway, now: now ?? () => _initial);
  await tester.pumpWidget(
    MaterialApp(
      theme: campusTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: EdgeInsets.only(bottom: bottomPadding),
          textScaler: TextScaler.linear(scale),
          disableAnimations: reduced,
        ),
        child: Scaffold(
          body: active == null
              ? page
              : ValueListenableBuilder(
                  valueListenable: active,
                  builder: (context, enabled, child) =>
                      TickerMode(enabled: enabled, child: child!),
                  child: page,
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _date(String value) => find.byKey(ValueKey('today-date-$value'));
Finder _frame(String value) => find.byKey(ValueKey('today-frame-$value'));
double _offset(WidgetTester tester, String value) => tester.widget<Transform>(find.byKey(ValueKey('today-offset-$value'))).transform.getTranslation().y;
Future<void> _swipeDate(
  WidgetTester tester,
  String date,
  double distance, {
  bool settle = true,
}) async {
  // 多次 move 模拟真正拖动，第一段由手势识别消耗触摸阈值。
  final gesture = await tester.startGesture(tester.getCenter(_date(date)));
  await gesture.moveBy(Offset(0, -distance.sign * 24));
  await tester.pump();
  await gesture.moveBy(Offset(0, -distance));
  await tester.pump(const Duration(milliseconds: 16));
  await gesture.up();
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets('上滑明天下滑昨天，日期课程同步渐变，回今天且翻日不读库联网', (tester) async {
    final gateway = _Gateway();
    await _mount(tester, gateway);
    expect(_date('2026-09-25'), findsOneWidget);
    final reads = gateway.reads;
    await _swipeDate(tester, '2026-09-25', 100, settle: false);
    await tester.pump(const Duration(milliseconds: 32));
    expect(
      find.byKey(const ValueKey('today-frame-2026-09-25')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('today-frame-2026-09-26')),
      findsOneWidget,
    );
    for (final key in ['today-frame-2026-09-25', 'today-frame-2026-09-26', 'today-header-2026-09-25', 'today-header-2026-09-26']) {
      final fade = tester.widget<FadeTransition>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(FadeTransition)).first);
      expect(fade.opacity.value, inInclusiveRange(0, 1));
    }
    expect(_offset(tester, '2026-09-25'), lessThan(0));
    expect(_offset(tester, '2026-09-26'), greaterThan(0));
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
    expect(find.text('星期6的课'), findsOneWidget);
    expect(find.textContaining('下一节'), findsNothing);
    expect(find.textContaining('后上课'), findsNothing);
    // 回今天是底栏上方水平居中的胶囊，箭头指向今天所在方向；日期下注明相对天数。
    final width = tester.getSize(find.byType(TodayPage)).width;
    expect(tester.getCenter(find.byKey(const ValueKey('today-reset'))).dx, closeTo(width / 2, 1));
    expect(find.text('明天'), findsOneWidget);
    expect(tester.widget<AnimatedRotation>(find.descendant(of: find.byKey(const ValueKey('today-reset')), matching: find.byType(AnimatedRotation))).turns, 0);
    await _swipeDate(tester, '2026-09-26', 100);
    expect(_date('2026-09-27'), findsOneWidget);
    expect(find.text('后天'), findsOneWidget);
    await _swipeDate(tester, '2026-09-27', -100);
    expect(_date('2026-09-26'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pumpAndSettle();
    await _swipeDate(tester, '2026-09-25', -100);
    await _swipeDate(tester, '2026-09-24', -100);
    await _swipeDate(tester, '2026-09-23', -100);
    expect(find.text('3天前'), findsOneWidget);
    expect(tester.widget<AnimatedRotation>(find.descendant(of: find.byKey(const ValueKey('today-reset')), matching: find.byType(AnimatedRotation))).turns, .5);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    expect(gateway.reads, reads);
    expect(gateway.network, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('连续快速切日和反向最多两帧，回今天覆盖待达目标', (tester) async {
    await _mount(tester, _Gateway());
    await _swipeDate(tester, '2026-09-25', 100, settle: false);
    await tester.pump(const Duration(milliseconds: 60));
    for (var index = 0; index < 3; index++) {
      await _swipeDate(tester, '2026-09-26', 100, settle: false);
      await tester.pump(const Duration(milliseconds: 24));
      expect(
        find.byType(CourseDayCards).evaluate().length,
        lessThanOrEqualTo(2),
      );
    }
    await _swipeDate(tester, '2026-09-26', -100, settle: false);
    await tester.pumpAndSettle();
    expect(_date('2026-09-28'), findsOneWidget);
    await _swipeDate(tester, '2026-09-28', 100, settle: false);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byKey(const ValueKey('today-reset')).hitTestable());
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未达阈值、取消和水平滑动都不切日', (tester) async {
    await _mount(tester, _Gateway());
    await _swipeDate(tester, '2026-09-25', 20);
    expect(_date('2026-09-25'), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(_date('2026-09-25')),
    );
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    await tester.drag(_date('2026-09-25'), const Offset(130, 0));
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
  });

  testWidgets('顶下拉前一天，长列表中间滚动和惯性不切日，底上推下一天', (tester) async {
    // 空档合成一行后内容变短，放大字号仍构成需要滚动的长列表。
    await _mount(tester, _Gateway(periods: 12), size: const Size(390, 670), scale: 1.6);
    Finder list() => find.descendant(
      of: find.byType(CourseDayCards),
      matching: find.byType(ListView),
    );
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: list(), matching: find.byType(Scrollable)),
        )
        .position;
    await tester.drag(list(), const Offset(0, -170));
    await tester.pumpAndSettle();
    expect(position().pixels, greaterThan(0));
    expect(_date('2026-09-25'), findsOneWidget);
    await tester.fling(list(), const Offset(0, -100), 4000);
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    position().jumpTo(position().maxScrollExtent);
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(list()));
    await gesture.moveBy(const Offset(0, -24));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pumpAndSettle();
    expect(position().pixels, 0);
    final down = await tester.startGesture(tester.getCenter(list()));
    await down.moveBy(const Offset(0, 24));
    await down.moveBy(const Offset(0, 100));
    await tester.pump();
    await down.up();
    await tester.pumpAndSettle();
    expect(_date('2026-09-24'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短列表和空日直接切换，课程区拖动取消不提交', (tester) async {
    await _mount(
      tester,
      _Gateway()..emptyWeekday = 6,
      size: const Size(600, 1000),
    );
    final list = find.descendant(
      of: find.byType(CourseDayCards),
      matching: find.byType(ListView),
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    expect(scroll.maxScrollExtent, 0);
    var gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -24));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    gesture = await tester.startGesture(tester.getCenter(list));
    await gesture.moveBy(const Offset(0, -24));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
    expect(find.text('这天没课'), findsOneWidget);
    gesture = await tester.startGesture(tester.getCenter(find.text('这天没课')));
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
  });

  testWidgets('局部刷新保留日期，范围变化不静默归位', (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final gateway = _Gateway();
    await _mount(tester, gateway, active: active);
    await _swipeDate(tester, '2026-09-25', 100);
    gateway.start = '2026-10-01';
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
    expect(find.text('这天不在已知课表范围内'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
  });

  testWidgets('转场保持出场列表的滚动位置，反向拖回不误切日', (tester) async {
    // 空档合成一行后内容变短，放大字号仍构成需要滚动的长列表。
    await _mount(tester, _Gateway(periods: 12), size: const Size(390, 670), scale: 1.6);
    final list = find.descendant(
      of: find.byType(CourseDayCards),
      matching: find.byType(ListView),
    );
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    scroll.jumpTo(150);
    await tester.pump();
    await _swipeDate(tester, '2026-09-25', 100, settle: false);
    await tester.pump(const Duration(milliseconds: 32));
    final outgoing = find.byKey(const ValueKey('today-frame-2026-09-25'));
    final oldPosition = tester
        .state<ScrollableState>(
          find.descendant(of: outgoing, matching: find.byType(Scrollable)),
        )
        .position;
    expect(identical(scroll, oldPosition), isTrue);
    expect(oldPosition.pixels, 150);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(_date('2026-09-26')),
    );
    await gesture.moveBy(const Offset(0, 24));
    await gesture.moveBy(const Offset(0, 100));
    await gesture.moveBy(const Offset(0, -85));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
  });

  testWidgets('课程区慢拖连续预览不丢手势，松手正确提交且新旧页有课空日互换', (tester) async {
    final gateway = _Gateway()..emptyWeekdays = {6};
    await _mount(tester, gateway);
    final cards = find.byType(CourseDayCards);
    final gesture = await tester.startGesture(tester.getCenter(cards));
    await gesture.moveBy(const Offset(0, -24));await tester.pump();
    for (var index = 0; index < 6; index++) { await gesture.moveBy(const Offset(0, -24));await tester.pump(const Duration(milliseconds:16)); }
    expect(_frame('2026-09-26'), findsOneWidget);
    await gesture.up();await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);expect(_frame('2026-09-25'), findsNothing);
    expect(find.text('这天没课'), findsOneWidget);
    final reverse = await tester.startGesture(tester.getCenter(find.byType(CourseDayCards)));
    await reverse.moveBy(const Offset(0,24));await tester.pump();
    for(var index=0;index<6;index++){await reverse.moveBy(const Offset(0,24));await tester.pump(const Duration(milliseconds:16));}
    await reverse.up();await tester.pumpAndSettle();
    expect(_date('2026-09-25'),findsOneWidget);expect(gateway.network,0);
  });

  testWidgets('分支返回与前后台保留浏览日，午夜仅跟随今天者换日', (tester) async {
    var now = _initial;
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    final gateway = _Gateway();
    await _mount(tester, gateway, now: () => now, active: active);
    await _swipeDate(tester, '2026-09-25', -100);
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pumpAndSettle();
    expect(_date('2026-09-24'), findsOneWidget);
    now = DateTime.utc(2026, 9, 25, 16, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_date('2026-09-24'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pumpAndSettle();
    expect(_date('2026-09-26'), findsOneWidget);
    now = DateTime.utc(2026, 9, 26, 16, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_date('2026-09-27'), findsOneWidget);
    expect(gateway.network, 0);
  });

  testWidgets('迟到的读取不覆盖新快照，也不弹旧错误', (tester) async {
    final gateway = _Gateway();
    final delayed = Completer<GatewayResult<ScheduleView>>();
    gateway.pending = delayed;
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await _mount(tester, gateway, active: active);
    active.value = false;
    await tester.pump();
    active.value = true;
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    delayed.complete(
      const GatewayResult(
        ok: false,
        source: 'local',
        fetchedAt: '',
        error: GatewayError(code: 'STALE', message: '旧错误'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧错误'), findsNothing);
    expect(_date('2026-09-25'), findsOneWidget);
  });

  testWidgets('学期边界不越界，今天范围外仍可归位，不把未知当无课', (tester) async {
    await _mount(tester, _Gateway(start: '2026-09-01', weeks: 1));
    expect(find.text('这天不在已知课表范围内'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
    await tester.tap(find.text('查看已知课表'));
    await tester.pumpAndSettle();
    expect(_date('2026-09-06'), findsOneWidget);
    await _swipeDate(tester, '2026-09-06', 100);
    expect(_date('2026-09-06'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
  });

  testWidgets('缺开学日与未同步、空学期、读取失败分别展示', (tester) async {
    await _mount(tester, _Gateway(start: null));
    expect(find.text('设置开学日'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, _Gateway()..known = false);
    expect(find.text('尚未同步课表'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, _Gateway(empty: true));
    expect(find.text('当前学期暂无课程'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, _Gateway()..failed = true);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('读取失败'), findsOneWidget);
    expect(find.text('这天没课'), findsNothing);
  });

  testWidgets('今天昨天明天空日均有顶部胶囊且不伪造实时摘要', (tester) async {
    await _mount(tester, _Gateway()..emptyWeekdays = {4,5,6});
    expect(find.text('今天暂无课程'), findsOneWidget);
    // 今天没课时预告下一节，跳过同样没课的周六。
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '下一节 后天 8:00 星期7的课 教室'), findsOneWidget);
    expect(find.text('这天没课'), findsOneWidget);
    await _swipeDate(tester, '2026-09-25', 100);
    expect(find.text('当天暂无课程'), findsOneWidget);
    expect(find.text('今天暂无课程'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('today-reset')));await tester.pumpAndSettle();
    await _swipeDate(tester, '2026-09-25', -100);
    expect(find.text('当天暂无课程'), findsOneWidget);
    expect(find.textContaining('下一节'), findsNothing);
    expect(find.textContaining('后上课'), findsNothing);
  });

  testWidgets('此刻卡：上课中按小时分钟显示剩余与起止进度条，课前显示下一节，下课后提示课上完了', (tester) async {
    var now = DateTime.utc(2026, 9, 25, 0, 20);
    await _mount(tester, _Gateway(), now: () => now);
    expect(find.text('上课中 · 第1–2节'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '1小时25分后下课'), findsOneWidget);
    expect(find.text('8:00'), findsNWidgets(2));
    expect(find.text('9:45'), findsWidgets);
    expect(find.textContaining('距离'), findsNothing);
    // 窄屏特大字号时右侧时长不挤爆课名。
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, _Gateway(), now: () => now, size: const Size(320, 640), scale: 1.4);
    expect(find.text('上课中 · 第1–2节'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    now = DateTime.utc(2026, 9, 24, 23, 15);
    await _mount(tester, _Gateway(), now: () => now);
    expect(find.text('下一节 · 第1–2节'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '45分钟后上课'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    now = DateTime.utc(2026, 9, 25, 2);
    await _mount(tester, _Gateway(), now: () => now);
    expect(find.text('今天的课上完了'), findsOneWidget);
    // 课上完后预告下一节，省去下滑切日。
    expect(find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.label == '下一节 明天 8:00 星期6的课 教室'), findsOneWidget);
    expect(find.text('下一节 · 明天 8:00'), findsOneWidget);
    // 单击课程卡弹只读详情：当天时段与这门课的全部上课时段，不出编辑入口。
    await tester.tap(find.text('星期5的课'));
    await tester.pumpAndSettle();
    expect(find.text('上课时段'), findsOneWidget);
    expect(find.text('周五 第1–2节 · 第1–8周 · 教室'), findsOneWidget);
    expect(find.text('编辑课程'), findsNothing);
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('上课时段'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('看别的日子时“今天”胶囊不压最后一节课：底栏占位下静止时末卡在胶囊之上', (tester) async {
    // 底部留白模拟悬浮底栏的占位（各页的底部安全区）。
    await _mount(tester, _Gateway(periods: 12), size: const Size(390, 560), bottomPadding: 100);
    await _swipeDate(tester, '2026-09-25', 100);
    expect(_date('2026-09-26'), findsOneWidget);
    final last = find.byWidgetPredicate((widget) => widget.key is ValueKey<String> && (widget.key! as ValueKey<String>).value.startsWith('course-card-') && (widget.key! as ValueKey<String>).value.contains(':11-12'));
    expect(tester.getRect(last).bottom, lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('today-reset'))).top));
    expect(tester.takeException(), isNull);
  });

  testWidgets('日期同栏且不再创建独立切日胶囊，预览不提交', (tester) async {
    await _mount(tester, _Gateway());
    expect(tester.getCenter(_date('2026-09-25')).dy, closeTo(tester.getCenter(find.text('今天').first).dy, 1));
    final gesture = await tester.startGesture(tester.getCenter(_date('2026-09-25')));
    await gesture.moveBy(const Offset(0, -24)); await tester.pump();
    await gesture.moveBy(const Offset(0, -40)); await tester.pump();
    expect(_frame('2026-09-26'), findsOneWidget);
    expect(_offset(tester, '2026-09-25'), lessThan(0));
    expect(_offset(tester, '2026-09-26'), greaterThan(0));
    expect(find.byKey(const ValueKey('today-pull-next-shape')), findsNothing);
    expect(find.byKey(const ValueKey('today-pull-previous-shape')), findsNothing);
    await gesture.cancel();await tester.pumpAndSettle();
    expect(_frame('2026-09-26'), findsNothing);
    expect(_date('2026-09-25'), findsOneWidget);
  });

  for (final configuration in [(size: const Size(390, 850), scale: 1.0), (size: const Size(320, 640), scale: 1.4), (size: const Size(740, 420), scale: 1.0)]) {
    testWidgets('交接不重排原课程，取消恢复位置 ${configuration.size} ${configuration.scale}', (tester) async {
      await _mount(tester, _Gateway(), size: configuration.size, scale: configuration.scale);
      final cards = find.descendant(of: _frame('2026-09-25'), matching: find.byType(CourseDayCards));
      final before = tester.getSize(cards);final element = tester.element(cards);
      final gesture = await tester.startGesture(tester.getCenter(_date('2026-09-25')));
      await gesture.moveBy(const Offset(0, 24)); await tester.pump();
      await gesture.moveBy(const Offset(0, 40)); await tester.pump();
      expect(identical(tester.element(cards), element), isTrue);
      expect(tester.getSize(cards), before);
      expect(_offset(tester, '2026-09-25'), greaterThan(0));
      expect(_offset(tester, '2026-09-24'), lessThan(0));
      await gesture.cancel();await tester.pumpAndSettle();
      expect(_offset(tester, '2026-09-25'), 0);expect(_frame('2026-09-24'), findsNothing);expect(tester.takeException(),isNull);
    });
  }

  testWidgets('拖动达到阈值后进入后台，恢复与松手不提交旧手势', (tester) async {
    await _mount(tester, _Gateway());
    final gesture = await tester.startGesture(tester.getCenter(_date('2026-09-25')));
    await gesture.moveBy(const Offset(0, -24));
    await gesture.moveBy(const Offset(0, -80));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 80));
    expect(_frame('2026-09-26'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await gesture.up(); await tester.pumpAndSettle();
    expect(_date('2026-09-25'), findsOneWidget);
    expect(find.byKey(const ValueKey('today-pull-next-shape')), findsNothing);
    expect(find.byKey(const ValueKey('today-pull-previous-shape')), findsNothing);
  });

  testWidgets('窄屏大字号与减少动画可操作，不溢出', (tester) async {
    await _mount(
      tester,
      _Gateway(),
      reduced: true,
      scale: 1.4,
      size: const Size(320, 640),
    );
    await _swipeDate(tester, '2026-09-25', 100);
    expect(_date('2026-09-26'), findsOneWidget);
    expect(find.byType(CourseDayCards), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('today-reset')));
    await tester.pump();
    expect(_date('2026-09-25'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final date in ['2026-09-30', '2026-12-31', '2028-02-28']) {
    testWidgets('$date连续日期跨月年和闰日', (tester) async {
      final instant = parseIsoDate(date).add(const Duration(hours: 4));
      final gateway = _Gateway(
        start: formatIsoDate(instant.subtract(const Duration(days: 7))),
      );
      await _mount(tester, gateway, now: () => instant);
      await _swipeDate(tester, date, 100);
      final next = formatIsoDate(instant.add(const Duration(days: 1)));
      expect(_date(next), findsOneWidget);
      expect(gateway.network, 0);
    });
  }
}
