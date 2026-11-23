import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_services.dart';
import 'package:superxd/app_session.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/application/quick_nav.dart';
import 'package:superxd/domain/feature_flags.dart';
import 'package:superxd/domain/quick_nav.dart';
import 'package:superxd/local/quick_nav_memory.dart';
import 'package:superxd/page/academic_page.dart';
import 'package:superxd/page/quick_edit_page.dart';
import 'package:superxd/page/schedule_page.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/page/today_page.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_pull_button.dart';
import 'package:superxd/theme/campus_side_drawer.dart';
import 'fixture_campus_gateway.dart';
import 'page_fixture_support.dart';

// 今天页侧栏（11-23，人工决策见 page/side_drawer.dart 的 SideDrawerPanel 与 today_page.dart 的顶栏）。
class _Gate implements FeatureGate {
  _Gate(this.on);
  final Set<String> on;
  final _changes = StreamController<void>.broadcast();

  @override
  bool isOn(FeatureFlag flag) => on.contains(flag.id);

  @override
  Stream<void> get changes => _changes.stream;
}

Future<(QuickNav, AppSession)> _app(WidgetTester tester, {QuickNavPrefs prefs = const QuickNavPrefs(), FeatureGate? features}) async {
  final fixtures = pageFixtures();
  final session = AppSession(FixtureAccounts(FixtureCampusGateway(readText: (name) async => fixtures[name]!), signedIn: true));
  await session.restore();
  final nav = QuickNav(memory: FileQuickNavMemory.memory(prefs));
  await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(quickNav: nav, features: features)));
  await tester.pumpAndSettle();
  return (nav, session);
}

CampusSideDrawerState _drawer(WidgetTester tester) => tester.state<CampusSideDrawerState>(find.byType(CampusSideDrawer));

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byTooltip('侧栏'));
  await tester.pumpAndSettle();
}

Future<void> _done(WidgetTester tester, AppSession session) async {
  await tester.pumpWidget(const SizedBox());
  session.dispose();
}

void main() {
  group('常用与最近的规则', () {
    test('最近：最新的在前、去重、最多 5 个；常用去重、丢掉空 id', () {
      var prefs = const QuickNavPrefs();
      for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'b']) {
        prefs = prefs.visited(id);
      }
      expect(prefs.recent, ['b', 'f', 'e', 'd', 'c']);
      expect(prefs.pinned, isNull, reason: '没编辑过常用');
      expect(prefs.pinning(['x', '', 'y', 'x']).pinned, ['x', 'y']);
    });

    test('本机文件是外部输入：坏了的项丢掉，整份不是对象当没有', () {
      expect(QuickNavPrefs.fromJson('坏的').pinned, isNull);
      final prefs = QuickNavPrefs.fromJson({'pinned': ['/schedule', 3, null, '/schedule', '/grades'], 'recent': '不是列表'});
      expect(prefs.pinned, ['/schedule', '/grades']);
      expect(prefs.recent, isEmpty);
      expect(QuickNavPrefs.fromJson(const QuickNavPrefs(recent: ['/a']).toJson()).recent, ['/a']);
    });

    test('搜索排序：名字开头最前、名字里有其次、只有别名里有再次', () {
      expect(quickNavRank('课', '课表', const []), 0);
      expect(quickNavRank('签到', '学习通签到', const []), 1);
      expect(quickNavRank('洗澡', '住理生活', const ['洗澡']), 2);
      expect(quickNavRank('  ', '课表', const []), isNull);
      expect(quickNavRank('成绩', '课表', const ['教务']), isNull);
    });

    test('本机记录：写进 quick_nav.json、重开读回来；坏文件当没有', () async {
      final directory = await Directory.systemTemp.createTemp('quick_nav');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/quick_nav.json');
      final memory = await FileQuickNavMemory.open(file);
      await memory.save(const QuickNavPrefs(pinned: ['/grades'], recent: ['/schedule']));
      final reopened = await FileQuickNavMemory.open(file);
      expect(reopened.prefs.pinned, ['/grades']);
      expect(reopened.prefs.recent, ['/schedule']);
      await file.writeAsString('{坏');
      expect((await FileQuickNavMemory.open(file)).prefs.pinned, isNull);
    });

    test('进了已在最前的入口不再写、不通知；存常用先通知', () async {
      final nav = QuickNav(memory: FileQuickNavMemory.memory(const QuickNavPrefs(recent: ['/schedule'])));
      var notified = 0;
      nav.addListener(() => notified++);
      nav.visit('/schedule');
      expect(notified, 0);
      nav.visit('/grades');
      expect(nav.prefs.recent, ['/grades', '/schedule']);
      expect(notified, 1);
      await nav.pin(['/grades']);
      expect(nav.prefs.pinned, ['/grades']);
      expect(notified, 2);
    });
  });

  testWidgets('今天页顶栏两侧圆钮、日期居中；点左边拉出侧栏，常用是默认那几个（看不见的跳过），点压暗处关上', (tester) async {
    final (_, session) = await _app(tester);
    final menu = tester.getCenter(find.byTooltip('侧栏')), sync = tester.getCenter(find.byTooltip('同步'));
    final width = tester.getSize(find.byType(TodayPage)).width;
    expect(menu.dx + sync.dx, moreOrLessEquals(width, epsilon: 1), reason: '两个圆钮左右对称');
    await _open(tester);
    expect(_drawer(tester).isOpen, isTrue);
    expect(find.descendant(of: find.byTooltip('侧栏'), matching: find.byType(CampusMenuGlyph)), findsOneWidget, reason: '左上角是同 Claude 的三道横线');
    for (final title in ['常用', '课表', '成绩', '学习通签到', '快递', '视频解析', '游乐场']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('住理生活'), findsNothing, reason: '灰度没开的不列');
    expect(find.text('最近'), findsNothing, reason: '还没进过任何一页');
    expect(find.text('林同学'), findsNothing, reason: '底部没有「我的」那一行（11-23 用户嫌冗余删掉）');
    await tester.tapAt(Offset(width - 12, 400));
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isFalse);
    expect(find.text('常用'), findsNothing);
    await tester.tap(find.byTooltip('侧栏'));
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isTrue, reason: '合上后左上角照样能点开（弹簧收尾吸到 0，透明的压暗层不挡）');
    await _done(tester, session);
  });

  testWidgets('今天页上从左往右滑拉出、往左滑关上；返回键先关侧栏；别的栏滑动不拉出', (tester) async {
    final (_, session) = await _app(tester);
    await tester.dragFrom(const Offset(80, 420), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isTrue);
    await tester.flingFrom(const Offset(300, 420), const Offset(-200, 0), 1200);
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isFalse);
    // 滑着合上、还在收尾的最后一点时马上点左上角：要能拉开，不被几乎透明的压暗层吞掉。
    await _open(tester);
    await tester.flingFrom(const Offset(300, 420), const Offset(-200, 0), 1200);
    while (_drawer(tester).progress.value >= .02) {
      await tester.pump(const Duration(milliseconds: 8));
    }
    await _open(tester);
    expect(_drawer(tester).isOpen, isTrue);
    await tester.tapAt(const Offset(780, 300));
    await tester.pumpAndSettle();
    await _open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isFalse);
    expect(find.byType(TodayPage), findsOneWidget, reason: '返回只关侧栏，没退出');
    GoRouter.of(tester.element(find.byType(ShellPage))).go('/service');
    await tester.pumpAndSettle();
    await tester.dragFrom(const Offset(80, 420), const Offset(260, 0));
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isFalse);
    await _done(tester, session);
  });

  testWidgets('点常用里的一项：推入那页并记进最近，盖住后侧栏合上，返回回到今天页；从别处进的也记进最近、已在常用的不重复', (tester) async {
    final (nav, session) = await _app(tester);
    await _open(tester);
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();
    expect(find.byType(SchedulePage), findsOneWidget);
    expect(nav.prefs.recent.first, '/schedule');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsOneWidget);
    expect(_drawer(tester).isOpen, isFalse);
    unawaited(GoRouter.of(tester.element(find.byType(ShellPage))).push('/academic'));
    await tester.pumpAndSettle();
    expect(find.byType(AcademicPage), findsOneWidget);
    expect(nav.prefs.recent, ['/academic', '/schedule']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await _open(tester);
    expect(find.text('最近'), findsOneWidget);
    expect(find.text('学业'), findsOneWidget);
    expect(find.text('课表'), findsOneWidget, reason: '课表已在常用里，最近不重复列');
    await _done(tester, session);
  });

  testWidgets('编辑常用：取消勾选、勾上的接到末尾、拖动排序，点了就存；看不见的原样留在末尾；回来还开着侧栏', (tester) async {
    final (nav, session) = await _app(tester, prefs: const QuickNavPrefs(pinned: ['/toolbox/life/zhuli', '/schedule', '/grades']));
    await _open(tester);
    expect(find.text('课表'), findsOneWidget);
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.byType(QuickEditPage), findsOneWidget);
    expect(find.text('住理生活'), findsNothing);
    await tester.tap(find.text('课表'));
    await tester.pumpAndSettle();
    expect(nav.prefs.pinned, ['/grades', '/toolbox/life/zhuli']);
    await tester.scrollUntilVisible(find.text('快递'), 120, scrollable: find.descendant(of: find.byType(QuickEditPage), matching: find.byType(Scrollable)));
    await tester.tap(find.text('快递'));
    await tester.pumpAndSettle();
    expect(nav.prefs.pinned, ['/grades', '/toolbox/express', '/toolbox/life/zhuli']);
    await tester.scrollUntilVisible(find.text('成绩'), -120, scrollable: find.descendant(of: find.byType(QuickEditPage), matching: find.byType(Scrollable)));
    final handle = find.byType(ReorderableDragStartListener);
    // 同开屏画作播放顺序页的测法：按住把手分两步往上拖过上一张。
    final gesture = await tester.startGesture(tester.getCenter(handle.at(1)));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(nav.prefs.pinned, ['/toolbox/express', '/grades', '/toolbox/life/zhuli']);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isTrue, reason: '编辑页不合上侧栏');
    final express = tester.getTopLeft(find.text('快递')).dy, grades = tester.getTopLeft(find.text('成绩')).dy;
    expect(express, lessThan(grades));
    await _done(tester, session);
  });

  testWidgets('下拉进搜索：到位松手展开成整屏、出输入框；按名字与别名搜并写分组，搜不到写一行；关闭钮与返回键先退回列表', (tester) async {
    final (_, session) = await _app(tester, features: _Gate({lifeFlag.id, zhuliFlag.id}));
    await _open(tester);
    expect(find.text('住理生活'), findsOneWidget, reason: '灰度开着就列出来（默认常用里有它）');
    await tester.drag(find.text('课表'), const Offset(0, 40));
    await tester.pumpAndSettle();
    expect(_drawer(tester).expanded.value, isFalse, reason: '没拉到位不进搜索');
    await tester.drag(find.text('课表'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(_drawer(tester).expanded.value, isTrue);
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.testTextInput.isVisible, isTrue, reason: '进搜索就弹键盘，展开动画走完也不收起');
    expect(find.text('最近使用'), findsNothing, reason: '还没进过任何一页');
    expect(find.text('同步记录'), findsOneWidget, reason: '空查询按分组列出全部');
    await tester.enterText(find.byType(TextField), '洗澡');
    await tester.pump();
    expect(find.text('住理生活'), findsOneWidget);
    expect(find.text('百宝箱'), findsOneWidget, reason: '每行写分组');
    await tester.enterText(find.byType(TextField), '找不到的东西');
    await tester.pump();
    expect(find.text('没有找到'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭搜索'));
    await tester.pumpAndSettle();
    expect((_drawer(tester).expanded.value, _drawer(tester).isOpen), (false, true));
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(_drawer(tester).expanded.value, isTrue, reason: '点搜索钮也能进');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect((_drawer(tester).expanded.value, _drawer(tester).isOpen), (false, true), reason: '返回先退出搜索');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_drawer(tester).isOpen, isFalse);
    await _done(tester, session);
  });

  testWidgets('下拉进搜索再退回来：搜索钮上的圈从头算，不停在松手那一刻的回弹进度上（11-23 用户录屏）', (tester) async {
    final (_, session) = await _app(tester);
    await _open(tester);
    await tester.drag(find.text('课表'), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(_drawer(tester).expanded.value, isTrue);
    // 用户录屏里是按返回退出搜索（不经关闭钮）。
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_drawer(tester).expanded.value, isFalse);
    expect(tester.widget<CampusPullButton>(find.byType(CampusPullButton)).pull, 0);
    await _done(tester, session);
  });

  testWidgets('左上角签名为主：列表往上滚时跟着手指换成 Newsreader 斜体，滚回顶上换回签名', (tester) async {
    final (_, session) = await _app(tester, prefs: const QuickNavPrefs(pinned: ['/schedule', '/grades', '/academic', '/academic/records', '/toolbox', '/toolbox/short_video', '/toolbox/chaoxing', '/toolbox/express', '/playground', 'appearance', 'about', 'account']));
    await _open(tester);
    final newsreader = find.byWidgetPredicate((widget) => widget is Text && widget.data == 'SuperXD' && widget.style?.fontFamily == 'Newsreader');
    expect(newsreader, findsNothing, reason: '在顶上只有签名');
    final gesture = await tester.startGesture(tester.getCenter(find.text('成绩')));
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -20));
    await tester.pump();
    expect(newsreader, findsNothing, reason: '滚了一点还是签名在淡出');
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    expect(tester.widget<Opacity>(find.ancestor(of: newsreader, matching: find.byType(Opacity)).first).opacity, greaterThan(.9));
    await gesture.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(newsreader, findsNothing, reason: '滚回顶上换回签名');
    await gesture.up();
    await tester.pumpAndSettle();
    await _done(tester, session);
  });

  testWidgets('搜索里点一项：打开那页、侧栏合上，返回回到今天页', (tester) async {
    final (nav, session) = await _app(tester);
    await _open(tester);
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '成');
    await tester.pump();
    await tester.tap(find.text('成绩'));
    await tester.pumpAndSettle();
    expect(nav.prefs.recent.first, '/grades');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TodayPage), findsOneWidget);
    expect((_drawer(tester).isOpen, _drawer(tester).expanded.value), (false, false));
    await _done(tester, session);
  });
}
