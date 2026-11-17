import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/pour/pour_page.dart';
import 'package:superxd/playground/puzzle/pour/pour_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

const _rules = PourRules();
const _seeds = 40;

// 每档挑得到的题型（同 pour_rules.dart 的 _tiers）。
const _kinds = {
  PuzzleTier.entry: {PourKind.ramp, PourKind.funnel, PourKind.catcher},
  PuzzleTier.easy: {PourKind.ramp, PourKind.funnel, PourKind.catcher, PourKind.bridge},
  PuzzleTier.normal: {PourKind.bridge, PourKind.detour, PourKind.uturn, PourKind.pair},
  PuzzleTier.hard: {PourKind.detour, PourKind.uturn, PourKind.pair, PourKind.slot, PourKind.windmill},
  PuzzleTier.expert: {PourKind.switchback, PourKind.slot, PourKind.windmill, PourKind.pair, PourKind.uturn},
};

// 这一档出某一类题的第一个种子（种子到题型的对应随出题改动会变，测试按题型找）。
int _seedFor(PuzzleTier tier, PourKind kind) {
  for (var seed = 0; ; seed++) {
    if (_rules.generate(seed, tier).puzzle.kind == kind) return seed;
  }
}

// 题面拼成一个列表比较（record 里的 List 按引用比，不逐项比）。
List<int> _shape(PourPuzzle puzzle) => [
  puzzle.kind.code,
  ...puzzle.balls,
  puzzle.cup.x,
  puzzle.cup.bottom,
  puzzle.cup.width,
  puzzle.cup.depth,
  for (final block in puzzle.blocks) ...[block.x, block.y, block.halfWidth, block.halfHeight, block.angle],
  for (final spinner in puzzle.spinners) ...[spinner.x, spinner.y, spinner.halfLength, spinner.speed, spinner.angle],
  puzzle.ink,
  puzzle.par,
];

// 一道手搭的题：球在左上，杯子在右下，没有障碍，墨水 600，参考线长按 200 算星。
Map<String, Object> _simpleJson({List<int> spinners = const []}) => {'kind': 0, 'balls': [150, 200], 'cup': [440, 740, 130, 70], 'blocks': <int>[], 'spinners': spinners, 'ink': 600, 'par': 200};
final _simple = _rules.decodePuzzle(_simpleJson());

// 一笔最左与最右的 x 之和（按它左右翻过来，这一笔原地换朝向）。
int _flipCenter(List<int> stroke) {
  final xs = [for (var index = 0; index < stroke.length; index += 2) stroke[index]];
  return xs.reduce(math.min) + xs.reduce(math.max);
}

// 棋盘最底下一条贴边的线（碰不到球，长 length）：放不下就沿右边往上拐。
List<int> _tail(num length) => length <= 580 ? [10, 798, 10 + length.round(), 798] : [10, 798, 590, 798, 590, 798 - (length - 580).round()];

Widget _app(PourPage page) => MaterialApp(theme: campusTheme(), home: page);

PourPage _page(PlaygroundStore store, int seed) => PourPage(game: playgroundCatalog.firstWhere((game) => game.id == 'pour'), store: store, seeds: () => seed);

Finder get _board => find.bySemanticsLabel(RegExp('^画线入杯：')).first;

// 状态行里的墨水百分比（「墨水 64%」后面可能挂着分隔点）。
int _inkShown(WidgetTester tester) {
  final text = tester.widgetList<Text>(find.textContaining(RegExp('^墨水 '))).single.data!;
  return int.parse(RegExp(r'墨水 (\d+)%').firstMatch(text)!.group(1)!);
}

Finder _strokeCount(int count) => find.textContaining(RegExp('^$count 笔'));

// 放球中计时器与模拟每帧出帧，pumpAndSettle 等不到停；按帧推进一段。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// 用手指在棋盘上按单位坐标画一笔：沿折线每 3 像素报一次移动（同真手指的密度）。
Future<void> _draw(WidgetTester tester, List<int> points) async {
  final origin = tester.getTopLeft(_board), scale = tester.getSize(_board).width / pourWidth;
  Offset at(int index) => origin + Offset(points[index] * scale, points[index + 1] * scale);
  final gesture = await tester.startGesture(at(0));
  for (var index = 2; index < points.length; index += 2) {
    final from = at(index - 2), to = at(index);
    final count = math.max(1, ((to - from).distance / 3).ceil());
    for (var step = 1; step <= count; step++) {
      await gesture.moveTo(Offset.lerp(from, to, step / count)!);
    }
  }
  await gesture.up();
  await tester.pump();
}

Future<void> _tapButton(WidgetTester tester, String label) async {
  hideCampusToast();
  await tester.pump(const Duration(milliseconds: 400));
  final button = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

// 放球后推进到出结果（进杯会弹结果，没进会出提示条），最多 13 秒。
Future<void> _runOut(WidgetTester tester) async {
  for (var elapsed = 0; elapsed < 13000 && find.widgetWithText(FilledButton, '停下').evaluate().isNotEmpty; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// 按参考线画完、放球，等结果弹层出来。
Future<void> _solve(WidgetTester tester, List<List<int>> solution) async {
  for (final stroke in solution) {
    await _draw(tester, stroke);
  }
  await _tapButton(tester, '放球');
  await _runOut(tester);
  await tester.pumpAndSettle();
}

void main() {
  group('规则', () {
    test('每档出题：题型在这一档里，参考线在墨水之内且留余量、正好 3 星，画上放球能进杯，什么都不画进不了；难度分落在这一档的分段', () {
      for (final tier in PuzzleTier.values) {
        final seen = <PourKind>{};
        for (var seed = 0; seed < _seeds; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '${tier.name} 种子 $seed ${puzzle.kind.name}';
          seen.add(puzzle.kind);
          expect(_kinds[tier], contains(puzzle.kind), reason: reason);
          expect(puzzle.ballCount, greaterThanOrEqualTo(puzzle.kind.balls), reason: reason);
          expect(puzzle.par, pourInkUsed(draw.solution).ceil(), reason: reason);
          expect(puzzle.ink, greaterThanOrEqualTo(puzzle.par * 1.3), reason: reason);
          expect(pourStars(puzzle, draw.solution), 3, reason: reason);
          expect(pourAnswerValid(puzzle, draw.solution), isTrue, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          expect(pourSimulate(puzzle, const []), PourOutcome.lost, reason: reason);
          expect(_rules.complexity(puzzle), inInclusiveRange(tier.index * 2 + 1, tier.index * 2 + 2), reason: reason);
        }
        // 换种子换的是结构：这一档的每一类都挑得到。
        expect(seen, _kinds[tier], reason: tier.name);
      }
    });

    test('各类自己的检查：参考线上下挪 6 单位照样进；多笔的题少画哪一笔都进不了；绕障与风车照直画一条坡进不了；风车的轴挡在那条坡上', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle, solution = draw.solution;
          final reason = '${tier.name} 种子 $seed ${puzzle.kind.name}';
          for (final dy in [-6, 6]) {
            expect(_rules.solved(puzzle, [for (final stroke in solution) [for (final (index, value) in stroke.indexed) index.isOdd ? value + dy : value]]), isTrue, reason: '$reason 挪 $dy');
          }
          if (solution.length > 1) {
            for (final stroke in solution) {
              expect(pourSimulate(puzzle, [stroke]), PourOutcome.lost, reason: '$reason 只画一笔');
            }
          }
          if (puzzle.kind == PourKind.detour || puzzle.kind == PourKind.windmill) {
            final stroke = solution.single;
            expect(stroke.length, 6, reason: '$reason 折一下');
            expect(pourSimulate(puzzle, [[stroke[0], stroke[1], stroke[4], stroke[5]]]), PourOutcome.lost, reason: '$reason 照直');
          }
          expect(puzzle.spinners.length, puzzle.kind == PourKind.windmill ? 1 : 0, reason: reason);
          if (puzzle.kind == PourKind.pair) expect(solution.length, 2, reason: reason);
        }
      }
    });

    test('难度分逐档上升，同档相差不超过 1；预计用时逐档上升', () {
      var previous = 0, previousSeconds = 0;
      for (final tier in PuzzleTier.values) {
        final puzzles = [for (var seed = 0; seed < 30; seed++) _rules.generate(seed, tier).puzzle];
        final scores = [for (final puzzle in puzzles) _rules.complexity(puzzle)];
        expect(scores.reduce(math.max) - scores.reduce(math.min), lessThanOrEqualTo(1), reason: tier.name);
        expect(scores.reduce(math.min), greaterThan(previous), reason: tier.name);
        previous = scores.reduce(math.max);
        final seconds = [for (final puzzle in puzzles) _rules.expectedSeconds(puzzle)];
        expect(seconds.reduce(math.min), greaterThanOrEqualTo(previousSeconds), reason: tier.name);
        previousSeconds = seconds.reduce(math.max);
      }
    });

    test('星级：用墨不超过参考线长的 1.25 倍 3 星、不超过 1.75 倍 2 星，其余 1 星', () {
      expect(pourThreeStars, 1.25);
      expect(pourTwoStars, 1.75);
      // 参考线长 200：250 以内 3 星，350 以内 2 星。
      for (final (length, stars) in [(0, 3), (120, 3), (250, 3), (251, 2), (350, 2), (351, 1), (590, 1)]) {
        expect(pourStars(_simple, [_tail(length)]), stars, reason: '$length');
        expect(pourStarsFor(_simple, length.toDouble()), stars, reason: '$length');
      }
      // 几笔加起来算。
      expect(pourStars(_simple, [_tail(200), [10, 780, 60, 780]]), 3);
      expect(pourStars(_simple, [_tail(200), [10, 780, 61, 780]]), 2);
    });

    test('同一道题同一种画法每次模拟结果一样（同一台设备上判定稳定），风车也一样', () {
      for (final (tier, kind) in [(PuzzleTier.hard, PourKind.pair), (PuzzleTier.expert, PourKind.windmill)]) {
        final draw = _rules.generate(_seedFor(tier, kind), tier);
        List<double> finalPoses() {
          final simulation = PourSimulation(draw.puzzle, draw.solution);
          while (simulation.outcome == PourOutcome.running) {
            simulation.step();
          }
          final poses = [
            for (var index = 0; index < draw.puzzle.ballCount; index++) ...[simulation.ball(index).x, simulation.ball(index).y],
            for (var index = 0; index < draw.puzzle.spinners.length; index++) simulation.spinner(index),
            simulation.steps.toDouble(),
          ];
          simulation.dispose();
          return poses;
        }

        expect(finalPoses(), finalPoses(), reason: kind.name);
      }
    });

    test('风车匀速转：转角只看过了几步', () {
      final puzzle = _rules.decodePuzzle(_simpleJson(spinners: [300, 420, 50, 90, 30]));
      final simulation = PourSimulation(puzzle, const []);
      expect(simulation.spinner(0), closeTo(30 * math.pi / 180, 1e-6));
      for (var step = 0; step < 40; step++) {
        simulation.step();
      }
      expect(simulation.outcome, PourOutcome.running);
      // 40 步 × 1/60 秒 × 90 度每秒 = 60 度。
      expect(simulation.spinner(0), closeTo(90 * math.pi / 180, 1e-3));
      simulation.dispose();
    });

    test('明显错的线不进杯：球下方的平台把球接住、朝杯子反方向的坡、参考线每笔原地左右翻过来', () {
      // 手搭的题先确认一条朝杯子的坡能进，排除题本身有问题。
      expect(_rules.solved(_simple, [[100, 300, 400, 655]]), isTrue);
      expect(_rules.solved(_simple, [[90, 300, 220, 300]]), isFalse);
      expect(_rules.solved(_simple, [[220, 300, 40, 420]]), isFalse);
      expect(_rules.solved(_simple, const []), isFalse);
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 8; seed++) {
          final draw = _rules.generate(seed, tier);
          // 缓冲接住的参考线是一笔竖挡，翻过来还是竖挡；搭桥的桥短而缓，翻过来球也冲得过去（另一种解法）。都不拿它比。
          if (draw.puzzle.kind == PourKind.catcher || draw.puzzle.kind == PourKind.bridge) continue;
          // 每笔按自己的左右中线翻过来：坡朝反方向斜。
          final flipped = [
            for (final stroke in draw.solution)
              [for (var index = 0; index < stroke.length; index++) index.isEven ? _flipCenter(stroke) - stroke[index] : stroke[index]],
          ];
          expect(_rules.solved(draw.puzzle, flipped), isFalse, reason: '${tier.name} 种子 $seed ${draw.puzzle.kind.name}');
        }
      }
    });

    test('墨水超限的答案不算，哪怕放球能进杯；线压着球的起点也不算', () {
      final draw = _rules.generate(_seedFor(PuzzleTier.entry, PourKind.ramp), PuzzleTier.entry);
      final puzzle = draw.puzzle;
      final left = puzzle.ink - pourInkUsed(draw.solution);
      // 棋盘最底下一条贴边的线碰不到球：短到墨水够时照样进杯，长过剩下的墨水就不算。
      final enough = [...draw.solution, _tail(left.floor() - 1)];
      final over = [...draw.solution, _tail(left.ceil() + 1)];
      expect(_rules.solved(puzzle, enough), isTrue);
      expect(pourSimulate(puzzle, over), PourOutcome.won);
      expect(pourAnswerValid(puzzle, over), isFalse);
      expect(_rules.solved(puzzle, over), isFalse);
      // 穿过球起点的线。
      final ball = (puzzle.balls[0], puzzle.balls[1]);
      expect(_rules.solved(puzzle, [...draw.solution, [ball.$1 - 20, ball.$2, ball.$1 + 20, ball.$2]]), isFalse);
      expect(pourSegmentClear(puzzle, ball.$1 - 40, ball.$2 - pourBallClearance, ball.$1 + 40, ball.$2 - pourBallClearance), isTrue);
      expect(pourSegmentClear(puzzle, ball.$1 - 40, ball.$2 - pourBallClearance + 1, ball.$1 + 40, ball.$2 - pourBallClearance + 1), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException；题面写法是第 2 版', () {
      expect(_rules.puzzleVersion, 2);
      for (final tier in PuzzleTier.values) {
        for (final kind in _kinds[tier]!) {
          final draw = _rules.generate(_seedFor(tier, kind), tier);
          expect(_shape(_rules.decodePuzzle(_rules.encodePuzzle(draw.puzzle))), _shape(draw.puzzle), reason: '${tier.name} ${kind.name}');
          final answer = _rules.decodeAnswer(_rules.encodeAnswer(draw.solution));
          expect([for (final stroke in answer) ...stroke, -1], [for (final stroke in draw.solution) ...stroke, -1]);
        }
      }
      final good = _simpleJson();
      Map<String, Object?> change(String key, Object? value) => {...good, key: value};
      Map<String, Object?> without(String key) => {...good}..remove(key);
      expect(_rules.decodePuzzle(change('spinners', [300, 420, 50, 90, 30])).spinners.single.speed, 90);
      for (final bad in <Object?>[
        null,
        'pour',
        without('kind'),
        change('kind', 99),
        change('kind', '0'),
        change('balls', <int>[]),
        change('balls', [150]),
        change('balls', [5, 200]),
        change('balls', [150, 200, 160, 210]),
        change('balls', [1, 2, 3, 4, 5, 6, 7, 8]),
        change('cup', [440, 740, 130]),
        change('cup', [560, 740, 130, 70]),
        change('cup', [440, 795, 130, 70]),
        change('cup', [440, 740, 20, 70]),
        change('blocks', [300, 300, 40, 10]),
        change('blocks', [150, 200, 40, 10, 0]),
        change('blocks', [300, 300, 2, 10, 0]),
        without('spinners'),
        change('spinners', [300, 420, 50, 90]),
        change('spinners', [300, 420, pourSpinnerHub + 9, 90, 0]),
        change('spinners', [300, 420, 50, 0, 0]),
        change('spinners', [300, 420, 50, 90, 181]),
        change('spinners', [170, 220, 50, 90, 0]),
        change('spinners', [300, 420, 50, 90, 0, 300, 300, 50, 90, 0, 300, 200, 50, 90, 0]),
        change('ink', 0),
        change('ink', pourMaxInk + 1),
        change('ink', '600'),
        without('par'),
        change('par', 10),
        change('par', 601),
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>[
        null,
        {'strokes': <int>[]},
        [[10, 10]],
        [[10, 10, 20]],
        [[10, 10, pourWidth + 1, 20]],
        [[10, -1, 20, 20]],
        [['10', 10, 20, 20]],
        List.filled(pourMaxStrokes + 1, [10, 10, 20, 20]),
        [List.filled(pourMaxPoints * 2 + 2, 10)],
      ]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer(const <Object>[]), isEmpty);
    });

    // 这个游戏在界面线程上当场出题（forge2d 的原生世界不能放进别的 isolate），出题慢了换题会卡一下。
    test('出题与判定耗时：每档单题最慢不超过 200ms，判定一次不超过 100ms', () {
      var slowest = Duration.zero, slowestJudge = Duration.zero;
      for (final tier in PuzzleTier.values) {
        for (var seed = 100; seed < 120; seed++) {
          final watch = Stopwatch()..start();
          final draw = _rules.generate(seed, tier);
          final generated = watch.elapsed;
          _rules.solved(draw.puzzle, draw.solution);
          final judged = watch.elapsed - generated;
          if (generated > slowest) slowest = generated;
          if (judged > slowestJudge) slowestJudge = judged;
        }
      }
      expect(slowest, lessThan(const Duration(milliseconds: 200)));
      expect(slowestJudge, lessThan(const Duration(milliseconds: 100)));
    });
  });

  group('对局页', () {
    testWidgets('画线时墨水跟着减少，超出墨水就停在用完的地方；墨水用完再画轻震提示、不添笔', (tester) async {
      final store = PlaygroundStore.memory();
      await tester.pumpWidget(_app(_page(store, 4)));
      await tester.pumpAndSettle();
      final puzzle = _rules.generate(4, PuzzleTier.entry).puzzle;
      expect(_inkShown(tester), 100);

      // 沿棋盘最底下来回画几趟（总长远超墨水），手指还按着时墨水就在减少。
      final origin = tester.getTopLeft(_board), scale = tester.getSize(_board).width / pourWidth;
      final gesture = await tester.startGesture(origin + Offset(10 * scale, 790 * scale));
      for (var x = 10; x <= 210; x += 5) {
        await gesture.moveTo(origin + Offset(x * scale, 790 * scale));
      }
      await tester.pump();
      final midway = _inkShown(tester);
      expect(midway, inInclusiveRange(100 - (200 / puzzle.ink * 100).ceil() - 2, 99));
      for (final (fromX, toX, y) in [(210, 590, 790), (590, 10, 796), (10, 590, 784)]) {
        for (var step = 0; step <= 80; step++) {
          await gesture.moveTo(origin + Offset((fromX + (toX - fromX) * step / 80) * scale, y * scale));
        }
      }
      await gesture.up();
      await tester.pump();
      expect(_inkShown(tester), 0);
      expect(_strokeCount(1), findsOneWidget);
      expect(find.text('墨水用完了，可以撤销或重画'), findsOneWidget);

      // 再画一笔：不添笔，照样提示。
      hideCampusToast();
      await tester.pump(const Duration(milliseconds: 400));
      await _draw(tester, [100, 770, 300, 770]);
      expect(_strokeCount(1), findsOneWidget);
      expect(find.text('墨水用完了，可以撤销或重画'), findsOneWidget);
    });

    testWidgets('撤销退回上一笔、重画清空；线画到球上就停在球外', (tester) async {
      final store = PlaygroundStore.memory();
      await tester.pumpWidget(_app(_page(store, 4)));
      await tester.pumpAndSettle();
      final puzzle = _rules.generate(4, PuzzleTier.entry).puzzle;
      await _draw(tester, [40, 785, 200, 785]);
      final afterOne = _inkShown(tester);
      await _draw(tester, [300, 792, 500, 792]);
      expect(_strokeCount(2), findsOneWidget);
      expect(_inkShown(tester), lessThan(afterOne));
      await _tapButton(tester, '撤销');
      expect(_strokeCount(1), findsOneWidget);
      expect(_inkShown(tester), afterOne);
      await _tapButton(tester, '重画');
      expect(_strokeCount(1), findsNothing);
      expect(_inkShown(tester), 100);

      // 从球左边横着朝球画过去：画到球外就停，提示线不能碰到球，松手后这一笔照样留下。
      final (ballX, ballY) = (puzzle.balls[0], puzzle.balls[1]);
      await _draw(tester, [math.max(0, ballX - 120), ballY, math.min(pourWidth, ballX + 120), ballY]);
      expect(find.text('线不能碰到球'), findsOneWidget);
      expect(_strokeCount(1), findsOneWidget);
      // 画好的这一笔整条都不压球。
      expect(_inkShown(tester), greaterThan(100 - (120 / puzzle.ink * 100).ceil() - 1));
    });

    testWidgets('按参考线画、放球进杯：杯子亮一下、亮出 3 星再弹新纪录（结果写几星），换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final draw = _rules.generate(6, PuzzleTier.entry);
      await tester.pumpWidget(_app(_page(store, 6)));
      await tester.pumpAndSettle();
      for (final stroke in draw.solution) {
        await _draw(tester, stroke);
      }
      expect(_strokeCount(draw.solution.length), findsOneWidget);
      await _tapButton(tester, '放球');
      expect(find.widgetWithText(FilledButton, '停下'), findsOneWidget);
      await _runOut(tester);
      // 刚停稳时杯子还在亮，结果没弹出来。
      expect(find.text('新纪录'), findsNothing);
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      // 说明行按「 · 」分项排，读屏读整句。
      expect(find.bySemanticsLabel(RegExp('3 星 · ${draw.solution.length} 笔，用掉')), findsOneWidget);
      expect(store.best('pour', PuzzleTier.entry)!.moves, draw.solution.length);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('pour'), PuzzleTier.easy);
      expect(_inkShown(tester), 100);
      expect(find.widgetWithText(FilledButton, '放球'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('墨水条上的星：用墨超过参考线 1.25 倍就只够 2 星，撤销回到 3 星；用得多画进杯结果写 2 星', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedFor(PuzzleTier.entry, PourKind.ramp);
      final draw = _rules.generate(seed, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      await tester.pumpWidget(_app(_page(store, seed)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('，够 3 星，')), findsOneWidget);
      // 底下一条贴边的线，加上参考线正好超过 1.25 倍。
      await _draw(tester, _tail(puzzle.par * .3 + 10));
      expect(find.bySemanticsLabel(RegExp('，够 3 星，')), findsOneWidget);
      for (final stroke in draw.solution) {
        await _draw(tester, stroke);
      }
      expect(find.bySemanticsLabel(RegExp('，够 2 星，')), findsOneWidget);
      await _tapButton(tester, '放球');
      await _runOut(tester);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('2 星 · ${draw.solution.length + 1} 笔，用掉')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('两边来球：只画一边那边进杯不算，两边都画上才进杯；风车题照参考线画也进杯，读屏说有风车', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await store.chooseTier('pour', PuzzleTier.normal);
      final pairSeed = _seedFor(PuzzleTier.normal, PourKind.pair);
      final pair = _rules.generate(pairSeed, PuzzleTier.normal);
      await tester.pumpWidget(_app(_page(store, pairSeed)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('^画线入杯：上方.+有 2 个球')), findsOneWidget);
      await _draw(tester, pair.solution.first);
      await _tapButton(tester, '放球');
      await _runOut(tester);
      expect(find.textContaining('没进杯'), findsOneWidget);
      await _solve(tester, [pair.solution.last]);
      expect(find.text('新纪录'), findsOneWidget);
      await tester.tap(find.text('换到困难'));
      await tester.pumpAndSettle();

      final windSeed = _seedFor(PuzzleTier.hard, PourKind.windmill);
      final windmill = _rules.generate(windSeed, PuzzleTier.hard);
      // 先拆掉上一页，新页面才按新种子出题。
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_app(_page(store, windSeed)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel(RegExp('，中间有 1 个转动的风车，')), findsOneWidget);
      await _solve(tester, windmill.solution);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('放球期间不能画线、可以停下；没进杯提示再试一次，球留在原处，接着画一笔就收回', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await tester.pumpWidget(_app(_page(store, 4)));
      await tester.pumpAndSettle();
      await _draw(tester, [40, 785, 200, 785]);

      // 停下：球回到起点，又能画。
      await _tapButton(tester, '放球');
      await _frames(tester, 200);
      expect(find.bySemanticsLabel(RegExp('，球在滚')), findsOneWidget);
      await _tapButton(tester, '停下');
      expect(find.widgetWithText(FilledButton, '放球'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('，球在滚')), findsNothing);

      await _tapButton(tester, '放球');
      await _frames(tester, 100);
      await _draw(tester, [300, 792, 500, 792]);
      expect(find.text('放球中不能画线'), findsOneWidget);
      expect(_strokeCount(1), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '撤销'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      // 放球中不能画线的提示过时了，收掉再看没进杯。
      hideCampusToast();
      await tester.pump(const Duration(milliseconds: 400));
      await _runOut(tester);
      // 没进杯写在状态行、读屏有播报，不弹提示条（它会盖住棋盘下沿、接住画线的手指）。
      expect(find.textContaining('没进杯'), findsOneWidget);
      expect(find.byType(CampusOverlayGlass), findsNothing);
      expect(tester.getSemantics(find.bySemanticsLabel('没进杯，再试一次')), isSemantics(label: '没进杯，再试一次', isLiveRegion: true));
      expect(find.widgetWithText(FilledButton, '放球'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('，上一次没进杯')), findsOneWidget);
      // 马上就能在棋盘下沿画线。
      await _draw(tester, [300, 792, 500, 792]);
      expect(_strokeCount(2), findsOneWidget);
      expect(find.textContaining('没进杯'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('，上一次没进杯')), findsNothing);
      semantics.dispose();
    });

    // 进后台时系统本来就不出帧；被下拉的通知栏、控制中心盖住时（inactive）照样出帧，这时模拟也要停住。
    testWidgets('离开前台时模拟停住，回到前台接着走', (tester) async {
      final store = PlaygroundStore.memory();
      await tester.pumpWidget(_app(_page(store, 4)));
      await tester.pumpAndSettle();
      await _tapButton(tester, '放球');
      await _frames(tester, 100);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      // 比整次模拟的最长时长还久：不在前台时不走，所以还是「停下」。
      await _frames(tester, 14000);
      expect(find.widgetWithText(FilledButton, '停下'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _runOut(tester);
      expect(find.widgetWithText(FilledButton, '放球'), findsOneWidget);
      expect(find.textContaining('没进杯'), findsOneWidget);
    });

    testWidgets('减少动画时进杯停稳马上弹结果', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final store = PlaygroundStore.memory();
      final draw = _rules.generate(9, PuzzleTier.easy);
      await store.chooseTier('pour', PuzzleTier.easy);
      await tester.pumpWidget(_app(_page(store, 9)));
      await tester.pumpAndSettle();
      for (final stroke in draw.solution) {
        await _draw(tester, stroke);
      }
      await _tapButton(tester, '放球');
      await _runOut(tester);
      // 正常动画下这时杯子还在亮（720ms）；减少动画时弹层只走它自己的进场。
      await _frames(tester, 400);
      expect(find.text('新纪录'), findsOneWidget);
    });

    // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）也认横向移动：棋盘上横着画线必须归棋盘，别处的右滑照常返回。
    testWidgets('iOS 上棋盘里横着画线、不触发右滑返回，棋盘外右滑照常返回', (tester) async {
      final store = PlaygroundStore.memory();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
      unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => _page(store, 4))));
      await tester.pumpAndSettle();

      final origin = tester.getTopLeft(_board), scale = tester.getSize(_board).width / pourWidth;
      final gesture = await tester.startGesture(origin + Offset(20 * scale, 790 * scale));
      for (var step = 0; step < 12; step++) {
        await gesture.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      expect(navigator.currentState!.userGestureInProgress, isFalse);
      await gesture.up();
      await _frames(tester, 500);
      expect(find.byType(PourPage), findsOneWidget);
      expect(tester.getTopLeft(find.byType(PourPage)).dx, 0);
      expect(_strokeCount(1), findsOneWidget);

      // 底部按钮左边的空白处右滑：返回上一页。
      final width = tester.getSize(find.byType(MaterialApp)).width;
      final beside = Offset(8, tester.getCenter(find.widgetWithText(FilledButton, '撤销')).dy);
      await tester.timedDragFrom(beside, Offset(width * .7, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(PourPage), findsNothing);
      expect(find.text('上一页'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('读屏：棋盘讲清楚球、杯子、障碍、墨水与够几星，放球、撤销、重画都是按钮', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await store.chooseTier('pour', PuzzleTier.normal);
      final seed = _seedFor(PuzzleTier.normal, PourKind.uturn);
      final puzzle = _rules.generate(seed, PuzzleTier.normal).puzzle;
      await tester.pumpWidget(_app(_page(store, seed)));
      await tester.pumpAndSettle();
      String side(num x) => x < pourWidth / 3 ? '左侧' : (x > pourWidth * 2 / 3 ? '右侧' : '正中');
      expect(find.bySemanticsLabel('画线入杯：上方${side(puzzle.balls[0])}有 1 个球，杯子在下方${side(puzzle.cup.x)}，中间有 1 块障碍，墨水还剩 100%，够 3 星，已画 0 笔'), findsOneWidget);
      expect(tester.getSemantics(_board).hint, '用手指在棋盘上画线，把球引进杯子，再点放球');
      for (final label in ['放球', '撤销', '重画']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
      semantics.dispose();
    });
  });
}
