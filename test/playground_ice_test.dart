import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/ice/ice_page.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

const _rules = IceRules();
const _labels = ['向上滑', '向右滑', '向下滑', '向左滑'];

// 手搭的 5×3 小图（S 起点、G 终点、# 岩石），只有岩石：
// S . G . .
// . . . . .
// . . . # .
// 朝右会滑过终点停在右上角；最短是下、右、上三步。
Map<String, Object?> _smallJson([Map<String, Object?> change = const {}]) => {'width': 5, 'height': 3, 'tiles': '000000000000010', 'gems': <int>[], 'start': 0, 'goal': 2, 'limit': 6, ...change};
final _small = _rules.decodePuzzle(_smallJson());

// 手搭的 5×4 机关图（* 雪地、~ 薄冰、o 冰洞、# 岩石、g 宝石）：
// S . * . .
// . ~ . o .
// . . . . G
// # . g . .
final _traps = _rules.decodePuzzle({'width': 5, 'height': 4, 'tiles': '00200040300000010000', 'gems': [17], 'start': 0, 'goal': 14, 'limit': 20});

// 每档的边长、最少步数区间、上限比最少多几步、难易分段与乱走成功率上限（同 ice_rules.dart 的 _plans 与 iceDifficulty）。
const _bands = {
  PuzzleTier.entry: (side: 6, least: (3, 5), slack: 4, score: (1, 2), odds: 1.0),
  PuzzleTier.easy: (side: 7, least: (5, 7), slack: 2, score: (3, 4), odds: 1.0),
  PuzzleTier.normal: (side: 8, least: (7, 10), slack: 1, score: (5, 6), odds: .02),
  PuzzleTier.hard: (side: 10, least: (9, 14), slack: 0, score: (7, 8), odds: .001),
  PuzzleTier.expert: (side: 12, least: (12, 20), slack: 0, score: (9, 10), odds: .0001),
};

String _place(IcePuzzle puzzle, int cell) => '第${cell ~/ puzzle.width + 1}行第${cell % puzzle.width + 1}列';

Finder get _board => find.bySemanticsLabel(RegExp('^冰面')).first;
// 状态行按「 · 」分项排（DotSeparatedText），每项单独一段文字：步数那一项以「3/7 步」开头。
Finder _steps(int count, int limit) => find.textContaining(RegExp('^$count/$limit 步'));
Finder _key(int direction) => find.descendant(of: find.byTooltip(_labels[direction]), matching: find.byType(FilledButton));

int? _without(IcePuzzle puzzle, IceTile tile) => iceMinMoves(puzzle.copyWith(tiles: [for (final each in puzzle.tiles) each == tile ? IceTile.ice : each]));

// 找一个这一档的种子，让开局满足条件（固定种子出的题固定，测试可重复）。
int _seedWhere(bool Function(IcePuzzle puzzle) test, [PuzzleTier tier = PuzzleTier.entry]) {
  for (var seed = 0;; seed++) {
    if (test(_rules.generate(seed, tier).puzzle)) return seed;
  }
}

// 从起点朝哪个方向：滑得动（moves 为真）或滑不动的第一个；falls 为真时找掉进冰洞的。
int? _direction(IcePuzzle puzzle, {bool moves = true, bool falls = false}) {
  final at = IceState(puzzle.start);
  for (var direction = 0; direction < iceDirections; direction++) {
    final to = iceMove(puzzle, at, direction);
    if (falls ? to.fallen : (!identical(to, at)) == moves && !to.fallen) return direction;
  }
  return null;
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时按帧推进一段（滑行最长 300ms 加撞停 160ms，沉下去 420ms）。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<PlaygroundStore> _open(WidgetTester tester, int seed, [PuzzleTier tier = PuzzleTier.entry]) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('ice', tier);
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: _page(store, seed)));
  await tester.pumpAndSettle();
  return store;
}

IcePage _page(PlaygroundStore store, int seed) => IcePage(game: playgroundCatalog.firstWhere((game) => game.id == 'ice'), store: store, seeds: () => seed);

void main() {
  group('规则', () {
    test('滑到撞上岩石或边界才停，紧挨着就是原地；只有岩石的小图最少三步', () {
      int slide(IcePuzzle puzzle, int cell, int direction) => iceMove(puzzle, IceState(cell), direction).cell;
      expect(slide(_small, 0, iceRight), 4);
      expect(slide(_small, 0, iceDown), 10);
      final at = IceState(0);
      expect(iceMove(_small, at, iceUp), same(at));
      expect(iceMove(_small, at, iceLeft), same(at));
      expect(slide(_small, 10, iceRight), 12);
      expect(slide(_small, 12, iceUp), 2);
      expect(iceMinMoves(_small), 3);
      expect(iceSolution(_small), [iceDown, iceRight, iceUp]);
    });

    test('雪地滑进去就停；冰洞掉下去；宝石滑过或停上去都收走；薄冰滑过就碎，再进去掉下去', () {
      IceState move(int cell, int direction, {int gems = 0, int broken = 0}) => iceMove(_traps, IceState(cell, gems: gems, broken: broken), direction);
      // 雪地：朝右滑进第 0 行的雪就停在雪上；从右往左滑回来同样停在雪上。
      expect(move(0, iceRight).cell, 2);
      expect(move(4, iceLeft).cell, 2);
      // 从雪地出发照常滑：一路滑到底边停在宝石上，收走它。
      expect((move(2, iceDown).cell, move(2, iceDown).gems), (17, 1));
      // 滑过宝石也收：从第 3 行第 2 列往右滑到边。
      expect((move(16, iceRight).cell, move(16, iceRight).gems), (19, 1));
      // 冰洞：从第 0 行第 3 列往下，第一格就是洞。
      final fall = move(3, iceDown);
      expect((fall.cell, fall.fallen), (8, true));
      // 薄冰：从第 0 行第 1 列往下滑过薄冰到底边，薄冰记成碎了；再往上滑回去就掉进它碎成的洞。
      final across = move(1, iceDown);
      expect((across.cell, across.broken, across.fallen), (16, 1, false));
      final back = iceMove(_traps, across, iceUp);
      expect((back.cell, back.fallen), (6, true));
      // 没碎过的薄冰照样滑过。
      expect(move(16, iceUp).cell, 1);
    });

    test('解开要收齐宝石再停在终点：不收宝石的近路、滑过终点、掉进冰洞、超了步数上限都不算；滑不动的那步也算一步', () {
      // 不管宝石的话下、右两步就到；有宝石就得绕：右到雪、下到宝石、上回雪、左回起点、下、右。
      expect(iceMinMoves(_traps.copyWith(gems: const [])), 2);
      expect(_rules.solved(_traps, [iceDown, iceRight]), isFalse);
      expect(_rules.solved(_traps.copyWith(gems: const []), [iceDown, iceRight]), isTrue);
      const detour = [iceRight, iceDown, iceUp, iceLeft, iceDown, iceRight];
      expect(_rules.solved(_traps, detour), isTrue);
      expect(iceMinMoves(_traps), lessThanOrEqualTo(detour.length));
      final reference = iceSolution(_traps)!;
      expect(reference, hasLength(iceMinMoves(_traps)!));
      expect(_rules.solved(_traps, reference), isTrue);
      // 掉进冰洞：右到雪、右到边、下到底、左滑过宝石、上滑过薄冰，再下就掉进它碎成的洞；之后再怎么走都不算。
      const sink = [iceRight, iceRight, iceDown, iceLeft, iceUp, iceDown];
      final fallen = iceReplay(_traps, sink);
      expect((fallen.cell, fallen.gems, fallen.fallen), (6, 1, true));
      expect(_rules.solved(_traps, [...sink, ...detour]), isFalse);
      // 小图：滑过终点、停上去又离开都不算；上限内绕路也算；滑不动的那步也算进步数。
      expect(_rules.solved(_small, [iceRight]), isFalse);
      expect(_rules.solved(_small, const []), isFalse);
      expect(_rules.solved(_small, [iceDown, iceRight, iceUp]), isTrue);
      expect(_rules.solved(_small, [iceDown, iceRight, iceUp, iceRight]), isFalse);
      expect(_rules.solved(_small, [iceUp, iceLeft, iceDown, iceRight, iceRight, iceUp]), isTrue);
      expect(_rules.solved(_small, [iceUp, iceLeft, iceUp, iceDown, iceRight, iceRight, iceUp]), isFalse);
      expect(_rules.solved(_small.copyWith(limit: 3), [iceDown, iceRight, iceUp]), isTrue);
      expect(_rules.solved(_small.copyWith(limit: 3), [iceUp, iceDown, iceRight, iceUp]), isFalse);
    });

    test('乱走成功率：每步在滑得动又不掉下去的方向里等可能地挑，逐步精确累加', () {
      // 3×3 全是冰面，左上起点、右上终点：第一步右（到）或下各一半；下去以后上、右各一半都不到；第三步再各有 1/8 到。
      final open = _rules.decodePuzzle({'width': 3, 'height': 3, 'tiles': '000000000', 'gems': <int>[], 'start': 0, 'goal': 2, 'limit': 1});
      expect(iceWanderOdds(open), .5);
      expect(iceWanderOdds(open.copyWith(limit: 2)), .5);
      expect(iceWanderOdds(open.copyWith(limit: 3)), .75);
      // 起点正下方是冰洞：乱走的人不往洞里滑，只剩向右，一步就到。
      final holed = _rules.decodePuzzle({'width': 3, 'height': 3, 'tiles': '000300000', 'gems': <int>[], 'start': 0, 'goal': 2, 'limit': 1});
      expect(iceWanderOdds(holed), 1.0);
      // 同一道题算出的数一样。
      final hard = _rules.generate(5, PuzzleTier.hard).puzzle;
      expect(iceWanderOdds(hard), iceWanderOdds(_rules.decodePuzzle(_rules.encodePuzzle(hard))));
    });

    test('每档 20 道：边长与逐档加的机制、最少步数落在区间、上限 = 最少 + 这一档的余量、机制都起作用、乱走成功率压在上限下、难易分落在本档分段，出题快', () {
      var generating = 0;
      for (final tier in PuzzleTier.values) {
        final band = _bands[tier]!;
        for (var seed = 0; seed < 20; seed++) {
          final watch = Stopwatch()..start();
          final draw = _rules.generate(seed, tier);
          generating += watch.elapsedMilliseconds;
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          final kinds = puzzle.tiles.toSet();
          expect((puzzle.width, puzzle.height), (band.side, band.side), reason: reason);
          expect(kinds.contains(IceTile.snow), tier != PuzzleTier.entry, reason: reason);
          expect(kinds.contains(IceTile.hole), tier.index >= PuzzleTier.normal.index, reason: reason);
          expect(puzzle.gems.length, inInclusiveRange(switch (tier) { PuzzleTier.hard => 1, PuzzleTier.expert => 2, _ => 0 }, switch (tier) { PuzzleTier.hard => 2, PuzzleTier.expert => 3, _ => 0 }), reason: reason);
          expect(puzzle.thin.length, tier == PuzzleTier.expert ? inInclusiveRange(4, iceMaxThin) : 0, reason: reason);
          expect(puzzle.tiles[puzzle.start], IceTile.ice, reason: reason);
          expect([IceTile.ice, IceTile.snow], contains(puzzle.tiles[puzzle.goal]), reason: reason);
          final least = iceMinMoves(puzzle)!;
          expect(least, inInclusiveRange(band.least.$1, band.least.$2), reason: reason);
          expect(puzzle.limit, least + band.slack, reason: reason);
          expect(draw.solution.length, least, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          expect(_rules.solved(puzzle, draw.solution.sublist(0, least - 1)), isFalse, reason: reason);
          // 新加的机制真起作用：雪地换回冰面最少步数会变，宝石拿掉、薄冰换回冰面都会更少。
          if (kinds.contains(IceTile.snow)) expect(_without(puzzle, IceTile.snow), isNot(least), reason: reason);
          if (puzzle.gems.isNotEmpty) expect(iceMinMoves(puzzle.copyWith(gems: const []))!, lessThan(least), reason: reason);
          if (puzzle.thin.isNotEmpty) expect(_without(puzzle, IceTile.thin)!, lessThan(least), reason: reason);
          expect(iceWanderOdds(puzzle), lessThanOrEqualTo(band.odds), reason: reason);
          expect(_rules.complexity(puzzle), inInclusiveRange(band.score.$1, band.score.$2), reason: reason);
          expect(jsonEncode(_rules.encodePuzzle(_rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(puzzle)))))), jsonEncode(_rules.encodePuzzle(puzzle)), reason: reason);
        }
      }
      expect(generating, lessThan(2000));
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(7, PuzzleTier.hard).puzzle)), jsonEncode(_rules.encodePuzzle(_rules.generate(7, PuzzleTier.hard).puzzle)));
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(7, PuzzleTier.hard).puzzle)), isNot(jsonEncode(_rules.encodePuzzle(_rules.generate(8, PuzzleTier.hard).puzzle))));
    });

    test('预计用时逐档明显上升（中位数约 40、70、110、170、260 秒）', () {
      final medians = [
        for (final tier in PuzzleTier.values)
          ([for (var seed = 1; seed <= 15; seed++) _rules.expectedSeconds(_rules.generate(seed * 7919, tier).puzzle)]..sort())[7],
      ];
      for (final (index, (low, high)) in [(30, 55), (55, 90), (85, 140), (130, 220), (210, 330)].indexed) {
        expect(medians[index], inInclusiveRange(low, high), reason: '$medians');
      }
    });

    test('挑战的出口：最少步数都同终点（步数上限对哪个出口都对），不压起点与宝石、互相隔开两格以上', () {
      for (final tier in [PuzzleTier.normal, PuzzleTier.expert]) {
        for (var seed = 0; seed < 6; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          final exits = iceExits(puzzle, PuzzleRandom(seed));
          expect(exits, contains(puzzle.goal));
          for (final exit in exits) {
            expect(iceMinMoves(puzzle.copyWith(goal: exit)), iceMinMoves(puzzle));
            expect(exit == puzzle.start || puzzle.gems.contains(exit), isFalse);
            for (final other in exits.where((other) => other != exit)) {
              expect((exit ~/ puzzle.width - other ~/ puzzle.width).abs() + (exit % puzzle.width - other % puzzle.width).abs(), greaterThanOrEqualTo(2));
            }
          }
          if (exits.length >= 2) expect(_rules.decodePuzzle(_rules.encodePuzzle(puzzle.copyWith(exits: exits))).exits, exits);
        }
      }
    });

    test('编解码往返，坏题面与坏答案抛 FormatException', () {
      final draw = _rules.generate(3, PuzzleTier.expert);
      final puzzle = _rules.decodePuzzle(_rules.encodePuzzle(draw.puzzle));
      expect(jsonEncode(_rules.encodePuzzle(puzzle)), jsonEncode(_rules.encodePuzzle(draw.puzzle)));
      expect(_rules.solved(puzzle, _rules.decodeAnswer(_rules.encodeAnswer(draw.solution))), isTrue);
      for (final broken in [
        _smallJson({'tiles': '00000000000001'}),
        _smallJson({'tiles': '000000000000015'}),
        _smallJson({'tiles': 15}),
        _smallJson({'start': 13}),
        _smallJson({'tiles': '300000000000010'}),
        _smallJson({'tiles': '200000000000010'}),
        _smallJson({'goal': 13}),
        _smallJson({'tiles': '003000000000010'}),
        _smallJson({'tiles': '004000000000010'}),
        _smallJson({'goal': 0}),
        _smallJson({'goal': 15}),
        _smallJson({'gems': [13]}),
        _smallJson({'gems': [0]}),
        _smallJson({'gems': [2]}),
        _smallJson({'gems': [5, 3]}),
        _smallJson({'gems': [3, 3]}),
        _smallJson({'gems': [3, 5, 6, 7]}),
        _smallJson({'gems': null}),
        _smallJson({'tiles': '044444440000010'}),
        _smallJson({'limit': 0}),
        _smallJson({'limit': iceMaxMoves + 1}),
        _smallJson({'limit': 2}),
        _smallJson({'tiles': '000000010000010'}),
        _smallJson({'exits': [2]}),
        _smallJson({'exits': [0, 2]}),
        _smallJson({'exits': [2, 2]}),
        _smallJson({'exits': [4, 10]}),
        _smallJson({'exits': [2, 13]}),
        _smallJson({'gems': [4], 'exits': [2, 4]}),
        _smallJson({'width': 2}),
        _smallJson({'height': iceMaxSide + 1}),
        _smallJson({'start': '0'}),
      ]) {
        expect(() => _rules.decodePuzzle(broken), throwsFormatException, reason: '$broken');
      }
      expect(_rules.decodePuzzle(_smallJson({'gems': [4], 'limit': 8})).gems, [4]);
      expect(() => _rules.decodePuzzle('冰面'), throwsFormatException);
      expect(() => _rules.decodeAnswer([4]), throwsFormatException);
      expect(() => _rules.decodeAnswer([-1]), throwsFormatException);
      expect(() => _rules.decodeAnswer([0, '1']), throwsFormatException);
      expect(() => _rules.decodeAnswer('0123'), throwsFormatException);
      expect(() => _rules.decodeAnswer(List.filled(iceMaxMoves + 1, 0)), throwsFormatException);
    });
  });

  group('对局页', () {
    testWidgets('方向键：滑不动不算步数，撤销退回，按参考解走完弹出新纪录，换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere((puzzle) => _direction(puzzle, moves: false) != null && _direction(puzzle) != null);
      final draw = _rules.generate(seed, PuzzleTier.entry);
      final puzzle = draw.puzzle, limit = puzzle.limit;
      final store = await _open(tester, seed);
      expect(_steps(0, limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，终点在${_place(puzzle, puzzle.goal)}')), findsOneWidget);
      for (final label in _labels) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      // 紧挨着墙的方向：不算步数，位置不变。
      await tester.tap(find.byTooltip(_labels[_direction(puzzle, moves: false)!]));
      await _frames(tester, 300);
      expect(_steps(0, limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，')), findsOneWidget);
      // 滑得动的方向：一步，位置换到停下的那格；撤销回到起点。
      final moving = _direction(puzzle)!;
      await tester.tap(find.byTooltip(_labels[moving]));
      await _frames(tester, 500);
      expect(_steps(1, limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, iceMove(puzzle, IceState(puzzle.start), moving).cell)}，')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 300);
      expect(_steps(0, limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，')), findsOneWidget);

      for (final direction in draw.solution) {
        await tester.tap(find.byTooltip(_labels[direction]));
        await _frames(tester, 500);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('${draw.solution.length} 步，正好最少'), findsOneWidget);
      expect(store.best('ice', PuzzleTier.entry)!.moves, draw.solution.length);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('ice'), PuzzleTier.easy);
      expect(find.bySemanticsLabel(RegExp('^冰面 7×7')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^0/\d+ 步')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('在棋盘上滑动推动棋子，四个方向都认', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere((puzzle) => iceSolution(puzzle)!.toSet().length == iceDirections);
      final draw = _rules.generate(seed, PuzzleTier.entry);
      await _open(tester, seed);
      // 按出题的参考解逐步滑（这道题的最短走法上下左右都用到）：每一步都朝那个方向在棋盘上划一下。
      const swipes = [Offset(0, -60), Offset(60, 0), Offset(0, 60), Offset(-60, 0)];
      for (final (index, direction) in draw.solution.indexed) {
        await tester.dragFrom(tester.getCenter(_board), swipes[direction]);
        await _frames(tester, 500);
        if (index < draw.solution.length - 1) expect(_steps(index + 1, draw.puzzle.limit), findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）也认横向移动：棋盘上的横滑必须归棋盘，别处的右滑照常返回。
    testWidgets('iOS 上棋盘里横滑推动棋子、不触发右滑返回，棋盘外右滑照常返回', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedWhere((puzzle) {
        final at = IceState(puzzle.start), to = iceMove(puzzle, at, iceRight);
        return !identical(to, at) && to.cell != puzzle.goal;
      });
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
      unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => _page(store, seed))));
      await tester.pumpAndSettle();

      final board = tester.getCenter(_board);
      final gesture = await tester.startGesture(board);
      for (var step = 0; step < 8; step++) {
        await gesture.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      await gesture.up();
      await _frames(tester, 500);
      expect(find.byType(IcePage), findsOneWidget);
      expect(tester.getTopLeft(find.byType(IcePage)).dx, 0);
      expect(_steps(1, puzzle.limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, iceMove(puzzle, IceState(puzzle.start), iceRight).cell)}，')), findsOneWidget);

      // 方向键左边的空白处右滑：返回上一页。
      final width = tester.getSize(find.byType(MaterialApp)).width;
      final beside = tester.getCenter(find.byTooltip('向左滑')) - const Offset(80, 0);
      await tester.timedDragFrom(beside, Offset(width * .7, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(IcePage), findsNothing);
      expect(find.text('上一页'), findsOneWidget);
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('减少动画时直接到位：最后一步停上终点，不放滑行与跳一下，马上弹结果', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final seed = _seedWhere((_) => true);
      final solution = _rules.generate(seed, PuzzleTier.entry).solution;
      await _open(tester, seed);
      for (final direction in solution) {
        await tester.tap(find.byTooltip(_labels[direction]));
        await tester.pump();
      }
      // 正常动画下这时还在滑行或在终点上跳（滑行加撞停至少 240ms、跳一下 760ms）。
      await _frames(tester, 200);
      expect(find.text('新纪录'), findsOneWidget);
    });

    testWidgets('掉进冰洞：状态行写明并播报、方向键停用、多出从头来；撤销回到洞前，从头来回到起点', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere((puzzle) => _direction(puzzle, falls: true) != null, PuzzleTier.normal);
      final puzzle = _rules.generate(seed, PuzzleTier.normal).puzzle;
      await _open(tester, seed, PuzzleTier.normal);
      expect(find.text('这一题从头来'), findsNothing);
      final fall = _direction(puzzle, falls: true)!;
      await tester.tap(find.byTooltip(_labels[fall]));
      await _frames(tester, 900);
      expect(find.textContaining('掉进冰洞了'), findsOneWidget);
      expect(find.bySemanticsLabel('掉进冰洞了'), findsOneWidget);
      for (var direction = 0; direction < iceDirections; direction++) {
        expect(tester.widget<FilledButton>(_key(direction)).onPressed, isNull);
      }
      // 滑也不动。
      await tester.dragFrom(tester.getCenter(_board), const Offset(0, -60));
      await _frames(tester, 300);
      expect(find.textContaining('掉进冰洞了'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 400);
      expect(_steps(0, puzzle.limit), findsOneWidget);
      expect(find.bySemanticsLabel('掉进冰洞了'), findsNothing);
      expect(tester.widget<FilledButton>(_key(fall)).onPressed, isNotNull);

      await tester.tap(find.byTooltip(_labels[fall]));
      await _frames(tester, 900);
      await tester.tap(find.widgetWithText(FilledButton, '这一题从头来'));
      await _frames(tester, 100);
      expect(_steps(0, puzzle.limit), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，')), findsOneWidget);
      expect(find.text('这一题从头来'), findsNothing);
      semantics.dispose();
    });

    testWidgets('步数用完还没到：状态行写明、方向键停用；撤销一步又能走', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere((_) => true);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      await _open(tester, seed);
      // 每步挑第一个滑得动、又不会停上终点的方向，走满上限。
      var state = IceState(puzzle.start);
      for (var step = 0; step < puzzle.limit; step++) {
        final direction = [for (var direction = 0; direction < iceDirections; direction++) direction].firstWhere((direction) {
          final to = iceMove(puzzle, state, direction);
          return !identical(to, state) && !iceArrived(puzzle, to);
        });
        state = iceMove(puzzle, state, direction);
        await tester.tap(find.byTooltip(_labels[direction]));
        await _frames(tester, 500);
      }
      expect(find.textContaining('步数用完了'), findsOneWidget);
      expect(find.bySemanticsLabel('步数用完了'), findsOneWidget);
      expect(tester.widget<FilledButton>(_key(iceUp)).onPressed, isNull);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 400);
      expect(_steps(puzzle.limit - 1, puzzle.limit), findsOneWidget);
      expect(find.text('这一题从头来'), findsNothing);
      semantics.dispose();
    });

    testWidgets('困难档：状态行写还剩几颗宝石、读屏读宝石在哪，按参考解收齐后停上终点弹新纪录', (tester) async {
      final semantics = tester.ensureSemantics();
      final draw = _rules.generate(2, PuzzleTier.hard);
      final puzzle = draw.puzzle;
      await _open(tester, 2, PuzzleTier.hard);
      expect(_steps(0, puzzle.limit), findsOneWidget);
      expect(find.text('剩 ${puzzle.gems.length} 颗宝石'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('宝石在${_place(puzzle, puzzle.gems.first)}')), findsOneWidget);
      var state = IceState(puzzle.start);
      for (final (index, direction) in draw.solution.indexed) {
        state = iceMove(puzzle, state, direction);
        await tester.tap(find.byTooltip(_labels[direction]));
        await _frames(tester, 500);
        if (index == draw.solution.length - 1) break;
        final left = puzzle.gems.length - [for (var gem = 0; gem < puzzle.gems.length; gem++) if (state.gems & (1 << gem) != 0) gem].length;
        expect(_steps(index + 1, puzzle.limit), findsOneWidget, reason: '第 ${index + 1} 步');
        expect(find.textContaining('颗宝石'), left == 0 ? findsNothing : findsOneWidget, reason: '第 ${index + 1} 步');
        if (left > 0) expect(find.text('剩 $left 颗宝石'), findsOneWidget, reason: '第 ${index + 1} 步');
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('专家档 12×12 在 360 宽、1.3 倍字号下放得下：棋盘、方向键与撤销都在屏内，格子不小于 20', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      await _open(tester, 1, PuzzleTier.expert);
      final board = tester.getRect(_board);
      expect(board.left, greaterThanOrEqualTo(0));
      expect(board.right, lessThanOrEqualTo(360));
      expect(board.width / 12, greaterThanOrEqualTo(20));
      for (var direction = 0; direction < iceDirections; direction++) {
        final key = tester.getRect(_key(direction));
        expect(key.top, greaterThanOrEqualTo(board.bottom));
        expect(key.bottom, lessThanOrEqualTo(700));
      }
      expect(tester.getRect(find.widgetWithText(FilledButton, '撤销')).bottom, lessThanOrEqualTo(700));
      expect(find.textContaining(RegExp(r'^0/\d+ 步')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^剩 \d 颗宝石')), findsOneWidget);
      semantics.dispose();
    });
  });
}
