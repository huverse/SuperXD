import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as path;

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_page.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_page.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/mines/mines_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_page.dart';
import 'package:superxd/playground/puzzle/nonogram/nonogram_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

import 'form_layout_support.dart';

PlaygroundGame _game(String id) => playgroundCatalog.firstWhere((game) => game.id == id);

Finder _peg(int index) => find.bySemanticsLabel(RegExp('^第${index + 1}根柱子'));
Finder _cell(int row, int column) => find.bySemanticsLabel(RegExp('^第${row + 1}行第${column + 1}列，'));

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时只推进固定时长。
Future<void> _step(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));

// 汉诺塔开局里的一步（题随种子变，按规则找）：合规或不合规的，rightward 为真时只找往右挪的。
HanoiMove _hanoiMove(HanoiPuzzle puzzle, {required bool legal, bool rightward = false}) {
  final stacks = hanoiStacks(puzzle.pegs, puzzle.start);
  for (var from = 0; from < puzzle.pegs; from++) {
    for (var to = rightward ? from + 1 : 0; to < puzzle.pegs; to++) {
      if (from != to && stacks[from].isNotEmpty && hanoiLegal(puzzle, stacks, (from: from, to: to)) == legal) return (from: from, to: to);
    }
  }
  throw StateError('开局没有这样的一步');
}

// 汉诺塔点选走一步：点起点柱再点终点柱。
Future<void> _hanoiTap(WidgetTester tester, HanoiMove move) async {
  await _tapOn(tester, _peg(move.from));
  await _step(tester);
  await _tapOn(tester, _peg(move.to));
  await _step(tester);
}

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
    // 有游戏的子类按顺序都显示；没有游戏的子类不显示，也不放占位卡（按登记表查，游戏陆续登记进来也不用改这里）。
    // 游戏多了首页要滚动、列表按需构建，所以按顺序滚到每个标题再看，最后滚回顶部。
    final scrollable = find.descendant(of: find.byType(PlaygroundPage), matching: find.byType(Scrollable)).first;
    for (final group in playgroundGroups) {
      if (playgroundCatalog.any((game) => game.group.id == group.id)) {
        await tester.scrollUntilVisible(find.text(group.name), 200, scrollable: scrollable);
        await tester.pumpAndSettle();
        expect(find.text(group.name), findsOneWidget);
      } else {
        expect(find.text(group.name), findsNothing);
      }
    }
    await tester.drag(scrollable, const Offset(0, 10000));
    await tester.pumpAndSettle();
    expect(find.text('最近玩过'), findsNothing);

    // 先滚到汉诺塔再点（跳到位后排一帧再点，不然按跳之前的位置点）。
    await tester.scrollUntilVisible(find.text('汉诺塔'), 200, scrollable: scrollable);
    await tester.pumpAndSettle();
    await tester.tap(find.text('汉诺塔'));
    await tester.pumpAndSettle();
    expect(find.byType(HanoiPage), findsOneWidget);
    expect(store.recent, ['hanoi']);
    await tester.tap(find.byTooltip('返回'));
    await tester.pumpAndSettle();
    // 返回后首页停在滚下去的位置，滚回顶部再看「最近玩过」。
    await tester.scrollUntilVisible(find.text('最近玩过'), -200, scrollable: find.descendant(of: find.byType(PlaygroundPage), matching: find.byType(Scrollable)).first);
    await tester.pumpAndSettle();
    expect(find.text('最近玩过'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '汉诺塔'), findsOneWidget);
  });

  // [人工决策-2026-11-19 13:20:14] 见 hanoi_page.dart 文件头：盘子按大小从红到紫拉开色相、正中写号码，目标缩略图用同一个盘子同色同号。
  for (final dark in [false, true]) {
    testWidgets('汉诺塔（${dark ? '深色' : '浅色'}）：每个盘子写号码、目标里同号同色；相邻大小的盘子颜色分得开，号码对盘子 4.5:1 以上', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1080 / 360;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(palette: dark ? CampusPalette.darkValues.first : CampusPalette.values.first), home: HanoiPage(game: _game('hanoi'), store: PlaygroundStore.memory(), seeds: () => 1)));
      await tester.pumpAndSettle();
      final disks = const HanoiRules().generate(1, PuzzleTier.entry).puzzle.disks;
      Color fill(Finder label) => (((tester.widget<AnimatedContainer>(find.ancestor(of: label, matching: find.byType(AnimatedContainer)).first).decoration as BoxDecoration).gradient as LinearGradient).colors.last);
      double contrast(Color a, Color b) {
        final (x, y) = (a.computeLuminance(), b.computeLuminance());
        return (math.max(x, y) + .05) / (math.min(x, y) + .05);
      }
      final colors = <Color>[];
      for (var number = 1; number <= disks; number++) {
        final labels = find.text('$number');
        expect(labels, findsNWidgets(2), reason: '棋盘上与目标里各一个 $number 号');
        expect(fill(labels.first), fill(labels.last), reason: '$number 号在棋盘与目标里同色');
        final ink = tester.widget<Text>(labels.first).style!.color!;
        expect(contrast(ink, fill(labels.first)), greaterThan(4.5), reason: '$number 号的号码看得清');
        expect(tester.getSize(labels.last).height, greaterThanOrEqualTo(13.5), reason: '目标里的号码也是 14 号');
        colors.add(fill(labels.first));
      }
      for (var index = 1; index < colors.length; index++) {
        final (a, b) = (colors[index - 1], colors[index]);
        final distance = math.sqrt(math.pow(a.r - b.r, 2) + math.pow(a.g - b.g, 2) + math.pow(a.b - b.b, 2));
        expect(distance, greaterThan(.25), reason: '$index 号与 ${index + 1} 号颜色分得开');
      }
    });
  }

  testWidgets('汉诺塔：点选走完最优解弹出新纪录，违规不算步数，撤销退回，拖动也能挪；目标缩略图读出目标局面，拿起时不亮出能放的柱子', (tester) async {
    final semantics = tester.ensureSemantics();
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    final draw = const HanoiRules().generate(1, PuzzleTier.entry);
    final puzzle = draw.puzzle, least = draw.solution.length;
    expect(find.textContaining('最少 $least 步'), findsOneWidget);
    expect(find.text('目标'), findsOneWidget);
    final goal = hanoiStacks(puzzle.pegs, puzzle.goal);
    final described = [for (var peg = 0; peg < puzzle.pegs; peg++) if (goal[peg].isNotEmpty) '第${peg + 1}根柱子从下到上是${goal[peg].map((disk) => '${disk + 1}号').join('、')}'].join('，');
    expect(find.bySemanticsLabel('目标，$described'), findsOneWidget);

    // 违规：大盘压小盘，轻震退回、不算步数。
    await _hanoiTap(tester, _hanoiMove(puzzle, legal: false));
    expect(find.textContaining('0 步'), findsOneWidget);
    // 拿起时只读「已拿起」，不亮出能放的柱子（人工决策见 hanoi_page.dart 文件头）。
    final first = _hanoiMove(puzzle, legal: true);
    await _tapOn(tester, _peg(first.from));
    await _step(tester);
    expect(find.bySemanticsLabel(RegExp('^第${first.from + 1}根柱子.*已拿起')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('可以放')), findsNothing);
    await _tapOn(tester, _peg(first.from));
    await _step(tester);
    // 拖动挪一步。
    await tester.dragFrom(tester.getCenter(_peg(first.from)), tester.getCenter(_peg(first.to)) - tester.getCenter(_peg(first.from)));
    await _step(tester);
    expect(find.textContaining('1 步'), findsOneWidget);
    // 撤销回到开局。
    await tester.tap(find.widgetWithText(FilledButton, '撤销'));
    await _step(tester);
    expect(find.textContaining('0 步'), findsOneWidget);

    for (final move in draw.solution) {
      await _hanoiTap(tester, move);
    }
    await tester.pumpAndSettle();
    expect(find.text('新纪录'), findsOneWidget);
    expect(find.textContaining('$least 步，正好最少'), findsOneWidget);
    expect(store.best('hanoi', PuzzleTier.entry), isNotNull);
    expect(store.best('hanoi', PuzzleTier.entry)!.moves, least);

    // 换到下一档：换一道简单档的题。
    await tester.tap(find.text('换到简单'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最少 ${hanoiMinMoves(const HanoiRules().generate(1, PuzzleTier.easy).puzzle)} 步'), findsOneWidget);
    expect(store.tierOf('hanoi'), PuzzleTier.easy);
    semantics.dispose();
  });

  testWidgets('汉诺塔的相邻与循环：底座下画箭头、读屏读规矩；逆着方向放提示条说规矩、不算步数，接着走一步合规的提示收起', (tester) async {
    final semantics = tester.ensureSemantics();
    // 普通档第 1 道是三柱循环，困难档第 2 道是四柱相邻。
    for (final (tier, seed, rule, reason) in [(PuzzleTier.normal, 1, '只能顺着箭头挪到下一根，最后一根挪回第一根', '只能顺着箭头挪到下一根'), (PuzzleTier.hard, 2, '只能挪到旁边的柱子', '只能挪到旁边的柱子')]) {
      final store = PlaygroundStore.memory();
      await store.chooseTier('hanoi', tier);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(key: ValueKey(tier), game: _game('hanoi'), store: store, seeds: () => seed)));
      await tester.pumpAndSettle();
      final puzzle = const HanoiRules().generate(seed, tier).puzzle;
      expect(puzzle.variant, tier == PuzzleTier.normal ? HanoiVariant.cyclic : HanoiVariant.adjacent);
      expect(find.bySemanticsLabel(rule), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^第${puzzle.pegs}根柱子')), findsOneWidget);
      // 一步大小合规、方向不许的：从有盘子的柱子挪到空柱或更大的盘子上，但不是许可的方向。
      final stacks = hanoiStacks(puzzle.pegs, puzzle.start);
      final wrong = [
        for (var from = 0; from < puzzle.pegs; from++)
          for (var to = 0; to < puzzle.pegs; to++)
            if (from != to && stacks[from].isNotEmpty && !hanoiAllowed(puzzle, from, to) && (stacks[to].isEmpty || stacks[to].last > stacks[from].last)) (from: from, to: to),
      ].first;
      await _hanoiTap(tester, wrong);
      expect(find.text(reason), findsOneWidget);
      expect(find.textContaining(RegExp('^0 步')), findsOneWidget);
      await _hanoiTap(tester, _hanoiMove(puzzle, legal: true));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(reason), findsNothing);
      expect(find.textContaining(RegExp('^1 步')), findsOneWidget);
    }
    semantics.dispose();
  });

  testWidgets('汉诺塔四柱在 360 宽、1.3 倍字号下放得下：柱子的触区并排不出界，盘子扁平不出列，拿起的盘子不压到上方的目标缩略图', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(720, 1400);
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final disks = find.byWidgetPredicate((widget) => widget.runtimeType.toString() == '_Disk');
    // 目标缩略图也用同一个盘子（人工决策见 hanoi_page.dart 文件头 11-19 那条）：棋盘上的是目标以外的那些。
    final goalBox = find.byWidgetPredicate((widget) => widget is Semantics && (widget.properties.label?.startsWith('目标，') ?? false));
    List<Element> board() => [for (final element in disks.evaluate()) if (find.descendant(of: goalBox, matching: find.byElementPredicate((candidate) => candidate == element)).evaluate().isEmpty) element];
    // 普通档第 2 道是四柱 8 盘，专家档第 1 道是四柱循环 6 盘（底座下有箭头）。
    for (final (tier, seed) in [(PuzzleTier.normal, 2), (PuzzleTier.expert, 1)]) {
      final store = PlaygroundStore.memory();
      await store.chooseTier('hanoi', tier);
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(key: ValueKey(tier), game: _game('hanoi'), store: store, seeds: () => seed)));
      await tester.pumpAndSettle();
      final puzzle = const HanoiRules().generate(seed, tier).puzzle;
      expect(puzzle.pegs, 4);
      expect(tester.takeException(), isNull);
      for (var peg = 0; peg < 4; peg++) {
        final rect = tester.getRect(_peg(peg));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(360));
        expect(rect.width, greaterThanOrEqualTo(72));
      }
      expect(disks, findsNWidgets(puzzle.disks * 2), reason: '棋盘与目标各一套');
      expect(board(), hasLength(puzzle.disks));
      final column = tester.getRect(_peg(0)).width;
      for (final element in board()) {
        final rect = tester.getRect(find.byElementPredicate((candidate) => candidate == element));
        expect(rect.height, lessThanOrEqualTo(32));
        expect(rect.width, lessThan(column));
      }
      final goal = tester.getRect(find.bySemanticsLabel(RegExp('^目标，')));
      expect(goal.right, lessThanOrEqualTo(360));
      final from = _hanoiMove(puzzle, legal: true).from;
      await _tapOn(tester, _peg(from));
      await tester.pumpAndSettle();
      final lifted = [for (final element in board()) tester.getRect(find.byElementPredicate((candidate) => candidate == element)).top].reduce(math.min);
      expect(lifted, greaterThanOrEqualTo(goal.bottom));
    }
    semantics.dispose();
  });

  testWidgets('换难度：走过几步后先确认，确认才换题', (tester) async {
    final semantics = tester.ensureSemantics();
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 2)));
    await tester.pumpAndSettle();
    final draw = const HanoiRules().generate(2, PuzzleTier.entry);
    await _hanoiTap(tester, draw.solution.first);
    await tester.tap(find.widgetWithText(TextButton, '入门'));
    await _step(tester);
    await tester.tap(find.text('专家'));
    await _step(tester);
    expect(find.text('换成专家？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _step(tester);
    expect(find.textContaining('最少 ${draw.solution.length} 步'), findsOneWidget);
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

  // 用时按秒刷新：走着表、棋盘不动时不逐帧出帧（以前用逐帧的计时器，一局开着就一直以屏幕刷新率重画）；秒数照样往前走。
  testWidgets('走表时棋盘不动就不出帧，用时照样按秒刷新', (tester) async {
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    final first = const HanoiRules().generate(1, PuzzleTier.entry).solution.first;
    await _tapOn(tester, _peg(first.from));
    await _step(tester);
    await _tapOn(tester, _peg(first.to));
    // 落盘的动画走完（几帧接力，逐段推进）。
    for (var frame = 0; frame < 3; frame++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.textContaining('1 步'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '走着表也不空转出帧');
    // 用时是真实时间（Stopwatch），等过一秒再推进假时钟，计时器到点刷新状态行。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(RegExp(r'^0:0[1-9]')), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  // 人工决策见 play_frame.dart 的 PlaySession（11-17 19:19:39）：从头来用时接着算、罚时算进成绩、看过答案的题不记成绩，换一道题才清。
  test('从头来不清表、罚时算进成绩、揭开过答案的题不记成绩；换一道题才都清掉', () async {
    final store = PlaygroundStore.memory();
    // 用不按出题计时的登记项（舒尔特，按自己的「开始」），看得出从头来之后表停着、下一步才接着走。
    final session = PlaySession(game: _game('schulte'), rules: const _CountingRules(), store: store, seeds: () => 3);
    expect(session.wrongPenalty, const Duration(seconds: 5), reason: '预计用时 10 秒的四分之一按 5 秒取整，至少 5 秒');
    session.moved();
    session.penalize(const Duration(seconds: 7));
    expect(session.elapsed, greaterThanOrEqualTo(const Duration(seconds: 7)));
    session.restart();
    expect((session.running, session.started, session.penalty), (false, true, const Duration(seconds: 7)));
    // 从头来之后、下一步之前表停着（切回前台也不走）。
    final kept = session.elapsed;
    session
      ..pause()
      ..resume();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(session.elapsed, kept);
    session.moved();
    expect(session.running, isTrue);
    expect(await session.finish(moves: 1), isTrue);
    expect(store.best('schulte', PuzzleTier.entry)!.millis, greaterThanOrEqualTo(7000), reason: '成绩含罚时');
    // 解开后从头来再解一遍：用时只会更长，不刷新纪录。
    session
      ..restart()
      ..moved();
    expect(await session.finish(moves: 1), isFalse);
    // 换一道题：表与罚时清零。踩雷那样揭开过答案的题，从头来再解开不记成绩（刚换的题用时很短，记的话就是新纪录）。
    session.next();
    expect((session.elapsed, session.penalty, session.started, session.spoiled), (Duration.zero, Duration.zero, false, false));
    session
      ..moved()
      ..end(revealed: true)
      ..restart()
      ..moved();
    expect(await session.finish(moves: 1), isFalse);
    expect(session.spoiled, isTrue);
    expect(store.best('schulte', PuzzleTier.entry)!.millis, greaterThanOrEqualTo(7000));
    session.next();
    expect(session.spoiled, isFalse);
    session.dispose();
  });

  // 人工决策见 playground_catalog.dart 文件头与 PlaySession（11-17 20:13:19）：看题就能推理的游戏题一出现就计时，不用等第一步；
  // 换档前确认只看动没动过；从头来表接着走，换一道题从零重走；挑战模式不看它。
  test('题一出现就计时：建好就走表、没动不算动过；从头来接着走，换一道题从零重走，解开才停', () async {
    final session = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: PlaygroundStore.memory(), seeds: () => 3);
    expect((_game('hanoi').clock, session.running, session.started), (PlayClock.sight, true, false));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(session.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 30)), reason: '没走一步表也在走');
    session.moved();
    expect(session.started, isTrue);
    session.restart();
    expect((session.running, session.started), (true, true));
    final before = session.elapsed;
    session.next();
    expect((session.running, session.started), (true, false));
    expect(session.elapsed, lessThan(before));
    await session.finish(moves: 1);
    expect(session.running, isFalse);
    session.restart();
    expect(session.running, isTrue, reason: '解开后从头来，题又摆出来了');
    session.dispose();
    // 扫雷也题一出现就计时（11-17 20:37:07）；只有舒尔特与记忆闪光按自己的「开始」。
    final mines = PlaySession(game: _game('mines'), rules: const _CountingRules(), store: PlaygroundStore.memory(), seeds: () => 3);
    expect(mines.running, isTrue);
    mines.dispose();
    expect({for (final game in playgroundCatalog) if (game.clock != PlayClock.sight) game.id: game.clock}, {'flash': PlayClock.start, 'schulte': PlayClock.start});
  });

  // 人工决策见 PlaySession 上 11-17 20:13:19 那条：自由模式用时（含罚时）不到预计用时的 15% 且不到 30 秒不进最好成绩，同挑战加试题的门槛；
  // 舒尔特与记忆闪光不套。测试里默认关着（test/flutter_test_config.dart），这里打开。
  test('快得不正常的不记纪录：不到预计用时 15% 且不到 30 秒不记，罚时算在用时里，认真解的照记，舒尔特与记忆闪光不套', () async {
    PlaySession.tooFastGuard = true;
    addTearDown(() => PlaySession.tooFastGuard = false);
    expect((playTooFastRatio, playTooFastFloor), (.15, const Duration(seconds: 30)), reason: '同挑战 challenge/config.json 的 extraRatio 与 extraFloor');
    final store = PlaygroundStore.memory();
    // 预计用时 10 秒的题：门槛是 1.5 秒。
    final session = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: store, seeds: () => 3);
    session.moved();
    expect(await session.finish(moves: 1), isFalse);
    expect((session.tooFast, store.best('hanoi', PuzzleTier.entry)), (true, null));
    session.restart();
    expect(session.tooFast, isFalse);
    // 罚时算在用时里：手上很快、罚过 5 秒的照记。
    session
      ..next()
      ..moved()
      ..penalize(const Duration(seconds: 5));
    expect(await session.finish(moves: 1), isTrue);
    expect(session.tooFast, isFalse);
    // 认真想了 1.6 秒（过了门槛）：照记，比罚过时的那次快就是新纪录。
    session.next();
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    session.moved();
    expect(await session.finish(moves: 1), isTrue);
    expect(store.best('hanoi', PuzzleTier.entry)!.millis, inInclusiveRange(1500, 5000));
    session.dispose();
    for (final id in ['schulte', 'flash']) {
      final quick = PlaySession(game: _game(id), rules: const _CountingRules(), store: store, seeds: () => 3);
      quick.moved();
      expect(await quick.finish(moves: 1), isTrue, reason: '$id 拼的就是快，不套门槛');
      quick.dispose();
    }
  });

  testWidgets('题一出现就计时：汉诺塔与扫雷打开不动也在走表', (tester) async {
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    // 用时是真实时间（Stopwatch），等过一秒再推进假时钟，计时器到点刷新状态行。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(RegExp(r'^0:0[1-9]')), findsOneWidget, reason: '汉诺塔没走一步也在走表');
    expect(find.textContaining('0 步'), findsOneWidget);
    // 还没动过：换难度不用确认。
    await tester.tap(find.widgetWithText(TextButton, '入门'));
    await _step(tester);
    await tester.tap(find.text('简单'));
    await _step(tester);
    expect(find.text('换成简单？'), findsNothing);

    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: MinesPage(key: UniqueKey(), game: _game('mines'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1100)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining(RegExp(r'^0:0[1-9]')), findsOneWidget, reason: '扫雷起点那片已经翻开，打开不动也在走表');
  });

  // [人工决策-2026-11-17 21:24:25] 见 play_frame.dart 的状态行：放不下时整项换到档位下面一行，不在档位旁边折成两三行；
  // 会罚时的游戏一直留着「+N 秒」的位置（设计审查 P1-1：以前插进状态行，整行重排、棋盘在手指下跳）。
  testWidgets('状态行：窄屏大字号放不下时整项换到档位下面一行、只占一行，宽屏跟在档位后面；「+N 秒」出现收起、步数从 9 到 10 都不挪棋盘与状态', (tester) async {
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await loadCampusFonts(tester);
    final board = GlobalKey();
    final status = find.byType(DotSeparatedText), tier = find.byType(TextButton).first;
    bool stacked() => tester.getTopLeft(status).dy >= tester.getBottomLeft(tier).dy - 1;
    Widget frame(PlaySession<Object?, Object?> session, String line, String key) => MaterialApp(theme: campusTheme(), home: PlayFrame(key: ValueKey(key), session: session, board: SizedBox.expand(key: board), onNewGame: (_) {}, onRestart: () {}, status: line));
    // 记忆闪光的状态长：放不放得下按数字至少两位量，411dp 标准字号也排在下一行（宁可多占一行，也不在点错 9 次到 10 次时整块跳）。
    for (final (game, line, grown, width, scale, expectStacked) in [
      ('knights', '已定 0/3', null, 360.0, 1.3, true),
      ('flash', '第 1/5 轮 · 点错 0 次', '第 1/5 轮 · 点错 10 次', 360.0, 1.3, true),
      ('knights', '已定 0/3', null, 411.0, 1.0, false),
      ('hanoi', '9 步 · 最少 15 步', '10 步 · 最少 15 步', 411.0, 1.0, false),
      ('flash', '第 1/5 轮 · 点错 9 次', '第 1/5 轮 · 点错 10 次', 411.0, 1.0, true),
    ]) {
      final reason = '$game ${width.toInt()}dp ×$scale';
      tester.view.physicalSize = Size(width * 2, 1600);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      final session = PlaySession(game: _game(game), rules: challengeRules[game]!, store: PlaygroundStore.memory(), seeds: () => 1);
      await tester.pumpWidget(frame(session, line, reason));
      await tester.pump();
      expect(stacked(), expectStacked, reason: reason);
      expect(tester.getSize(status).height, lessThan(14 * scale * 1.8), reason: '$reason：状态只占一行');
      final boardTop = tester.getTopLeft(find.byKey(board)).dy, statusTop = tester.getTopLeft(status);
      Object placed() => (tester.getTopLeft(find.byKey(board)).dy, tester.getTopLeft(status), stacked());
      if (game == 'knights') {
        session.penalize(const Duration(seconds: 15));
        await tester.pump();
        expect(find.text('+15 秒'), findsOneWidget, reason: reason);
        expect(placed(), (boardTop, statusTop, expectStacked), reason: '$reason：罚时出现不挪棋盘与状态');
        await tester.pump(const Duration(seconds: 2));
        expect(find.text('+15 秒'), findsNothing, reason: reason);
        expect(placed(), (boardTop, statusTop, expectStacked), reason: '$reason：罚时收起不挪棋盘与状态');
      }
      if (grown != null) {
        await tester.pumpWidget(frame(session, grown, reason));
        await tester.pump();
        expect(placed(), (boardTop, statusTop, expectStacked), reason: '$reason：数字多一位不换排法');
        expect(tester.getSize(status).height, lessThan(14 * scale * 1.8), reason: '$reason：多一位也只占一行');
      }
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    }
  });

  // 作弊机器人：解开以后从头来，照着刚才的走法飞快再走一遍。以前从头来把表清零，这一遍的几秒就成了新纪录。
  testWidgets('解开后从头来照着走一遍：用时接着算，不刷新纪录', (tester) async {
    final store = PlaygroundStore.memory();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1)));
    await tester.pumpAndSettle();
    final moves = const HanoiRules().generate(1, PuzzleTier.entry).solution;
    // 第一遍边走边想：走了第一步后过了 1.5 秒（真实时间，用时按 Stopwatch 算），再走完，记下纪录。
    await _hanoiTap(tester, moves.first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1500)));
    for (final move in moves.skip(1)) {
      await _hanoiTap(tester, move);
    }
    await tester.pumpAndSettle();
    expect(find.text('新纪录'), findsOneWidget);
    final best = store.best('hanoi', PuzzleTier.entry)!.millis;
    expect(best, greaterThanOrEqualTo(1500));
    // 关掉结果、从头来，照着走一遍（几乎不花真实时间）。
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这一题从头来'));
    await tester.pumpAndSettle();
    expect(find.textContaining(RegExp(r'^0:0[1-9]')), findsOneWidget, reason: '从头来不清表');
    for (final move in moves) {
      await _hanoiTap(tester, move);
    }
    await tester.pumpAndSettle();
    expect(find.text('新纪录'), findsNothing);
    expect(find.text('解开了'), findsOneWidget);
    expect(store.best('hanoi', PuzzleTier.entry)!.millis, best);
  });

  // 专家档出一道题要几十到上百毫秒：下一道题先在另一个 isolate 里出好，换题时直接用，界面线程不再出题。
  test('自由模式的下一道题先在后台出好：换一道题、换到下一档直接用出好的，没备的档当场出', () async {
    _generatedHere = 0;
    final session = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: PlaygroundStore.memory());
    expect(_generatedHere, 1, reason: '第一道题当场出');
    await session.upcoming(PuzzleTier.entry);
    session.next();
    expect(_generatedHere, 1, reason: '换一道题用后台出好的');
    expect(session.puzzle, session.seed);
    final finished = await session.finish(moves: 1);
    expect(finished, isTrue);
    await session.upcoming(PuzzleTier.easy);
    session.next(tier: PuzzleTier.easy);
    expect(_generatedHere, 1, reason: '换到下一档也用后台出好的');
    session.next(tier: PuzzleTier.expert);
    expect(_generatedHere, 2, reason: '没备的档当场出');
    expect(session.upcoming(PuzzleTier.expert), isNotNull);
    session.dispose();

    // 测试注入种子与不能进挑战的游戏（画线入杯用原生物理世界）都当场出、不备。
    final seeded = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: PlaygroundStore.memory(), seeds: () => 7);
    expect(seeded.upcoming(PuzzleTier.entry), isNull);
    final pour = PlaySession(game: _game('pour'), rules: const _CountingRules(), store: PlaygroundStore.memory());
    expect(pour.upcoming(PuzzleTier.entry), isNull);
  });

  // 人工决策见 playground_page.dart 的 PlaygroundGameHost：第一道题也在后台出，外壳读好本机记录就出，出好交给对局页。
  test('外壳出好的第一道题：档位对得上就用，对不上当场出', () {
    _generatedHere = 0;
    final store = PlaygroundStore.memory();
    final used = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: store, first: (seed: 5, tier: PuzzleTier.entry, draw: const PuzzleDraw<int, int>(5, 5)));
    expect(_generatedHere, 0);
    expect((used.puzzle, used.seed), (5, 5));
    final skipped = PlaySession(game: _game('hanoi'), rules: const _CountingRules(), store: store, first: (seed: 5, tier: PuzzleTier.expert, draw: const PuzzleDraw<int, int>(5, 5)));
    expect(_generatedHere, 1, reason: '档位对不上当场出');
    expect(skipped.puzzle, skipped.seed);
    used.dispose();
    skipped.dispose();
  });

  testWidgets('外壳读好本机记录就在后台出第一道题交给对局页（等的时候已有顶栏）；后台迟迟没出好就由对局页当场出；画线入杯不备', (tester) async {
    final store = PlaygroundStore.memory();
    Widget host(String id) => MaterialApp(theme: campusTheme(), home: PlaygroundGameHost(key: ValueKey(id), game: _game(id), store: store));
    await tester.pumpWidget(host('hanoi'));
    await tester.pump();
    expect(find.text('正在准备'), findsOneWidget);
    // 等题时就有同对局页的顶栏：返回与游戏名（11-17 设计审查）。
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.descendant(of: find.byType(AppBar), matching: find.text('汉诺塔')), findsOneWidget);
    // 另一个 isolate 按真实时间出题：让出真实的事件循环等它回来。
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await tester.pump();
    await tester.pump();
    expect(tester.widget<HanoiPage>(find.byType(HanoiPage)).first, isNotNull);

    // 假时钟里另一个 isolate 回不来：等满 firstPatience 就由对局页当场出。
    await tester.pumpWidget(host('nonogram'));
    await tester.pump();
    expect(find.byType(NonogramPage), findsNothing);
    await tester.pump(PlaygroundGameHost.firstPatience);
    await tester.pump();
    expect(tester.widget<NonogramPage>(find.byType(NonogramPage)).first, isNull);

    await tester.pumpWidget(host('pour'));
    await tester.pump();
    expect(find.text('正在准备'), findsNothing);
    await tester.pumpWidget(const SizedBox());
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

  // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）约 18dp 就认横向拖动：棋盘上的拖动必须归棋盘，
  // 不然数织横着涂、汉诺塔往右拖盘子时整页跟着滑走。
  testWidgets('iOS 上棋盘里的横向拖动归棋盘：数织横着涂一行、汉诺塔往右拖盘子，都不触发右滑返回', (tester) async {
    final semantics = tester.ensureSemantics();
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final store = PlaygroundStore.memory();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));

    Future<void> dragRight(Offset from, Offset to) async {
      final gesture = await tester.startGesture(from);
      final steps = ((to.dx - from.dx) / 12).ceil();
      for (var step = 0; step < steps; step++) {
        await gesture.moveBy(Offset((to.dx - from.dx) / steps, 0));
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
    }

    unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => NonogramPage(game: _game('nonogram'), store: store, seeds: () => 3))));
    await tester.pumpAndSettle();
    await dragRight(tester.getCenter(_cell(1, 0)), tester.getCenter(_cell(1, 4)));
    expect(tester.getTopLeft(find.byType(NonogramPage)).dx, 0);
    for (var column = 0; column < 5; column++) {
      expect(find.bySemanticsLabel('第2行第${column + 1}列，已涂'), findsOneWidget);
    }
    navigator.currentState!.pop();
    await tester.pumpAndSettle();

    unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => HanoiPage(game: _game('hanoi'), store: store, seeds: () => 1))));
    await tester.pumpAndSettle();
    final right = _hanoiMove(const HanoiRules().generate(1, PuzzleTier.entry).puzzle, legal: true, rightward: true);
    await dragRight(tester.getCenter(_peg(right.from)), tester.getCenter(_peg(right.to)));
    expect(tester.getTopLeft(find.byType(HanoiPage)).dx, 0);
    expect(find.textContaining('1 步'), findsOneWidget);
    semantics.dispose();
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

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

// 数一数这个 isolate 里出了几道题（顶层变量每个 isolate 各一份，后台 isolate 里出的不算在这里）。
var _generatedHere = 0;

// 题面与参考解就是种子，出一道记一次。
class _CountingRules extends PuzzleRules<int, int> {
  const _CountingRules();

  @override
  PuzzleDraw<int, int> generate(int seed, PuzzleTier tier) {
    _generatedHere++;
    return PuzzleDraw(seed, seed);
  }

  @override
  bool solved(int puzzle, int answer) => puzzle == answer;
  @override
  int complexity(int puzzle) => 1;
  @override
  int expectedSeconds(int puzzle) => 10;
  @override
  Object encodePuzzle(int puzzle) => puzzle;
  @override
  int decodePuzzle(Object? json) => json! as int;
  @override
  Object encodeAnswer(int answer) => answer;
  @override
  int decodeAnswer(Object? json) => json! as int;
}
