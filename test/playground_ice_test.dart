import 'dart:async';

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

// 手搭的 5×3 小图（S 起点、G 终点、# 岩石）：
// S . G . .
// . . . . .
// . . . # .
// 朝右会滑过终点停在右上角；最短是下、右、上三步。
final _small = _rules.decodePuzzle({'width': 5, 'height': 3, 'rocks': '000000000000010', 'start': 0, 'goal': 2});

// 每档区间与难度分段（同 ice_rules.dart 的注释）。
const _bands = {
  PuzzleTier.entry: (side: 6, least: (3, 5), score: (1, 2)),
  PuzzleTier.easy: (side: 7, least: (5, 7), score: (3, 3)),
  PuzzleTier.normal: (side: 8, least: (7, 10), score: (4, 5)),
  PuzzleTier.hard: (side: 10, least: (10, 14), score: (6, 7)),
  PuzzleTier.expert: (side: 12, least: (14, 99), score: (8, 10)),
};

String _place(IcePuzzle puzzle, int cell) => '第${cell ~/ puzzle.width + 1}行第${cell % puzzle.width + 1}列';

// 题面拼成一个列表比较（record 里的 List 按引用比，不逐项比）。
List<Object> _shape(IcePuzzle puzzle) => [puzzle.width, puzzle.height, puzzle.start, puzzle.goal, ...puzzle.rocks];

Finder get _board => find.bySemanticsLabel(RegExp('^冰面')).first;
Finder _steps(int count) => find.textContaining(RegExp('^$count 步'));

// 找一个入门档的种子，让开局满足条件（固定种子出的题固定，测试可重复）。
int _seedWhere(bool Function(IcePuzzle puzzle) test) {
  for (var seed = 0;; seed++) {
    if (test(_rules.generate(seed, PuzzleTier.entry).puzzle)) return seed;
  }
}

int? _direction(IcePuzzle puzzle, {required bool moves}) {
  for (var direction = 0; direction < iceDirections; direction++) {
    if ((iceSlide(puzzle, puzzle.start, direction) != puzzle.start) == moves) return direction;
  }
  return null;
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时按帧推进一段（滑行最长 300ms 加撞停 160ms）。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Widget _app(IcePage page) => MaterialApp(theme: campusTheme(), home: page);

IcePage _page(PlaygroundStore store, int seed) => IcePage(game: playgroundCatalog.firstWhere((game) => game.id == 'ice'), store: store, seeds: () => seed);

void main() {
  group('规则', () {
    test('滑到撞上岩石或边界才停，紧挨着就是原地', () {
      expect(iceSlide(_small, 0, iceRight), 4);
      expect(iceSlide(_small, 0, iceDown), 10);
      expect(iceSlide(_small, 0, iceUp), 0);
      expect(iceSlide(_small, 0, iceLeft), 0);
      expect(iceSlide(_small, 10, iceRight), 12);
      expect(iceSlide(_small, 12, iceUp), 2);
      expect(iceMinMoves(_small), 3);
      expect(iceSolution(_small), [iceDown, iceRight, iceUp]);
    });

    test('只有最后停在终点才算：滑过去不算、停上去又离开不算，滑不动只算原地', () {
      expect(_rules.solved(_small, [iceRight]), isFalse);
      expect(_rules.solved(_small, const []), isFalse);
      expect(_rules.solved(_small, [iceDown, iceRight, iceUp]), isTrue);
      expect(_rules.solved(_small, [iceDown, iceRight, iceUp, iceRight]), isFalse);
      expect(_rules.solved(_small, [iceUp, iceLeft, iceDown, iceRight, iceRight, iceUp]), isTrue);
      // 超过步数上限的答案一律不算，哪怕最后停在终点。
      expect(_rules.solved(_small, [...List.filled(iceMaxMoves - 2, iceUp), iceDown, iceRight, iceUp]), isFalse);
    });

    test('每档 20 道：边长、最少步数落在区间、终点能停下、参考解最短且判定解开、难度分落在本档分段，出题快', () {
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        final band = _bands[tier]!;
        var rocks = 0;
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect((puzzle.width, puzzle.height), (band.side, band.side), reason: reason);
          expect(puzzle.rocks[puzzle.start] || puzzle.rocks[puzzle.goal], isFalse, reason: reason);
          final least = iceMinMoves(puzzle);
          expect(least, inInclusiveRange(band.least.$1, band.least.$2), reason: reason);
          expect(draw.solution.length, least, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          expect(_rules.solved(puzzle, draw.solution.sublist(0, least! - 1)), isFalse, reason: reason);
          expect(_rules.difficulty(puzzle), inInclusiveRange(band.score.$1, band.score.$2), reason: reason);
          rocks += puzzle.rocks.where((rock) => rock).length;
        }
        // 岩石密度按 15%–25% 撒：20 道平均下来落在这附近。
        expect(rocks / (20 * band.side * band.side), inInclusiveRange(.13, .27), reason: '$tier');
      }
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(_shape(_rules.generate(7, PuzzleTier.hard).puzzle), _shape(_rules.generate(7, PuzzleTier.hard).puzzle));
      expect(_shape(_rules.generate(7, PuzzleTier.hard).puzzle), isNot(_shape(_rules.generate(8, PuzzleTier.hard).puzzle)));
    });

    test('难度分：步数多、地图大分数高，档与档在区间端点上也不倒挂', () {
      expect(iceDifficulty(5, 6), lessThan(iceDifficulty(5, 7)));
      expect(iceDifficulty(7, 7), lessThan(iceDifficulty(7, 8)));
      expect(iceDifficulty(10, 8), lessThan(iceDifficulty(10, 10)));
      expect(iceDifficulty(14, 10), lessThan(iceDifficulty(14, 12)));
      expect(iceDifficulty(3, 6), 1);
      expect(iceDifficulty(40, 12), 10);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = _rules.generate(3, PuzzleTier.expert);
      final puzzle = _rules.decodePuzzle(_rules.encodePuzzle(draw.puzzle));
      expect(_shape(puzzle), _shape(draw.puzzle));
      expect(_rules.solved(puzzle, _rules.decodeAnswer(_rules.encodeAnswer(draw.solution))), isTrue);
      Map<String, Object?> small(Map<String, Object?> change) => {'width': 5, 'height': 3, 'rocks': '000000000000010', 'start': 0, 'goal': 2, ...change};
      for (final broken in [
        small({'rocks': '00000000000001'}),
        small({'rocks': '000000000000012'}),
        small({'rocks': 15}),
        small({'start': 13}),
        small({'goal': 13}),
        small({'goal': 0}),
        small({'goal': 15}),
        small({'width': 2}),
        small({'height': iceMaxSide + 1}),
        small({'start': '0'}),
      ]) {
        expect(() => _rules.decodePuzzle(broken), throwsFormatException, reason: '$broken');
      }
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
      final store = PlaygroundStore.memory();
      final seed = _seedWhere((puzzle) => _direction(puzzle, moves: false) != null && _direction(puzzle, moves: true) != null);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final solution = iceSolution(puzzle)!;
      await tester.pumpWidget(_app(_page(store, seed)));
      await tester.pumpAndSettle();
      expect(find.text('最少 ${solution.length} 步'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，终点在${_place(puzzle, puzzle.goal)}')), findsOneWidget);
      // 四个方向键都能读、能点。
      for (final label in _labels) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      // 紧挨着墙的方向：不算步数，位置不变。
      await tester.tap(find.byTooltip(_labels[_direction(puzzle, moves: false)!]));
      await _frames(tester, 300);
      expect(_steps(0), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，')), findsOneWidget);
      // 滑得动的方向：一步，位置换到停下的那格；撤销回到起点。
      final moving = _direction(puzzle, moves: true)!;
      await tester.tap(find.byTooltip(_labels[moving]));
      await _frames(tester, 500);
      expect(_steps(1), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, iceSlide(puzzle, puzzle.start, moving))}，')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 300);
      expect(_steps(0), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, puzzle.start)}，')), findsOneWidget);

      for (final direction in solution) {
        await tester.tap(find.byTooltip(_labels[direction]));
        await _frames(tester, 500);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('${solution.length} 步，正好最少'), findsOneWidget);
      expect(store.best('ice', PuzzleTier.entry)!.moves, solution.length);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('ice'), PuzzleTier.easy);
      expect(find.bySemanticsLabel(RegExp('^冰面 7×7')), findsOneWidget);
      expect(_steps(0), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('在棋盘上滑动推动棋子，四个方向都认', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedWhere((puzzle) => iceSolution(puzzle)!.toSet().length == iceDirections);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      await tester.pumpWidget(_app(_page(store, seed)));
      await tester.pumpAndSettle();
      // 按出题的参考解逐步滑（这道题的最短走法上下左右都用到）：每一步都朝那个方向在棋盘上划一下。
      const swipes = [Offset(0, -60), Offset(60, 0), Offset(0, 60), Offset(-60, 0)];
      final solution = iceSolution(puzzle)!;
      for (final (index, direction) in solution.indexed) {
        await tester.dragFrom(tester.getCenter(_board), swipes[direction]);
        await _frames(tester, 500);
        if (index < solution.length - 1) expect(_steps(index + 1), findsOneWidget);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）也认横向移动：棋盘上的横滑必须归棋盘，别处的右滑照常返回。
    testWidgets('iOS 上棋盘里横滑推动棋子、不触发右滑返回，棋盘外右滑照常返回', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedWhere((puzzle) => iceSlide(puzzle, puzzle.start, iceRight) != puzzle.start);
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
      expect(_steps(1), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('棋子在${_place(puzzle, iceSlide(puzzle, puzzle.start, iceRight))}，')), findsOneWidget);

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
      final store = PlaygroundStore.memory();
      final seed = _seedWhere((_) => true);
      final solution = _rules.generate(seed, PuzzleTier.entry).solution;
      await tester.pumpWidget(_app(_page(store, seed)));
      await tester.pumpAndSettle();
      for (final direction in solution) {
        await tester.tap(find.byTooltip(_labels[direction]));
        await tester.pump();
      }
      // 正常动画下这时还在滑行或在终点上跳（滑行加撞停至少 240ms、跳一下 760ms）。
      await _frames(tester, 200);
      expect(find.text('新纪录'), findsOneWidget);
    });
  });
}
