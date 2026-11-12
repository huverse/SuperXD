import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

PlaygroundGame _game(String id) => playgroundCatalog.firstWhere((game) => game.id == id);

Finder _peg(int index) => find.bySemanticsLabel(RegExp('^第${index + 1}根柱子'));
Finder _cell(int row, int column) => find.bySemanticsLabel(RegExp('^第${row + 1}行第${column + 1}列，'));

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时只推进固定时长。
Future<void> _step(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));

void main() {
  testWidgets('首页按子类分组、只列已登记的游戏，点卡片进对局页，最近玩过记下来', (tester) async {
    final store = PlaygroundStore.memory();
    final router = GoRouter(initialLocation: '/playground', routes: [
      GoRoute(path: '/playground', pageBuilder: (context, state) => campusPage(key: state.pageKey, child: PlaygroundPage(store: store, games: playgroundCatalog, groups: playgroundGroups))),
      for (final game in playgroundCatalog)
        GoRoute(path: '/playground/${game.id}', pageBuilder: (context, state) => campusPage(key: state.pageKey, child: PlaygroundGameHost(game: game, store: store))),
    ]);
    await tester.pumpWidget(MaterialApp.router(theme: campusTheme(), routerConfig: router));
    await tester.pumpAndSettle();
    expect(find.text('格子谜题'), findsOneWidget);
    expect(find.text('移动与规划'), findsOneWidget);
    // 没有游戏的子类不显示，也不放占位卡（按登记表里还空着的子类查，游戏陆续登记进来也不用改这里）。
    for (final group in playgroundGroups.where((group) => !playgroundCatalog.any((game) => game.group.id == group.id))) {
      expect(find.text(group.name), findsNothing);
    }
    expect(find.text('最近玩过'), findsNothing);

    await tester.tap(find.text('汉诺塔'));
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsOneWidget);
    expect(store.recent, ['hanoi']);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    expect(find.text('最近玩过'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '汉诺塔'), findsOneWidget);
  });

  testWidgets('汉诺塔：点选走完最优解弹出新纪录，违规不算步数，撤销退回，拖动也能挪', (tester) async {
    final semantics = tester.ensureSemantics();
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    final puzzle = const HanoiRules().generate(1, PuzzleTier.entry).puzzle;
    expect(find.textContaining('最少 7 步'), findsOneWidget);

    // 拖动：从第一根拖到第二根。
    await tester.dragFrom(tester.getCenter(_peg(0)), tester.getCenter(_peg(1)) - tester.getCenter(_peg(0)));
    await _step(tester);
    expect(find.textContaining('1 步'), findsOneWidget);
    // 违规：第一根最上面的 1 号盘压到第二根的 0 号上。
    await _tapOn(tester, _peg(0));
    await _step(tester);
    await _tapOn(tester, _peg(1));
    await _step(tester);
    expect(find.textContaining('1 步'), findsOneWidget);
    // 撤销回到开局。
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await _step(tester);
    expect(find.textContaining('0 步'), findsOneWidget);

    for (final move in hanoiSolution(puzzle)) {
      await _tapOn(tester, _peg(move.from));
      await _step(tester);
      await _tapOn(tester, _peg(move.to));
      await _step(tester);
    }
    await tester.pumpAndSettle();
    expect(find.text('新纪录'), findsOneWidget);
    expect(find.textContaining('7 步，正好最少'), findsOneWidget);
    expect(store.best('hanoi', PuzzleTier.entry), isNotNull);
    expect(store.best('hanoi', PuzzleTier.entry)!.moves, 7);

    // 换到下一档：换一道 4 盘的题。
    await tester.tap(find.text('换到简单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最少 15 步'), findsOneWidget);
    expect(store.tierOf('hanoi'), PuzzleTier.easy);
    semantics.dispose();
  });

  testWidgets('换难度：走过几步后先确认，确认才换题', (tester) async {
    final semantics = tester.ensureSemantics();
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 2)));
    await tester.pumpAndSettle();
    await _tapOn(tester, _peg(0));
    await _step(tester);
    await _tapOn(tester, _peg(1));
    await _step(tester);
    await tester.tap(find.widgetWithText(TextButton, '入门'));
    await _step(tester);
    await tester.tap(find.text('专家'));
    await _step(tester);
    expect(find.text('换成专家？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _step(tester);
    expect(find.textContaining('最少 7 步'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '入门'));
    await _step(tester);
    await tester.tap(find.text('专家'));
    await _step(tester);
    await tester.tap(find.text('换难度'));
    await _step(tester);
    expect(find.widgetWithText(TextButton, '专家'), findsOneWidget);
    expect(find.textContaining('0 步'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('数织：拖动锁在一行、撤销按笔退回，按参考解点完即解开', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: NonogramPage(game: _game('nonogram'), store: store, seeds: () => 3)));
    await tester.pumpAndSettle();
    final draw = const NonogramRules().generate(3, PuzzleTier.entry);

    // 斜着拖：按起点后第一格的方向锁成横向，只改第二行。
    await tester.dragFrom(tester.getCenter(_cell(1, 0)), tester.getCenter(_cell(2, 4)) - tester.getCenter(_cell(1, 0)));
    await _step(tester);
    for (var column = 0; column < 5; column++) {
      expect(find.bySemanticsLabel('第2行第${column + 1}列，已涂'), findsOneWidget);
    }
    expect(find.bySemanticsLabel('第3行第5列，空'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await _step(tester);
    expect(find.bySemanticsLabel('第2行第1列，空'), findsOneWidget);

    // 标叉模式点一格，再切回涂色按参考解点完。
    await tester.tap(find.text('标叉'));
    await _step(tester);
    final blank = draw.solution.indexOf(false);
    await _tapOn(tester, _cell(blank ~/ 5, blank % 5));
    await _step(tester);
    expect(find.bySemanticsLabel('第${blank ~/ 5 + 1}行第${blank % 5 + 1}列，已标叉'), findsOneWidget);
    await tester.tap(find.text('涂色'));
    await _step(tester);
    for (var index = 0; index < draw.solution.length; index++) {
      if (!draw.solution[index]) continue;
      await _tapOn(tester, _cell(index ~/ 5, index % 5));
      await _step(tester);
    }
    await tester.pumpAndSettle();
    expect(find.text('新纪录'), findsOneWidget);
    expect(store.best('nonogram', PuzzleTier.entry), isNotNull);
    semantics.dispose();
  });

  testWidgets('数织：双指张开放大格子，第二根手指落下时这一笔作废', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final store = PlaygroundStore.memory();
    await store.chooseTier('nonogram', PuzzleTier.expert);
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: NonogramPage(game: _game('nonogram'), store: store, seeds: () => 4)));
    await tester.pumpAndSettle();
    final before = tester.getRect(_cell(7, 7)).width;
    expect(before, lessThan(44));
    final center = tester.getCenter(_cell(7, 7));
    final first = await tester.startGesture(center);
    await tester.pump();
    // 第一根手指已经把起点涂上了。
    expect(find.bySemanticsLabel('第8行第8列，已涂'), findsOneWidget);
    final second = await tester.startGesture(center + const Offset(30, 0));
    await tester.pump();
    expect(find.bySemanticsLabel('第8行第8列，空'), findsOneWidget);
    for (var step = 0; step < 5; step++) {
      await first.moveBy(const Offset(-8, 0));
      await second.moveBy(const Offset(8, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pump();
    expect(tester.getRect(_cell(7, 7)).width, greaterThan(before * 1.2));
    // 缩放不算一步：没有可撤销的笔画。
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);
    semantics.dispose();
  });

  test('本机记录：最好成绩只在更快时更新，最近玩过有上限，写盘后重新打开还在，坏文件当没有', () async {
    final directory = await Directory.systemTemp.createTemp('playground_store');
    addTearDown(() => directory.delete(recursive: true));
    final file = File(path.join(directory.path, 'playground', 'playground.json'));
    final store = PlaygroundStore(() async => file);
    final at = DateTime.utc(2026, 11, 12, 12);
    expect(await store.finish('hanoi', PuzzleTier.normal, millis: 60000, moves: 40, at: at), isTrue);
    expect(await store.finish('hanoi', PuzzleTier.normal, millis: 70000, moves: 31, at: at), isFalse);
    expect(await store.finish('hanoi', PuzzleTier.normal, millis: 50000, moves: 33, at: at), isTrue);
    expect(await store.finish('hanoi', PuzzleTier.entry, millis: 9000, moves: 7, at: at), isTrue);
    await store.chooseTier('hanoi', PuzzleTier.hard);
    for (final id in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) {
      await store.opened(id);
    }
    expect(store.recent, ['g', 'f', 'e', 'd', 'c', 'b']);

    final reopened = PlaygroundStore(() async => file);
    await reopened.ready;
    expect(reopened.best('hanoi', PuzzleTier.normal)!.millis, 50000);
    expect(reopened.best('hanoi', PuzzleTier.normal)!.moves, 33);
    expect(reopened.topBest('hanoi')!.tier, PuzzleTier.normal);
    expect(reopened.tierOf('hanoi'), PuzzleTier.hard);
    expect(reopened.tierOf('nonogram'), PuzzleTier.entry);
    expect(reopened.recent.first, 'g');

    await file.writeAsString('{"best": {"hanoi": {"normal": {"millis": "坏"}}}, "tiers": 3');
    final broken = PlaygroundStore(() async => file);
    await broken.ready;
    expect(broken.best('hanoi', PuzzleTier.normal), isNull);
    expect(broken.recent, isEmpty);
  });
}
