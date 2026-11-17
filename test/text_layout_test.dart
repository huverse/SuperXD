import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/app_session.dart';
import 'package:superxd/application/app_accounts.dart';
import 'package:superxd/application/app_health.dart';
import 'package:superxd/application/developer_notes.dart';
import 'package:superxd/application/leisure.dart';
import 'package:superxd/application/network_preference.dart';
import 'package:superxd/domain/app_account.dart';
import 'package:superxd/domain/app_health.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/developer_note.dart';
import 'package:superxd/local/app_health_memory.dart';
import 'package:superxd/local/developer_note_memory.dart';
import 'package:superxd/local/network_mode_memory.dart';
import 'package:superxd/page/app_feedback_dialog.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/challenge/challenge_run_page.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/app_services.dart';
import 'package:superxd/app_shell.dart';
import 'package:superxd/page/shell_page.dart';
import 'package:superxd/theme/campus_surface.dart';

import 'fixture_campus_gateway.dart';
import 'form_layout_support.dart';
import 'page_fixture_support.dart';
import 'text_fit_support.dart';
import 'toolbox_test_support.dart';

// 主要页面在窄屏大字号、宋体加系统「粗体文本」与宽屏标准三种条件下排版不出错：不裁字、不剩一行标点，课程与提示不留孤字。
// 10-27 用户真机截图（iPhone 系统字体下「09:40」缺半个 0，360dp 安卓学期视图课名一两个字一行、同意行换行留大空行）后加。
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
      final fixtures = pageFixtures();
      final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
      // 开学日取八周前的周一，今天总在学期中间。
      final today = parseIsoDate(campusToday());
      await inner.setTermStart(pageTerm, formatIsoDate(today.subtract(Duration(days: today.weekday - 1 + 56))));
      final display = DisplaySettings.memory();
      await display.setFont(font);
      // 应用字号是实际显示大小：标准时跟随系统（系统字号照常生效），其余直接给大小（人工决策见 display_settings.dart 的 textSizeMin）。
      await display.setTextSize(app == 1 ? null : app);
      // 学期视图左侧栏按最宽的一项定宽，Maple 标准字号在 360dp 上放得下（人工决策见 schedule_page.dart 的 semesterRailFits），再大就收成横条。
      // 跟随系统时最多到推荐上限，也就是左侧栏放得下的最大字号（人工决策见 display_settings.dart 的 textSizeMin），系统 130% 也照样是左侧栏；
      // 自己选的大字号才收成横条。
      final rail = app <= 1;

      final loggedOut = AppSession(FixtureAccounts(inner, signedIn: false));
      await loggedOut.restore();
      await tester.pumpWidget(SuperXdApp(session: loggedOut, backgroundPhase: .18, services: AppServices(display: display, toolbox: fixture.runtime)));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '登录页');
      // 同意行：「用户协议 和 隐私政策」整组在同一行，换行后行距按文字排，不按 48 的按钮触区撑开。
      expect(tester.getTopLeft(find.text('隐私政策')).dy, closeTo(tester.getTopLeft(find.text('用户协议')).dy, 1));
      expect(tester.getTopLeft(find.text('用户协议')).dy - tester.getTopLeft(find.text('我已阅读并同意')).dy, lessThan(40 * system * app));
      // 登录按钮的图标紧挨着文字（以前按「正在登录」占位，图标与「登录」之间空出两个字宽）。
      final icon = find.descendant(of: find.byType(FilledButton), matching: find.byType(Icon)).first;
      expect(tester.getTopLeft(find.text('登录')).dx - tester.getCenter(icon).dx, closeTo(12 + 8, 1));
      // [人工决策-2026-11-17 21:24:25] 见 login_page.dart：同意行在登录卡片里、登录按钮正下方，百宝箱等入口在卡片下面。
      final agree = find.text('我已阅读并同意'), button = find.byType(FilledButton);
      expect(tester.getTopLeft(agree).dy, greaterThan(tester.getBottomLeft(button).dy));
      expect(tester.getTopLeft(agree).dy - tester.getBottomLeft(button).dy, lessThan(48 * system * app));
      expect(find.ancestor(of: agree, matching: find.byType(CampusSurface)), findsOneWidget);
      expect(tester.getTopLeft(find.text('百宝箱')).dy, greaterThan(tester.getBottomLeft(agree).dy));
      await tester.pumpWidget(const SizedBox());
      loggedOut.dispose();

      final session = AppSession(FixtureAccounts(inner, signedIn: true));
      await session.restore();
      await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: AppServices(display: display, toolbox: fixture.runtime)));
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

  // 11-17 设计审查：11-12 之后上线的页面没进排版体检，窄屏大字号下有孤字、截断与拆词（学业页学期名、挑战总览游戏名、删除游乐场数据、
  // 开发者的话标题、对局页状态行、新版本反馈的输入框标签）。这里按同样三种条件扫一遍。
  for (final (font, width, system, app, bold) in [
    ('maple', 360.0, 1.3, 1.0, false),
    ('serif', 360.0, 1.0, 1.4, true),
    ('maple', 411.0, 1.0, 1.0, false),
  ]) {
    testWidgets('排版（新页面）：$font ${width.toInt()}dp 系统×$system 应用×$app${bold ? ' 粗体文本' : ''}：学业、我的、应用账号、开发者的话、新版本反馈、挑战与对局页', (tester) async {
      tester.view.devicePixelRatio = 3;
      tester.view.physicalSize = Size(width * 3, 800 * 3);
      tester.platformDispatcher.textScaleFactorTestValue = system;
      if (bold) tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(boldText: true);
      addTearDown(tester.platformDispatcher.clearAllTestValues);
      addTearDown(tester.view.reset);
      await loadCampusFonts(tester);
      final fixture = ToolboxFixture();
      await tester.runAsync(fixture.initialize);
      final fixtures = pageFixtures();
      final inner = FixtureCampusGateway(readText: (name) async => fixtures[name]!);
      final display = DisplaySettings.memory();
      await display.setFont(font);
      await display.setTextSize(app == 1 ? null : app);
      final client = _AppAccountClient();
      final appAccounts = AppAccounts(client: client);
      await tester.runAsync(appAccounts.load);
      final network = NetworkPreference(memory: FileNetworkModeMemory.memory());
      final notes = DeveloperNotes(feed: _NoteFeed(), memory: FileDeveloperNoteMemory.memory());
      await tester.runAsync(notes.refresh);
      final health = AppHealth(memory: FileAppHealthMemory.memory(), channel: 'alpha', platform: 'android', versionCode: 30, client: _HealthClient());
      final services = AppServices(display: display, toolbox: fixture.runtime, playground: PlaygroundStore.memory(), appAccounts: appAccounts, network: network, notes: notes, health: health, leisure: Leisure(clearLocal: () async {}, signedIn: () => false));
      final session = AppSession(FixtureAccounts(inner, signedIn: true));
      await session.restore();
      await tester.pumpWidget(SuperXdApp(session: session, backgroundPhase: .18, services: services));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(ShellPage)));
      Future<void> back() async {
        await tester.tap(find.byTooltip('返回').last);
        await tester.pumpAndSettle();
      }

      unawaited(router.push('/academic'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '学业');
      await back();
      router.go('/mine');
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '我的');
      await tester.tap(find.text('应用账号'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '应用账号·没登录');
      client.session = const AppAccountSession(account: AppAccountRef(accountId: 'AAAAAAAAAAAAAAAAAAAAAA', slot: 'fake-slot'), username: 'tester_one');
      await tester.runAsync(appAccounts.load);
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '应用账号·登录着');
      await tester.scrollUntilVisible(find.text('删除游乐场数据'), 200);
      expect(_problems(tester), isEmpty, reason: '应用账号·登录着·最底下');
      await back();
      await tester.tap(find.text('开发者的话'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '开发者的话');
      await tester.tap(find.text('新版本来了：课表同步更快'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '读信');
      await back();
      await back();
      unawaited(showAppFeedback(tester.element(find.byType(ShellPage)), health));
      await tester.pumpAndSettle();
      await tester.tap(find.text('好用'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '新版本反馈');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // 对局页：状态长的几个游戏（外壳在后台出第一道题，按真实时间等它）。
      for (final game in ['flash', 'river', 'balance', 'schulte', 'knights']) {
        router.go('/today');
        await tester.pumpAndSettle();
        unawaited(router.push('/playground/$game'));
        final frame = find.byWidgetPredicate((widget) => widget is PlayFrame && widget.session.game.id == game);
        for (var round = 0; round < 80 && frame.evaluate().isEmpty; round++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump(const Duration(milliseconds: 200));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(_problems(tester), isEmpty, reason: '对局页 $game');
      }
      router.go('/today');
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      appAccounts.dispose();

      // 挑战一栏与总览（合成的一局：四关给碎片、一关收碎片）。
      final hub = _Hub();
      Widget page(Widget home) => ListenableBuilder(listenable: display, builder: (context, _) => MaterialApp(
        theme: campusTheme(fontFamily: display.fontFamily),
        // 应用字号是实际显示大小（同 SuperXdApp 里的 CampusTextScale）；标准时跟随系统。
        builder: (context, child) => app == 1 ? child! : MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(app)), child: child!),
        home: home,
      ));
      await tester.pumpWidget(page(PlaygroundPage(store: PlaygroundStore.memory(), games: playgroundCatalog, groups: playgroundGroups, challenges: hub, openAccount: (_) {})));
      await tester.pumpAndSettle();
      await tester.tap(find.text('挑战'));
      await tester.pumpAndSettle();
      expect(_problems(tester), isEmpty, reason: '挑战一栏');
      final controller = ChallengeRunController(hub: hub, run: _run());
      await tester.pumpWidget(page(ChallengeRunPage(controller: controller, games: playgroundCatalog, store: PlaygroundStore.memory())));
      await tester.pump(const Duration(milliseconds: 500));
      expect(_problems(tester), isEmpty, reason: '挑战总览');
      // 关卡卡片的游戏名不省略（以前两列卡片里截成「冰面…」），放不下一行就均衡折成两行。
      expect([for (final issue in scanTexts(tester)) if (issue.kind == 'truncate') '$issue'], isEmpty, reason: '挑战总览的游戏名');
      controller.dispose();
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(fixture.close);
    });
  }
}

// 以下是「新页面」那组用的合成替身。
class _AppAccountClient implements AppAccountClient {
  AppAccountSession? session;
  @override
  Future<AppAccountSession?> accountOf() async => session;
  @override
  Future<List<AppAccountRef>> dropLegacy() async => const [];
  @override
  Future<AppAccountSummary> summary() async => AppAccountSummary(accountId: session!.account.accountId, username: session!.username, deviceCount: 1, createdAt: DateTime.utc(2026));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HealthClient implements AppHealthClient {
  @override
  Future<void> report({required String channel, required String platform, required HealthDay day}) async {}
  @override
  Future<void> feedback({required String channel, required String platform, required int versionCode, required bool good, required String text}) async {}
}

class _NoteFeed implements DeveloperNoteFeed {
  @override
  Future<List<DeveloperNote>> fetch() async => [
    DeveloperNote(id: 'b', title: '新版本来了：课表同步更快', publishedAt: DateTime.now().toUtc(), body: '这一版把课表同步改快了，大部分学期十秒内就能同步完。\n\n有问题可以在关于页反馈。'),
    DeveloperNote(id: 'a', title: '开学第一周', publishedAt: DateTime.now().toUtc().subtract(const Duration(days: 30)), body: '欢迎试用。'),
  ];
}

ChallengeLevel _level(String id, String game, {String state = 'open', String tier = 'entry', List<String> inputs = const [], String? output, Object? puzzle, ChallengeGate? gate}) => ChallengeLevel(
  id: id, game: game, tier: tier, difficulty: 4, expected: const Duration(seconds: 60), inputs: inputs, output: output, letter: id.toUpperCase(),
  state: ChallengeLevelState.values.byName(state), submissions: 0, errors: 0, minimum: null, gate: gate, consume: null, extraOf: null, puzzle: puzzle,
);

ChallengeRun _run() {
  final now = DateTime.now().toUtc();
  return ChallengeRun(
    runId: 'RRRRRRRRRRRRRRRRRRRRRR', challengeId: 'weekly.2026-11-09.six', title: '六连环', label: '入门', timeLimit: const Duration(minutes: 15),
    startedAt: now, deadline: now.add(const Duration(minutes: 15)), serverTime: now, running: true, penalty: Duration.zero, ending: ChallengeFinal.locked,
    levels: [
      _level('a', 'hanoi', output: 'e', puzzle: const HanoiRules().encodePuzzle(const HanoiRules().generate(1, PuzzleTier.entry).puzzle)),
      _level('b', 'ice', output: 'e', state: 'solved', tier: 'easy'),
      _level('c', 'logicgrid', output: 'e', state: 'solved', tier: 'normal'),
      _level('d', 'knights', output: 'e', state: 'solved', tier: 'normal'),
      _level('e', 'twentyfour', state: 'gated', inputs: const ['a', 'b', 'c', 'd'], gate: const ChallengeGate(product: false, value: null)),
    ],
    result: null,
  );
}

class _Hub implements ChallengeHub {
  @override
  bool get signedIn => true;
  @override
  Stream<void> get changes => const Stream.empty();
  @override
  Future<ChallengeCatalog> catalog(Set<String> games) async => ChallengeCatalog(serverTime: DateTime.now().toUtc(), activeRun: null, challenges: [
    ChallengeSummary(
      id: 'weekly.2026-11-09.six', title: '六连环', label: '入门', levels: 6, tiers: const ['entry', 'entry', 'easy', 'easy', 'normal', 'normal'], edges: const [(0, 2), (1, 2), (2, 4), (3, 4), (4, 5)],
      timeLimit: const Duration(minutes: 50), endsAt: DateTime.now().add(const Duration(days: 2, hours: 1)), best: 42, playable: true, ticket: 0,
    ),
  ]);
  @override
  Future<ChallengeRun> run(String runId) async => _run();
  @override
  Future<PointsSummary> points() async => const PointsSummary(balance: 86, expiring: 0, expiringAt: null, earned: 0, level: 0, nextLevelAt: null);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
