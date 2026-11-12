import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/lights/lights_page.dart';
import 'package:superxd/playground/puzzle/lights/lights_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

// 从全亮开始依次点 presses 得到的题面。
LightsPuzzle _board(int side, Iterable<int> presses) {
  final lit = List.filled(side * side, true);
  for (final cell in presses) {
    lightsPress(lit, side, cell);
  }
  return LightsPuzzle(side: side, lit: lit);
}

// 4×4 里「点了等于没点」的一组 8 格（零空间里的一个向量）。
const _quiet4 = [1, 2, 3, 4, 6, 8, 9, 12];

// 出题时每档最少下数的区间（同 lights_rules.dart 的 _least）。
const _leastRange = {PuzzleTier.entry: (2, 4), PuzzleTier.easy: (4, 7), PuzzleTier.normal: (7, 11), PuzzleTier.hard: (10, 15), PuzzleTier.expert: (13, 20)};

final _app = GlobalKey();

Finder _cell(int row, int column) => find.bySemanticsLabel(RegExp('^第${row + 1}行第${column + 1}列，'));
Finder _status(int presses, int least) => find.bySemanticsLabel(RegExp('· $presses 步 · 最少 $least 步\$'));

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时只推进固定时长。
Future<void> _step(WidgetTester tester) => tester.pump(const Duration(milliseconds: 300));

// 画面上某一点的颜色（按逻辑像素取）：用来看灯的过渡，不碰页面内部。
Future<Color> _colorAt(WidgetTester tester, Offset point) async => (await tester.runAsync(() async {
  final boundary = _app.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = (await image.toByteData())!;
  final offset = (point.dy.round() * image.width + point.dx.round()) * 4;
  image.dispose();
  return Color.fromARGB(bytes.getUint8(offset + 3), bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
}))!;

double _distance(Color left, Color right) => ((left.r - right.r).abs() + (left.g - right.g).abs() + (left.b - right.b).abs()) * 255;

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('lights', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'lights');
  await tester.pumpWidget(RepaintBoundary(key: _app, child: MaterialApp(theme: campusTheme(), home: LightsPage(game: game, store: store, seeds: () => seed))));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  group('点灯规则', () {
    const rules = LightsRules();

    test('点一格翻转自己和上下左右，同一格点两下复原', () {
      expect(lightsReach(3, 0)..sort(), [0, 1, 3]);
      expect(lightsReach(3, 5)..sort(), [2, 4, 5, 8]);
      expect(lightsReach(4, 5)..sort(), [1, 4, 5, 6, 9]);
      final lit = List.filled(9, true);
      lightsPress(lit, 3, 4);
      expect(lit, [true, false, true, false, false, false, true, false, true]);
      lightsPress(lit, 3, 4);
      expect(lit, everyElement(isTrue));
    });

    test('求最少点法：满秩时就是点过的那几格，有零空间时取最省的一组，点不全亮的返回 null', () {
      expect(lightsSolve(_board(3, [4])), [4]);
      expect(lightsSolve(_board(7, [0, 24, 48])), [0, 24, 48]);
      expect(_board(4, _quiet4).lit, everyElement(isTrue));
      // 点了零空间的 8 格再加一格：局面同只点那一格，最少 1 下。
      expect(lightsSolve(_board(4, [..._quiet4, 15])), [15]);
      expect(lightsSolve(_board(4, const [])), isEmpty);
      // 5×5 只灭左上角一盏：和零空间不正交，怎么点都点不全亮。
      expect(lightsSolve(LightsPuzzle(side: 5, lit: [false, ...List.filled(24, true)])), isNull);
    });

    test('每档出的题：开局没全亮，最少下数在这一档的区间，参考解点得开；难度分同档相近、档间单调；出题快且可复现', () {
      final watch = Stopwatch()..start();
      int? lowerTierTop;
      for (final tier in PuzzleTier.values) {
        final (low, high) = _leastRange[tier]!;
        final scores = <int>[];
        for (var seed = 0; seed < 20; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(puzzle.side, tier.index + 3, reason: '$tier $seed');
          expect(puzzle.lit, contains(false));
          expect(rules.solved(puzzle, const []), isFalse);
          expect(draw.solution.length, inInclusiveRange(low, high));
          expect(lightsSolve(puzzle)!.length, draw.solution.length);
          expect(rules.solved(puzzle, draw.solution), isTrue);
          scores.add(rules.difficulty(puzzle));
        }
        final lowest = scores.reduce(math.min), highest = scores.reduce(math.max);
        expect(lowest, greaterThanOrEqualTo(1));
        expect(highest, lessThanOrEqualTo(10));
        expect(highest - lowest, lessThanOrEqualTo(2), reason: '$tier 同档分数 $scores');
        if (lowerTierTop != null) expect(lowest, greaterThan(lowerTierTop), reason: '$tier 要高过下一档');
        lowerTierTop = highest;
      }
      // 对局页同步出题：100 道一共也要很快。
      expect(watch.elapsedMilliseconds, lessThan(2000));
      expect(rules.generate(7, PuzzleTier.hard).puzzle.lit, rules.generate(7, PuzzleTier.hard).puzzle.lit);
      expect(rules.generate(7, PuzzleTier.expert).puzzle.lit, isNot(rules.generate(8, PuzzleTier.expert).puzzle.lit));
    });

    test('按规则判定，不和参考解逐项比：换顺序、多点两下同一格、零空间里的另一组解都算；少点、越界与超长不算', () {
      final draw = rules.generate(2, PuzzleTier.easy);
      final puzzle = draw.puzzle;
      expect(rules.solved(puzzle, draw.solution.reversed.toList()), isTrue);
      expect(rules.solved(puzzle, [...draw.solution, 3, 3]), isTrue);
      final other = draw.solution.toSet().difference(_quiet4.toSet()).union(_quiet4.toSet().difference(draw.solution.toSet())).toList()..sort();
      expect(other, isNot(draw.solution));
      expect(other.length, greaterThanOrEqualTo(draw.solution.length));
      expect(rules.solved(puzzle, other), isTrue);
      expect(rules.solved(puzzle, draw.solution.sublist(1)), isFalse);
      expect(rules.solved(puzzle, [...draw.solution, 16]), isFalse);
      expect(rules.solved(puzzle, [...draw.solution, -1]), isFalse);
      // 多点偶数下同一格不改局面，只有长度上限能拦住。
      expect(rules.solved(puzzle, [...draw.solution, ...List.filled(lightsMaxPresses, 0)]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = rules.generate(11, PuzzleTier.expert);
      final puzzle = rules.decodePuzzle(jsonDecode(jsonEncode(rules.encodePuzzle(draw.puzzle))));
      expect(puzzle.side, 7);
      expect(puzzle.lit, draw.puzzle.lit);
      expect(rules.solved(puzzle, rules.decodeAnswer(jsonDecode(jsonEncode(rules.encodeAnswer(draw.solution))))), isTrue);
      for (final bad in <Object?>[
        null,
        '011111111',
        {'side': 2, 'lights': '0111'},
        {'side': 8, 'lights': '0${'1' * 63}'},
        {'side': '3', 'lights': '011111111'},
        {'side': 3, 'lights': 11111111},
        {'side': 3, 'lights': '01111111'},
        {'side': 3, 'lights': '01111111x'},
        {'side': 3, 'lights': '111111111'},
        {'side': 5, 'lights': '0${'1' * 24}'},
      ]) {
        expect(() => rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(rules.decodePuzzle({'side': 3, 'lights': '011111111'}).lit.first, isFalse);
      expect(() => rules.decodeAnswer('0'), throwsFormatException);
      expect(() => rules.decodeAnswer([49]), throwsFormatException);
      expect(() => rules.decodeAnswer([-1]), throwsFormatException);
      expect(() => rules.decodeAnswer([1.5]), throwsFormatException);
      expect(() => rules.decodeAnswer(List.filled(lightsMaxPresses + 1, 0)), throwsFormatException);
      expect(rules.decodeAnswer(List.filled(lightsMaxPresses, 0)), hasLength(lightsMaxPresses));
    });

    test('登记在格子谜题，能进挑战', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'lights');
      expect(game.group, gridGroup);
      expect(game.challengeable, isTrue);
    });
  });

  group('点灯对局页', () {
    testWidgets('点格翻转十字，几盏一起过渡；撤销退回；卡片边上也算最近那一格；点完先从中心亮一圈再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, seed: 1);
      final draw = const LightsRules().generate(1, PuzzleTier.entry);
      final least = draw.solution.length;
      final lit = [...draw.puzzle.lit];
      String state(int cell) => '第${cell ~/ 3 + 1}行第${cell % 3 + 1}列，${lit[cell] ? '亮' : '灭'}';
      void expectBoard() {
        for (var cell = 0; cell < 9; cell++) {
          expect(find.bySemanticsLabel(state(cell)), findsOneWidget, reason: state(cell));
        }
      }

      expect(_status(0, least), findsOneWidget);
      expectBoard();

      // 点正中：它和上下左右五盏一起翻；过渡中途的颜色在两头之间，走完才到位。
      final middle = tester.getCenter(_cell(1, 1));
      final before = await _colorAt(tester, middle);
      await _tapOn(tester, _cell(1, 1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final halfway = await _colorAt(tester, middle);
      await _step(tester);
      final after = await _colorAt(tester, middle);
      expect(_distance(before, after), greaterThan(60));
      expect(_distance(halfway, before), greaterThan(10));
      expect(_distance(halfway, after), greaterThan(10));
      lightsPress(lit, 3, 4);
      expectBoard();
      expect(_status(1, least), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      lightsPress(lit, 3, 4);
      expectBoard();
      expect(_status(0, least), findsOneWidget);

      // 卡片左上角的边（在第一格外面）归第一格。
      await tester.tapAt(tester.getRect(_cell(0, 0)).topLeft - const Offset(3, 3));
      await _step(tester);
      lightsPress(lit, 3, 0);
      expectBoard();
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      lightsPress(lit, 3, 0);

      for (final cell in draw.solution) {
        await _tapOn(tester, _cell(cell ~/ 3, cell % 3));
        await _step(tester);
      }
      // 收尾：正中那盏先亮一下（比解开后的样子更亮），亮完才弹结果。
      final settled = await _colorAt(tester, middle);
      var brightest = 0.0;
      for (var frame = 0; frame < 30 && find.text('新纪录').evaluate().isEmpty; frame++) {
        brightest = math.max(brightest, _distance(await _colorAt(tester, middle), settled));
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(brightest, greaterThan(10));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('$least 步，正好最少'), findsOneWidget);
      expect(store.best('lights', PuzzleTier.entry)!.moves, least);
      for (var cell = 0; cell < 9; cell++) {
        expect(find.bySemanticsLabel('第${cell ~/ 3 + 1}行第${cell % 3 + 1}列，亮'), findsOneWidget);
      }

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(_cell(3, 3), findsOneWidget);
      expect(store.tierOf('lights'), PuzzleTier.easy);
      expect(_status(0, const LightsRules().generate(1, PuzzleTier.easy).solution.length), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('减少动画：点下去直接到位，解开不放收尾直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 4);
      final draw = const LightsRules().generate(4, PuzzleTier.entry);
      final first = draw.solution.first;
      final center = tester.getCenter(_cell(first ~/ 3, first % 3));
      final before = await _colorAt(tester, center);
      await _tapOn(tester, _cell(first ~/ 3, first % 3));
      await tester.pump();
      final now = await _colorAt(tester, center);
      await _step(tester);
      expect(_distance(now, before), greaterThan(60));
      expect(_distance(now, await _colorAt(tester, center)), lessThan(1));

      for (final cell in draw.solution.skip(1)) {
        await _tapOn(tester, _cell(cell ~/ 3, cell % 3));
        await tester.pump();
      }
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });
  });
}
