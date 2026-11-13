import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/loop/loop_page.dart';
import 'package:superxd/playground/puzzle/loop/loop_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

const _rules = LoopRules();
const _sides = {PuzzleTier.entry: 4, PuzzleTier.easy: 5, PuzzleTier.normal: 6, PuzzleTier.hard: 7, PuzzleTier.expert: 10};
final _app = GlobalKey();

PlaygroundGame get _game => playgroundCatalog.firstWhere((game) => game.id == 'loop');

LoopPuzzle _puzzleOf(int width, int height, [Map<(int, int), int> clues = const {}]) =>
    LoopPuzzle(width: width, height: height, clues: [for (var row = 0; row < height; row++) for (var column = 0; column < width; column++) clues[(row, column)] ?? -1]);

// 一组边是线、其余是叉的答案。
List<bool> _answer(LoopGrid grid, Set<int> lines) => [for (var edge = 0; edge < grid.edgeCount; edge++) lines.contains(edge)];

// 一格四周的边（绕一格的小圈）。
Set<int> _square(LoopGrid grid, int row, int column) => {for (var side = 0; side < 4; side++) grid.cellEdges[(row * grid.width + column) * 4 + side]};

Finder _cell(int row, int column) => find.bySemanticsLabel(RegExp('^第${row + 1}行第${column + 1}列，'));
String _label(WidgetTester tester, int row, int column) => tester.getSemantics(_cell(row, column)).label;

// 一格四条边的中点（上、右、下、左）与四个角上的点（左上、右上、右下、左下）：按读屏节点的位置算，不碰页面内部。
Offset _side(WidgetTester tester, int row, int column, int side) {
  final rect = tester.getRect(_cell(row, column));
  return [rect.topCenter, rect.centerRight, rect.bottomCenter, rect.centerLeft][side];
}

Offset _corner(WidgetTester tester, int row, int column, int corner) {
  final rect = tester.getRect(_cell(row, column));
  return [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft][corner];
}

// 一条边（按 LoopGrid 的下标）的中点。
Offset _edgePoint(WidgetTester tester, LoopPuzzle puzzle, int edge) {
  final grid = LoopGrid.of(puzzle.width, puzzle.height);
  if (grid.isHorizontal(edge)) {
    final row = edge ~/ puzzle.width, column = edge % puzzle.width;
    return row < puzzle.height ? _side(tester, row, column, 0) : _side(tester, row - 1, column, 2);
  }
  final index = edge - grid.horizontalCount, row = index ~/ (puzzle.width + 1), column = index % (puzzle.width + 1);
  return column < puzzle.width ? _side(tester, row, column, 3) : _side(tester, row, column - 1, 1);
}

// 按住从第一个点依次拖到后面各点（每步约 8 逻辑像素，每步出一帧），再松手。
Future<void> _drag(WidgetTester tester, List<Offset> points) async {
  final gesture = await tester.startGesture(points.first);
  await tester.pump();
  for (var index = 1; index < points.length; index++) {
    final from = points[index - 1], to = points[index];
    final steps = ((to - from).distance / 8).ceil();
    for (var step = 0; step < steps; step++) {
      await gesture.moveBy((to - from) / steps.toDouble());
      await tester.pump();
    }
  }
  await gesture.up();
  await tester.pump();
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；操作后只推进固定时长。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _act(WidgetTester tester, Finder finder, String label) {
  final node = tester.getSemantics(finder);
  final id = CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label));
  expect(node.getSemanticsData().customSemanticsActionIds, contains(id), reason: label);
  node.owner!.performAction(node.id, SemanticsAction.customAction, id);
}

FilledButton _undoButton(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销'));

// 画面上某一点的颜色（按逻辑像素取）：用来看数字的颜色与收尾过渡，不碰页面内部。测试字体的字形是实心方块，数字中心就是字的颜色。
Future<Color> _colorAt(WidgetTester tester, Offset point) async => (await tester.runAsync(() async {
  final boundary = _app.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage();
  final bytes = (await image.toByteData())!;
  final offset = (point.dy.round() * image.width + point.dx.round()) * 4;
  image.dispose();
  return Color.fromARGB(bytes.getUint8(offset + 3), bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2));
}))!;

double _distance(Color left, Color right) => ((left.r - right.r).abs() + (left.g - right.g).abs() + (left.b - right.b).abs()) * 255;

// 记下触感：画线是选择触感，被拦下是重震。
List<String> _haptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

// 打开对局页（读屏导航开着：每格一个节点，测试按节点的位置点边）。
Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  final store = PlaygroundStore.memory();
  await store.chooseTier('loop', tier);
  await tester.pumpWidget(RepaintBoundary(key: _app, child: MaterialApp(theme: campusTheme(), home: LoopPage(game: _game, store: store, seeds: () => seed))));
  await tester.pumpAndSettle();
  return store;
}

void main() {
  group('推理规则', () {
    test('数字：线已够数其余是叉；未定的全算上才够数，全是线', () {
      final grid = LoopGrid.of(4, 4);
      final zero = loopDeduce(_puzzleOf(4, 4, {(1, 1): 0}))!;
      expect([for (final edge in _square(grid, 1, 1)) zero[edge]], everyElement(isFalse));
      // 0 挨着 3：中间那条是叉，3 剩下的三条只能都是线。
      final three = loopDeduce(_puzzleOf(4, 4, {(1, 1): 0, (1, 2): 3}))!;
      expect([three[grid.horizontal(1, 2)], three[grid.vertical(1, 3)], three[grid.horizontal(2, 2)]], [true, true, true]);
      expect(three[grid.vertical(1, 2)], isFalse);
      // 2 已有上边与左边两条线：右边、下边是叉（这两条不碰那两条线的交点，只能是数字推出来的）。
      final two = loopDeduce(_puzzleOf(4, 4, {(1, 1): 2}), given: {grid.horizontal(1, 1): true, grid.vertical(1, 1): true})!;
      expect([two[grid.vertical(1, 2)], two[grid.horizontal(2, 1)]], [false, false]);
      // 2 只有上边一条线：还差一条在哪不知道，其余三条都还不能定（推多了就是错的）。
      final open = loopDeduce(_puzzleOf(4, 4, {(1, 1): 2}), given: {grid.horizontal(1, 1): true})!;
      expect([open[grid.vertical(1, 2)], open[grid.horizontal(2, 1)], open[grid.vertical(1, 1)]], [null, null, null]);
    });

    test('点：已有两条线其余是叉；一条线只剩一条未定边就接上；没有线只剩一条未定边就是叉', () {
      final grid = LoopGrid.of(4, 4);
      final crowded = loopDeduce(_puzzleOf(4, 4), given: {grid.horizontal(1, 1): true, grid.vertical(1, 1): true})!;
      expect([crowded[grid.vertical(0, 1)], crowded[grid.horizontal(1, 0)]], [false, false]);
      // 左上角的点只有两条边。
      expect(loopDeduce(_puzzleOf(4, 4), given: {grid.horizontal(0, 0): true})![grid.vertical(0, 0)], isTrue);
      expect(loopDeduce(_puzzleOf(4, 4), given: {grid.horizontal(0, 0): false})![grid.vertical(0, 0)], isFalse);
      // 线走进死角（另一头只剩叉）：矛盾。
      expect(loopDeduce(_puzzleOf(4, 4), given: {grid.horizontal(0, 0): true, grid.vertical(0, 0): false}), isNull);
    });

    test('不能提前闭合：一段线两头相邻、外面还有别的线，中间那条是叉；没有别的线时不定', () {
      final grid = LoopGrid.of(4, 4);
      final cup = {grid.horizontal(1, 1): true, grid.vertical(1, 1): true, grid.vertical(1, 2): true};
      expect(loopDeduce(_puzzleOf(4, 4), given: {...cup, grid.horizontal(4, 3): true})![grid.horizontal(2, 1)], isFalse);
      expect(loopDeduce(_puzzleOf(4, 4), given: cup)![grid.horizontal(2, 1)], isNull);
      // 已经闭合成圈，外面还有线：矛盾；圈正好是全部的线：其余边都是叉。
      expect(loopDeduce(_puzzleOf(4, 4), given: {for (final edge in _square(grid, 1, 1)) edge: true, grid.horizontal(4, 3): true}), isNull);
      final closed = loopDeduce(_puzzleOf(4, 4), given: {for (final edge in _square(grid, 1, 1)) edge: true})!;
      expect(closed.where((value) => value == null), isEmpty);
      expect(closed.where((value) => value == true).length, 4);
    });

    test('格角：角落的 3 两条外边都是线，角落的 1 两条外边都是叉', () {
      final grid = LoopGrid.of(4, 4);
      final three = loopDeduce(_puzzleOf(4, 4, {(0, 0): 3}))!;
      expect([three[grid.horizontal(0, 0)], three[grid.vertical(0, 0)]], [true, true]);
      final one = loopDeduce(_puzzleOf(4, 4, {(0, 0): 1}))!;
      expect([one[grid.horizontal(0, 0)], one[grid.vertical(0, 0)]], [false, false]);
      // 右下角同理（按角的方向都走同一套）。
      final corner = loopDeduce(_puzzleOf(4, 4, {(3, 3): 3}))!;
      expect([corner[grid.horizontal(4, 3)], corner[grid.vertical(3, 4)]], [true, true]);
    });

    test('圈里圈外：一行格的竖边里线是双数条，只剩一条没定就定下', () {
      // 取中间一行：这一行的点上下都还有未定的边，光靠点与格角推不出来，只能按圈里圈外。
      final grid = LoopGrid.of(5, 3);
      final odd = loopDeduce(_puzzleOf(5, 3), given: {grid.vertical(1, 0): true, for (var column = 1; column < 5; column++) grid.vertical(1, column): false})!;
      expect(odd[grid.vertical(1, 5)], isTrue);
      final even = loopDeduce(_puzzleOf(5, 3), given: {grid.vertical(1, 0): true, grid.vertical(1, 1): true, for (var column = 2; column < 5; column++) grid.vertical(1, column): false})!;
      expect(even[grid.vertical(1, 5)], isFalse);
    });

    test('连通：两段线被一圈叉隔开、永远连不成一个圈，就是矛盾', () {
      final grid = LoopGrid.of(6, 3);
      final wall = {for (var line = 0; line <= 3; line++) grid.horizontal(line, 2): false};
      final segments = {grid.horizontal(1, 0): true, grid.horizontal(1, 4): true};
      expect(loopDeduce(_puzzleOf(6, 3), given: {...wall, ...segments}), isNull);
      expect(loopDeduce(_puzzleOf(6, 3), given: segments), isNotNull);
      expect(loopDeduce(_puzzleOf(6, 3), given: {...wall, grid.horizontal(1, 0): true}), isNotNull);
    });
  });

  group('求解器', () {
    test('数解：没有数字时 1×1 有 1 个圈、2×2 有 13 个、3×3 有 213 个（点阵上的简单回路数）', () {
      expect(loopSolve(_puzzleOf(1, 1), limit: 1000).count, 1);
      expect(loopSolve(_puzzleOf(2, 2), limit: 1000).count, 13);
      expect(loopSolve(_puzzleOf(3, 3), limit: 1000).count, 213);
      // 3×3 中间一个 0、四边中间各一个 1：只剩绕外圈一种；只给中间的 0 和两个角的 2 还有 16 种。
      const ringClues = {(1, 1): 0, (0, 1): 1, (1, 0): 1, (1, 2): 1, (2, 1): 1};
      final ring = loopSolve(_puzzleOf(3, 3, ringClues), limit: 1000);
      expect(ring.count, 1);
      expect(_rules.solved(_puzzleOf(3, 3, ringClues), ring.first!), isTrue);
      expect(ring.first!.where((line) => line).length, 12);
      expect(loopSolve(_puzzleOf(3, 3, {(1, 1): 0, (0, 0): 2, (2, 2): 2}), limit: 1000).count, 16);
      // 数字矛盾：没有解。
      expect(loopSolve(_puzzleOf(2, 2, {(0, 0): 0, (1, 1): 3})).count, 0);
    });

    test('数到第 2 个解就停，比数完全部试探得少', () {
      final stopped = loopSolve(_puzzleOf(3, 3));
      final all = loopSolve(_puzzleOf(3, 3), limit: 1000);
      expect(stopped.count, 2);
      expect(stopped.branches, lessThan(all.branches));
      expect(loopSolve(_puzzleOf(3, 3), limit: 1).count, 1);
    });
  });

  group('规则', () {
    test('每档出 10 道：边长对、唯一解、参考解判定通过；入门简单只靠推理就解开，困难专家要用到试探；同一个种子出同一道题', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 10; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect((puzzle.width, puzzle.height), (_sides[tier], _sides[tier]), reason: '$tier $seed');
          final result = loopSolve(puzzle);
          expect(result.count, 1, reason: '$tier $seed 要唯一');
          expect(result.first, draw.solution, reason: '$tier $seed');
          expect(_rules.solved(puzzle, draw.solution), isTrue);
          expect(_rules.solved(puzzle, List.filled(draw.solution.length, false)), isFalse);
          expect(puzzle.clues.where((clue) => clue >= 0), isNotEmpty);
          if (tier.index <= PuzzleTier.easy.index) expect(result.branches, 0, reason: '$tier $seed 不该要试探');
          if (tier.index >= PuzzleTier.hard.index) expect(result.branches, greaterThan(0), reason: '$tier $seed 光靠推理不该推完');
        }
      }
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.clues, _rules.generate(7, PuzzleTier.hard).puzzle.clues);
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.clues, isNot(_rules.generate(8, PuzzleTier.hard).puzzle.clues));
    });

    test('数字没有多余：入门简单拿掉任何一个就要试探或不唯一，普通困难拿掉任何一个就不唯一；专家极少数证明太长的留着（每道至多 1 个）', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < (tier == PuzzleTier.expert ? 3 : 10); seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          var spare = 0;
          for (var cell = 0; cell < puzzle.clues.length; cell++) {
            if (puzzle.clues[cell] < 0) continue;
            final result = loopSolve(LoopPuzzle(width: puzzle.width, height: puzzle.height, clues: [...puzzle.clues]..[cell] = -1));
            final needed = result.count == 2 || tier.index <= PuzzleTier.easy.index && result.branches > 0;
            if (!needed) spare++;
          }
          expect(spare, tier == PuzzleTier.expert ? lessThanOrEqualTo(1) : 0, reason: '$tier $seed 多余的数字');
        }
      }
    });

    test('出题耗时：每档 10 道都在上限内（专家 10 见方单道几十毫秒，留足机器差）', () {
      const limits = {PuzzleTier.entry: 1000, PuzzleTier.easy: 1000, PuzzleTier.normal: 1000, PuzzleTier.hard: 1500, PuzzleTier.expert: 4000};
      for (final tier in PuzzleTier.values) {
        final watch = Stopwatch()..start();
        var slowest = 0;
        for (var seed = 100; seed < 110; seed++) {
          final single = Stopwatch()..start();
          _rules.generate(seed, tier);
          if (single.elapsedMilliseconds > slowest) slowest = single.elapsedMilliseconds;
        }
        expect(watch.elapsedMilliseconds, lessThan(limits[tier]!), reason: '$tier');
        expect(slowest, lessThan(limits[tier]! ~/ 2), reason: '$tier 最慢一道');
      }
    });

    test('难度分：1–10，同档最多差 1 分，下一档最低不低于上一档最高，平均分逐档上升', () {
      final scores = {for (final tier in PuzzleTier.values) tier: [for (var seed = 0; seed < 10; seed++) _rules.difficulty(_rules.generate(seed, tier).puzzle)]};
      double average(List<int> values) => values.reduce((sum, value) => sum + value) / values.length;
      int lowest(List<int> values) => values.reduce((a, b) => a < b ? a : b);
      int highest(List<int> values) => values.reduce((a, b) => a > b ? a : b);
      for (final (index, tier) in PuzzleTier.values.indexed) {
        final list = scores[tier]!;
        expect(list, everyElement(inInclusiveRange(1, 10)));
        expect(highest(list) - lowest(list), lessThanOrEqualTo(1), reason: '$tier $list');
        if (index == 0) continue;
        final previous = scores[PuzzleTier.values[index - 1]]!;
        expect(lowest(list), greaterThanOrEqualTo(highest(previous)), reason: '$tier');
        expect(average(list), greaterThan(average(previous)), reason: '$tier');
      }
      expect(scores[PuzzleTier.entry], everyElement(lessThanOrEqualTo(2)));
      expect(scores[PuzzleTier.expert], everyElement(greaterThanOrEqualTo(9)));
    });

    test('按规则判定：任何合规的回路都算；两个圈、分叉、交叉、没闭合、数字对不上、长度不对都不算', () {
      final grid = LoopGrid.of(3, 3);
      final blank = _puzzleOf(3, 3);
      // 不和参考解逐项比：没有数字时随便一个圈都算。
      expect(_rules.solved(blank, _answer(grid, _square(grid, 0, 0))), isTrue);
      expect(_rules.solved(blank, _answer(grid, _square(grid, 2, 1))), isTrue);
      final ring = {for (var column = 0; column < 3; column++) ...{grid.horizontal(0, column), grid.horizontal(3, column)}, for (var row = 0; row < 3; row++) ...{grid.vertical(row, 0), grid.vertical(row, 3)}};
      expect(_rules.solved(blank, _answer(grid, ring)), isTrue);
      // 两个圈。
      expect(_rules.solved(blank, _answer(grid, {..._square(grid, 0, 0), ..._square(grid, 2, 2)})), isFalse);
      // 两个圈只在一个点上碰到（8 字，交叉点连了四条线）。
      expect(_rules.solved(blank, _answer(grid, {..._square(grid, 0, 0), ..._square(grid, 1, 1)})), isFalse);
      // 分叉：圈上多伸出一条。
      expect(_rules.solved(blank, _answer(grid, {...ring, grid.horizontal(1, 0)})), isFalse);
      // 没闭合：少一条。
      expect(_rules.solved(blank, _answer(grid, ring.difference({grid.vertical(1, 0)}))), isFalse);
      expect(_rules.solved(blank, _answer(grid, {})), isFalse);
      // 数字对不上：中间写着 1 的格，外圈一条也不碰它。
      expect(_rules.solved(_puzzleOf(3, 3, {(1, 1): 1}), _answer(grid, ring)), isFalse);
      expect(_rules.solved(_puzzleOf(3, 3, {(1, 1): 0, (0, 0): 2}), _answer(grid, ring)), isTrue);
      expect(_rules.solved(blank, _answer(grid, ring).sublist(1)), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException，不唯一与无解的题拒收', () {
      final draw = _rules.generate(9, PuzzleTier.expert);
      final puzzle = _rules.decodePuzzle(_rules.encodePuzzle(draw.puzzle));
      expect((puzzle.width, puzzle.height), (10, 10));
      expect(puzzle.clues, draw.puzzle.clues);
      final answer = _rules.decodeAnswer(_rules.encodeAnswer(draw.solution));
      expect(answer, draw.solution);
      expect(_rules.solved(puzzle, answer), isTrue);
      expect(_rules.decodeAnswer(''), isEmpty);
      final unique = _rules.encodePuzzle(_rules.generate(1, PuzzleTier.entry).puzzle) as Map;
      for (final bad in <Object?>[
        null,
        'loop',
        {...unique, 'width': 1},
        {...unique, 'width': loopMaxSide + 1},
        {...unique, 'height': '4'},
        {...unique, 'clues': (unique['clues'] as List).sublist(1)},
        {...unique, 'clues': [...(unique['clues'] as List).sublist(1), 4]},
        {...unique, 'clues': [...(unique['clues'] as List).sublist(1), -2]},
        {...unique, 'clues': [...(unique['clues'] as List).sublist(1), 1.5]},
        {...unique, 'clues': '0123'},
        // 没有数字：不止一个解。
        {'width': 3, 'height': 3, 'clues': List.filled(9, -1)},
        // 数字互相矛盾：没有解。
        {'width': 2, 'height': 2, 'clues': [0, -1, -1, 3]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>[null, 101, '0102', [1, 0], '1' * (LoopGrid.of(loopMaxSide, loopMaxSide).edgeCount + 1)]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('对局页', () {
    testWidgets('点一条边画线、再点取消；切到标叉点边标叉；撤销按笔退回', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 1);
      expect(_undoButton(tester).onPressed, isNull);
      await tester.tapAt(_side(tester, 1, 1, 0));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('1条线：上边'));
      expect(_label(tester, 0, 1), contains('1条线：下边'));
      expect(haptics.last, 'HapticFeedbackType.selectionClick');
      await tester.tapAt(_side(tester, 1, 1, 0));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('没有线'));

      await tester.tap(find.text('标叉'));
      await _step(tester);
      await tester.tapAt(_side(tester, 1, 1, 1));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('叉：右边'));
      expect(_label(tester, 1, 2), contains('叉：左边'));
      // 落在格子中间偏下：归最近的下边。
      final rect = tester.getRect(_cell(1, 1));
      await tester.tapAt(rect.center + Offset(0, rect.height * .3));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('叉：右边、下边'));

      // 撤销三次：先退回两次标叉，再退回「取消」（线回来），再退回「画线」。
      for (final expected in ['叉：右边', '没有线', '1条线：上边', '没有线']) {
        await tester.tap(find.widgetWithText(FilledButton, '撤销'));
        await _step(tester);
        expect(_label(tester, 1, 1), contains(expected));
      }
      expect(_undoButton(tester).onPressed, isNull);
      semantics.dispose();
    });

    testWidgets('按住沿着点拖动连着画、拐弯也跟着走；起点那条已是线时这一笔擦掉；一笔撤销整笔退回', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 1);
      // 从左上角的点沿第一行拖到第 3 格右上角：三段都画上。
      await _drag(tester, [_corner(tester, 0, 0, 0), _corner(tester, 0, 2, 1)]);
      await _step(tester);
      for (var column = 0; column < 3; column++) {
        expect(_label(tester, 0, column), contains('上边'), reason: '第 ${column + 1} 格');
      }
      expect(_label(tester, 0, 3), contains('没有线'));
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      for (var column = 0; column < 3; column++) {
        expect(_label(tester, 0, column), contains('没有线'));
      }

      // 从一条边的中间起笔（先改这条），往右拖再往下拐：经过的边都画上。
      await _drag(tester, [_side(tester, 2, 0, 0), _corner(tester, 2, 1, 1), _corner(tester, 2, 1, 2)]);
      await _step(tester);
      expect(_label(tester, 2, 0), contains('1条线：上边'));
      expect(_label(tester, 2, 1), contains('2条线：上边、右边'));
      // 起点那条已是线：这一笔是擦掉，拖过的线都擦掉。
      await _drag(tester, [_corner(tester, 2, 0, 0), _corner(tester, 2, 1, 1)]);
      await _step(tester);
      expect(_label(tester, 2, 0), contains('没有线'));
      expect(_label(tester, 2, 1), contains('1条线：右边'));
      // 落在点上原地松手：按落点最近的那条边改。
      await tester.tapAt(_corner(tester, 3, 3, 2) + const Offset(-6, -1));
      await _step(tester);
      expect(_label(tester, 3, 3), contains('1条线：下边'));
      semantics.dispose();
    });

    testWidgets('一个点要连出第三条线时不画：重震、提示原因；接着正常画一笔就收起提示', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 1);
      await tester.tapAt(_side(tester, 1, 1, 0));
      await _step(tester);
      await tester.tapAt(_side(tester, 1, 1, 3));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('2条线：上边、左边'));
      // 第 2 行第 1 格的上边也连到那个点：分叉。
      await tester.tapAt(_side(tester, 1, 0, 0));
      await _step(tester);
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('线不能分叉，也不能交叉'), findsOneWidget);
      expect(_label(tester, 1, 0), isNot(contains('上边')));
      // 拖着穿过已有的线（交叉）也拦下，只震一次。
      final before = haptics.where((call) => call == 'HapticFeedbackType.heavyImpact').length;
      await _drag(tester, [_corner(tester, 0, 1, 0), _corner(tester, 1, 1, 3)]);
      await _step(tester);
      expect(haptics.where((call) => call == 'HapticFeedbackType.heavyImpact').length, before + 1);
      expect(_label(tester, 0, 1), contains('下边'));
      expect(_label(tester, 0, 0), isNot(contains('右边')));
      // 被拦下的那一下不算一笔：撤销退回的是左边那条。
      hideCampusToast();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_label(tester, 1, 1), contains('1条线：上边'));

      // 再拦一次（补回左边，再点那条会分叉的），然后在别处正常画一笔：过时的提示收起。
      await tester.tapAt(_side(tester, 1, 1, 3));
      await _step(tester);
      await tester.tapAt(_side(tester, 1, 0, 0));
      await _step(tester);
      expect(find.text('线不能分叉，也不能交叉'), findsOneWidget);
      await tester.tapAt(_side(tester, 0, 3, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.text('线不能分叉，也不能交叉'), findsNothing);
      expect(_label(tester, 0, 3), contains('上边'));
      semantics.dispose();
    });

    testWidgets('数字：周围的线比数字多标警示色（读屏读「多了几条」），正好时变淡', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 1);
      final puzzle = _rules.generate(1, PuzzleTier.entry).puzzle;
      final cell = puzzle.clues.indexWhere((clue) => clue >= 1);
      final (row, column, clue) = (cell ~/ 4, cell % 4, puzzle.clues[cell]);
      final palette = CampusPalette.of(tester.element(find.byType(LoopPage)));
      final center = tester.getCenter(_cell(row, column));
      final normal = await _colorAt(tester, center);
      expect(_distance(normal, palette.onSurface), lessThan(12));
      for (var side = 0; side < clue; side++) {
        await tester.tapAt(_side(tester, row, column, side));
        await _step(tester);
      }
      final done = await _colorAt(tester, center);
      expect(_distance(done, normal), greaterThan(40), reason: '正好时变淡');
      expect(_distance(done, palette.danger), greaterThan(40));
      await tester.tapAt(_side(tester, row, column, clue));
      await _step(tester);
      expect(_distance(await _colorAt(tester, center), palette.danger), lessThan(12), reason: '多了标警示色');
      expect(_label(tester, row, column), contains('多了1条'));
      semantics.dispose();
    });

    testWidgets('按参考解画完：线条过渡成激活色、圈里铺一层淡色，再弹新纪录；换到下一档换一道 5×5', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = await _open(tester, seed: 3);
      final draw = _rules.generate(3, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      final grid = LoopGrid.of(4, 4);
      final edges = [for (var edge = 0; edge < draw.solution.length; edge++) if (draw.solution[edge]) edge];
      late Color drawn;
      for (final (index, edge) in edges.indexed) {
        // 数字都对上了还没闭合时会弹提示条，它接住点在它上面的点按：先收起再点。
        hideCampusToast();
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        // 最后一笔之前记下线本来的颜色。
        if (index == edges.length - 1) drawn = await _colorAt(tester, _edgePoint(tester, puzzle, edges.first));
        await tester.tapAt(_edgePoint(tester, puzzle, edge));
        await tester.pump();
      }
      expect(find.text('新纪录'), findsNothing);
      // 收尾过渡中途：线已从本来的颜色往激活色走、还没走到；圈里没有数字的格比圈外的深一点。
      await tester.pump(const Duration(milliseconds: 350));
      final palette = CampusPalette.of(tester.element(find.byType(LoopPage)));
      final line = await _colorAt(tester, _edgePoint(tester, puzzle, edges.first));
      expect(_distance(line, drawn), greaterThan(20));
      expect(_distance(line, palette.accent), greaterThan(20));
      final inside = <int>{};
      for (var row = 0; row < 4; row++) {
        var within = false;
        for (var column = 0; column < 4; column++) {
          if (draw.solution[grid.vertical(row, column)]) within = !within;
          if (within) inside.add(row * 4 + column);
        }
      }
      final blankInside = inside.firstWhere((cell) => puzzle.clues[cell] < 0);
      final blankOutside = [for (var cell = 0; cell < 16; cell++) cell].firstWhere((cell) => !inside.contains(cell) && puzzle.clues[cell] < 0);
      final tinted = await _colorAt(tester, tester.getCenter(_cell(blankInside ~/ 4, blankInside % 4)));
      final plain = await _colorAt(tester, tester.getCenter(_cell(blankOutside ~/ 4, blankOutside % 4)));
      expect(_distance(tinted, plain), greaterThan(4));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('4×4'), findsWidgets);
      expect(store.best('loop', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('loop'), PuzzleTier.easy);
      expect(find.textContaining('5×5'), findsOneWidget);
      expect(_label(tester, 4, 4), contains('没有线'));
      semantics.dispose();
    });

    testWidgets('10×10 格子不到 48：双指张开放大到 48，第二根手指落下时这一笔作废、不算一步', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 2, tier: PuzzleTier.expert);
      final before = tester.getRect(_cell(5, 5));
      expect(before.width, lessThan(48));
      final first = await tester.startGesture(before.topCenter);
      await tester.pump();
      // 第一根手指已经把上边画上了。
      expect(_label(tester, 5, 5), contains('上边'));
      final second = await tester.startGesture(before.center + const Offset(30, 0));
      await tester.pump();
      expect(_label(tester, 5, 5), contains('没有线'));
      for (var step = 0; step < 6; step++) {
        await first.moveBy(const Offset(-10, 0));
        await second.moveBy(const Offset(10, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await _step(tester);
      final after = tester.getRect(_cell(5, 5));
      expect(after.width, greaterThan(before.width * 1.15));
      expect(after.width, lessThanOrEqualTo(48.01));
      expect(_undoButton(tester).onPressed, isNull);
      semantics.dispose();
    });

    // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）约 18dp 就认横向拖动：棋盘上的拖动必须归棋盘。
    testWidgets('iOS 上棋盘里横着拖动画线，不触发页面右滑返回', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final store = PlaygroundStore.memory();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
      unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => LoopPage(game: _game, store: store, seeds: () => 1))));
      await tester.pumpAndSettle();
      final from = _corner(tester, 1, 0, 0), to = _corner(tester, 1, 3, 1);
      final gesture = await tester.startGesture(from);
      final steps = ((to.dx - from.dx) / 12).ceil();
      for (var step = 0; step < steps; step++) {
        await gesture.moveBy(Offset((to.dx - from.dx) / steps, 0));
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LoopPage), findsOneWidget);
      expect(tester.getTopLeft(find.byType(LoopPage)).dx, 0);
      for (var column = 0; column < 4; column++) {
        expect(_label(tester, 1, column), contains('上边'));
      }
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('读屏：每格读出位置、数字与线数，四条边各一个操作，按当前模式画线、擦掉或标叉', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 1);
      final puzzle = _rules.generate(1, PuzzleTier.entry).puzzle;
      final clued = puzzle.clues.indexWhere((clue) => clue >= 0), blank = puzzle.clues.indexWhere((clue) => clue < 0);
      final (row, column) = (clued ~/ 4, clued % 4);
      expect(_label(tester, row, column), '第${row + 1}行第${column + 1}列，数字${puzzle.clues[clued]}，没有线');
      expect(_label(tester, blank ~/ 4, blank % 4), '第${blank ~/ 4 + 1}行第${blank % 4 + 1}列，没有数字，没有线');

      _act(tester, _cell(row, column), '上边画线');
      await _step(tester);
      expect(_label(tester, row, column), contains('1条线：上边'));
      _act(tester, _cell(row, column), '擦掉上边的线');
      await _step(tester);
      expect(_label(tester, row, column), contains('没有线'));
      await tester.tap(find.text('标叉'));
      await _step(tester);
      _act(tester, _cell(row, column), '右边标叉');
      await _step(tester);
      expect(_label(tester, row, column), contains('叉：右边'));
      expect(_undoButton(tester).onPressed, isNotNull);
      semantics.dispose();
    });
  });
}
