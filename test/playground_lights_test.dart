import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/lights/lights_page.dart';
import 'package:superxd/playground/puzzle/lights/lights_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

// 一种题（边长、形状、环面、级数）的全亮局面。
LightsPuzzle _lit(int side, {LightsShape shape = LightsShape.plus, bool wrap = false, int states = 2}) =>
    LightsPuzzle(side: side, cells: List.filled(side * side, states - 1), shape: shape, wrap: wrap, states: states);

// 从全亮开始依次点 presses 得到的题面。
LightsPuzzle _board(LightsPuzzle lit, Iterable<int> presses) {
  final cells = [...lit.cells];
  for (final cell in presses) {
    lightsPress(lit, cells, cell);
  }
  return lit.copyWith(cells: cells);
}

// 4×4 十字两态里「点了等于没点」的一组 8 格（零空间里的一个向量）。
const _quiet4 = [1, 2, 3, 4, 6, 8, 9, 12];

// 测试另写的影响范围（不用 lightsReach）：自己加十字或斜角四格，环面取模、不是环面出界不算。
List<int> _neighbors(LightsPuzzle puzzle, int cell) {
  final side = puzzle.side, row = cell ~/ side, column = cell % side;
  final steps = puzzle.shape == LightsShape.plus ? [[0, 0], [-1, 0], [1, 0], [0, -1], [0, 1]] : [[0, 0], [-1, -1], [-1, 1], [1, -1], [1, 1]];
  return [
    for (final [down, right] in steps)
      if (puzzle.wrap) ((row + down + side) % side) * side + (column + right + side) % side
      else if (row + down >= 0 && row + down < side && column + right >= 0 && column + right < side) (row + down) * side + column + right,
  ];
}

// 测试另写的穷举：每格点 0 到「级数减 1」下的全部组合都试一遍，记下每个局面最少点几下就全亮（只给 3×3 与 4×4 两态用，组合数不超过 65536）。
// 点这组能从局面 B 到全亮，就是 B = 全亮减去这组点下去加的级数（三态时和「从全亮点这组得到的局面」不一样）。
Map<String, int> _bruteLeast(LightsPuzzle kind) {
  final count = kind.side * kind.side, states = kind.states;
  final least = <String, int>{};
  final total = math.pow(states, count).toInt();
  for (var index = 0; index < total; index++) {
    final cells = List.filled(count, states - 1);
    var presses = 0;
    for (var cell = 0, rest = index; cell < count; cell++, rest ~/= states) {
      final times = rest % states;
      presses += times;
      for (final reached in _neighbors(kind, cell)) {
        cells[reached] = (cells[reached] - times) % states;
      }
    }
    final key = cells.join();
    if ((least[key] ?? presses + 1) > presses) least[key] = presses;
  }
  return least;
}

// 出题时每档预计用时的区间（同 lights_rules.dart 的 _window）与每档的题型（边长、形状、环面、级数，同 _kinds）。
const _windows = {PuzzleTier.entry: (38, 52), PuzzleTier.easy: (60, 80), PuzzleTier.normal: (96, 124), PuzzleTier.hard: (153, 176), PuzzleTier.expert: (250, 266)};
const _kinds = {
  PuzzleTier.entry: {'3p2', '4p2'},
  PuzzleTier.easy: {'5p2', '5d2', '3p3'},
  PuzzleTier.normal: {'6p2', '4pT2', '4p3'},
  PuzzleTier.hard: {'6d2', '6p3', '7pT2'},
  PuzzleTier.expert: {'6d3', '7dT2', '7pT3'},
};
String _kindOf(LightsPuzzle puzzle) => '${puzzle.side}${puzzle.shape == LightsShape.plus ? 'p' : 'd'}${puzzle.wrap ? 'T' : ''}${puzzle.states}';

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

// 某一档里第一道满足条件的题的种子（种子从 0 往上找）。
int _seedOf(PuzzleTier tier, bool Function(LightsPuzzle puzzle) wanted) => [for (var seed = 0; seed < 400; seed++) seed].firstWhere((seed) => wanted(const LightsRules().generate(seed, tier).puzzle));

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

    test('影响范围：十字是上下左右、斜十字是四个斜角，出界的不算；环面绕到对边；点一下往亮走一级，点满级数下复原', () {
      expect(lightsReach(_lit(3), 0)..sort(), [0, 1, 3]);
      expect(lightsReach(_lit(3), 5)..sort(), [2, 4, 5, 8]);
      expect(lightsReach(_lit(4), 5)..sort(), [1, 4, 5, 6, 9]);
      expect(lightsReach(_lit(3, shape: LightsShape.diagonal), 0)..sort(), [0, 4]);
      expect(lightsReach(_lit(3, shape: LightsShape.diagonal), 1)..sort(), [1, 3, 5]);
      expect(lightsReach(_lit(4, shape: LightsShape.diagonal), 5)..sort(), [0, 2, 5, 8, 10]);
      expect(lightsReach(_lit(4, wrap: true), 0)..sort(), [0, 1, 3, 4, 12]);
      expect(lightsReach(_lit(4, shape: LightsShape.diagonal, wrap: true), 0)..sort(), [0, 5, 7, 13, 15]);
      // 3×3 环面的十字正好是整行加整列。
      expect(lightsReach(_lit(3, wrap: true), 4)..sort(), [1, 3, 4, 5, 7]);
      expect(lightsReach(_lit(3, wrap: true), 0)..sort(), [0, 1, 2, 3, 6]);
      for (final lit in [_lit(5), _lit(5, shape: LightsShape.diagonal, wrap: true), _lit(4, states: 3), _lit(7, wrap: true, states: 3)]) {
        for (var cell = 0; cell < lit.cells.length; cell++) {
          expect(lightsReach(lit, cell)..sort(), _neighbors(lit, cell)..sort(), reason: '${_kindOf(lit)} $cell');
        }
      }
      final two = [...?lightsReplay(_lit(3), [4])];
      expect(two, [1, 0, 1, 0, 0, 0, 1, 0, 1]);
      expect(lightsReplay(_lit(3), [4, 4]), everyElement(1));
      final three = _lit(3, states: 3);
      expect(lightsReplay(three, [4]), [2, 0, 2, 0, 0, 0, 2, 0, 2]);
      expect(lightsReplay(three, [4, 4]), [2, 1, 2, 1, 1, 1, 2, 1, 2]);
      expect(lightsReplay(three, [4, 4, 4]), everyElement(2));
      expect(lightsReplay(three, [9]), isNull);
      expect(lightsReplay(three, [-1]), isNull);
    });

    test('手算小例：满秩时就是点过的那几格，三态点过一下的要再点两下，零空间取最省的一组，点不全亮的返回 null', () {
      expect(lightsSolve(_board(_lit(3), [4])), [4]);
      expect(lightsSolve(_board(_lit(7), [0, 24, 48])), [0, 24, 48]);
      expect(lightsSolve(_board(_lit(3, shape: LightsShape.diagonal), [0])), [0]);
      expect(lightsSolve(_board(_lit(4, wrap: true), [0, 15])), [0, 15]);
      // 三态：从全亮点一下，那几格到了灭，再点两下才回到亮；点两下的那格，再点一下就够。
      expect(lightsSolve(_board(_lit(3, states: 3), [4])), [4, 4]);
      expect(lightsSolve(_board(_lit(3, states: 3), [4, 4, 0])), [0, 0, 4]);
      expect(lightsSolve(_board(_lit(6, shape: LightsShape.diagonal, states: 3), [7, 7, 20])), [7, 20, 20]);
      expect(_board(_lit(4), _quiet4).cells, everyElement(1));
      // 点了零空间的 8 格再加一格：局面同只点那一格，最少 1 下。
      expect(lightsSolve(_board(_lit(4), [..._quiet4, 15])), [15]);
      // 5×5 只灭左上角一盏：和零空间不正交，怎么点都点不全亮。
      expect(lightsSolve(_lit(5).copyWith(cells: [0, ...List.filled(24, 1)])), isNull);
      // 零空间的维数：十字两态 4×4 是 4、5×5 是 2，3、6、7 满秩；4×4 环面满秩、3×3 与 5×5 环面都有；三态 3×3 满秩。
      expect({for (final lit in [_lit(3), _lit(4), _lit(5), _lit(6), _lit(7)]) lit.side: lightsSolutions(lit)!.basis.length}, {3: 0, 4: 4, 5: 2, 6: 0, 7: 0});
      expect([for (final side in [3, 4, 5]) lightsSolutions(_lit(side, wrap: true))!.basis.length], [4, 0, 8]);
      expect(lightsSolutions(_lit(3, states: 3))!.basis, isEmpty);
      // 全部解的个数是级数的维数次方，每一个都点得全亮。
      final board = _board(_lit(4, states: 3), [0, 5, 5, 10]);
      final solutions = lightsSolutions(board)!;
      final all = [for (final presses in solutions.all) [...presses]];
      expect(all, hasLength(math.pow(3, solutions.basis.length)));
      expect(all.map((presses) => presses.join()).toSet(), hasLength(all.length));
      for (final presses in all) {
        expect(rules.solved(board, [for (var cell = 0; cell < 16; cell++) for (var time = 0; time < presses[cell]; time++) cell]), isTrue);
      }
    });

    test('求解器同穷举：3×3 的 8 种规矩与 4×4 两态的 4 种规矩，随便摆的局面解不解得开、最少几下都和穷举一样', () {
      final random = math.Random(11);
      for (final side in [3, 4]) {
        for (final states in side == 3 ? [2, 3] : [2]) {
          for (final shape in LightsShape.values) {
            for (final wrap in [false, true]) {
              final kind = _lit(side, shape: shape, wrap: wrap, states: states);
              final least = _bruteLeast(kind);
              for (var trial = 0; trial < 120; trial++) {
                final cells = [for (var cell = 0; cell < side * side; cell++) random.nextInt(states)];
                final solved = lightsSolve(kind.copyWith(cells: cells));
                expect(solved?.length, least[cells.join()], reason: '${_kindOf(kind)} ${cells.join()}');
                if (solved != null) expect(lightsReplay(kind.copyWith(cells: cells), solved), everyElement(states - 1));
              }
            }
          }
        }
      }
    });

    test('每档出的题：题型是这一档的、预计用时在区间里、参考解就是最少点法且点得开；困难、专家满秩（不多点就是最少）', () {
      for (final tier in PuzzleTier.values) {
        final (low, high) = _windows[tier]!;
        for (var seed = 0; seed < 30; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect(_kinds[tier], contains(_kindOf(puzzle)), reason: '$tier $seed');
          expect(puzzle.allLit, isFalse);
          expect(rules.solved(puzzle, const []), isFalse);
          expect(rules.expectedSeconds(puzzle), inInclusiveRange(low, high), reason: '$tier $seed');
          expect(lightsSolve(puzzle), draw.solution);
          expect(rules.solved(puzzle, draw.solution), isTrue);
          expect(rules.minimum(puzzle), draw.solution.length);
          expect(rules.fragment(puzzle, draw.solution), draw.solution.length);
          if (tier.index >= PuzzleTier.hard.index) expect(lightsSolutions(puzzle)!.basis, isEmpty, reason: '$tier $seed 要满秩');
        }
      }
    });

    test('变体真起作用：拿掉斜十字或环面，同一个局面最少下数变了或解不开；三态的题没有每格最多点一下的解', () {
      var diagonal = 0, wrap = 0, three = 0;
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 30; seed++) {
          final draw = rules.generate(seed, tier);
          final puzzle = draw.puzzle, least = draw.solution.length;
          if (puzzle.shape == LightsShape.diagonal) {
            diagonal++;
            expect(lightsSolve(puzzle.copyWith(shape: LightsShape.plus))?.length, isNot(least), reason: '$tier $seed 斜十字');
          }
          if (puzzle.wrap) {
            wrap++;
            expect(lightsSolve(puzzle.copyWith(wrap: false))?.length, isNot(least), reason: '$tier $seed 环面');
          }
          if (puzzle.states == 3) {
            three++;
            expect(lightsSolutions(puzzle)!.all.where((presses) => presses.every((count) => count <= 1)), isEmpty, reason: '$tier $seed 三态');
            expect(draw.solution.length, greaterThan(draw.solution.toSet().length), reason: '$tier $seed 要有点两下的格');
          }
          expect(lightsMatters(puzzle, least), isTrue);
        }
      }
      expect([diagonal, wrap, three], everyElement(greaterThan(10)));
      // 反例：只点中间格的 5×5 环面，和不是环面时一样少，不算环面起作用；全是点一下的三态题也不算。
      expect(lightsMatters(_board(_lit(5, wrap: true), [12]), 1), isFalse);
      expect(lightsMatters(_board(_lit(3, states: 3), [4, 4]), 1), isFalse);
      expect(lightsMatters(_board(_lit(3, states: 3), [4]), 2), isTrue);
    });

    test('每档多样：几种题型都出、题面几乎不重样（入门的 3×3 一共只有几百种局面，40 道里偶尔撞一道）；同一个种子出同一道题', () {
      for (final tier in PuzzleTier.values) {
        final draws = [for (var seed = 0; seed < 40; seed++) rules.generate(seed, tier).puzzle];
        expect(draws.map(_kindOf).toSet(), _kinds[tier], reason: '$tier');
        expect(draws.map((puzzle) => jsonEncode(rules.encodePuzzle(puzzle))).toSet().length, greaterThanOrEqualTo(tier == PuzzleTier.entry ? 36 : 40), reason: '$tier');
      }
      expect(rules.generate(7, PuzzleTier.hard).puzzle.cells, rules.generate(7, PuzzleTier.hard).puzzle.cells);
      expect(rules.generate(7, PuzzleTier.expert).puzzle.cells, isNot(rules.generate(8, PuzzleTier.expert).puzzle.cells));
    });

    test('预计用时：五档中位数约 45、70、110、165、255 秒且逐档上升；难易分五档不重叠，难度分入门 3 到专家 7', () {
      const targets = {PuzzleTier.entry: 45, PuzzleTier.easy: 70, PuzzleTier.normal: 110, PuzzleTier.hard: 165, PuzzleTier.expert: 255};
      var previous = 0, lowerTop = 0;
      for (final tier in PuzzleTier.values) {
        final seconds = <int>[], scores = <int>{}, difficulty = <int>{};
        for (var seed = 1; seed <= 12; seed++) {
          final puzzle = rules.generate(seed * 7919, tier).puzzle;
          seconds.add(rules.expectedSeconds(puzzle));
          scores.add(rules.complexity(puzzle));
          difficulty.add(rules.difficulty(puzzle));
        }
        seconds.sort();
        final median = seconds[seconds.length ~/ 2];
        expect(median, inInclusiveRange(targets[tier]! * .9, targets[tier]! * 1.1), reason: '$tier $seconds');
        expect(median, greaterThan(previous));
        previous = median;
        expect(scores.reduce(math.min), greaterThan(lowerTop), reason: '$tier 难易分 $scores');
        lowerTop = scores.reduce(math.max);
        expect(difficulty, {tier.index + 3}, reason: '$tier');
      }
    });

    test('出题与判定耗时：出题最慢一次不超过 200 毫秒，解码加判定满 1024 下的答案不超过 100 毫秒', () {
      var slowest = Duration.zero;
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 20; seed++) {
          final watch = Stopwatch()..start();
          rules.generate(seed * 104729, tier);
          if (watch.elapsed > slowest) slowest = watch.elapsed;
        }
      }
      expect(slowest, lessThan(const Duration(milliseconds: 200)));
      for (final tier in [PuzzleTier.hard, PuzzleTier.expert]) {
        final draw = rules.generate(3, tier);
        final json = rules.encodePuzzle(draw.puzzle);
        final answer = [...draw.solution, ...List.filled(lightsMaxPresses - draw.solution.length, 0)];
        final watch = Stopwatch()..start();
        final puzzle = rules.decodePuzzle(jsonDecode(jsonEncode(json)));
        rules.solved(puzzle, rules.decodeAnswer(answer));
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 100)), reason: '$tier');
      }
    });

    test('按规则判定，不和参考解逐项比：换顺序、多点一整圈、零空间里的另一组解都算；少点、越界与超长不算', () {
      final draw = rules.generate(2, PuzzleTier.entry);
      final four = _seedOf(PuzzleTier.entry, (puzzle) => puzzle.side == 4);
      final board = rules.generate(four, PuzzleTier.entry);
      final puzzle = board.puzzle;
      expect(rules.solved(puzzle, board.solution.reversed.toList()), isTrue);
      expect(rules.solved(puzzle, [...board.solution, 3, 3]), isTrue);
      final other = board.solution.toSet().difference(_quiet4.toSet()).union(_quiet4.toSet().difference(board.solution.toSet())).toList()..sort();
      expect(other, isNot(board.solution));
      expect(other.length, greaterThanOrEqualTo(board.solution.length));
      expect(rules.solved(puzzle, other), isTrue);
      expect(rules.solved(puzzle, board.solution.sublist(1)), isFalse);
      expect(rules.solved(puzzle, [...board.solution, 16]), isFalse);
      expect(rules.solved(puzzle, [...board.solution, -1]), isFalse);
      // 多点偶数下同一格不改局面，只有长度上限能拦住。
      expect(rules.solved(puzzle, [...board.solution, ...List.filled(lightsMaxPresses, 0)]), isFalse);
      expect(rules.solved(draw.puzzle, draw.solution), isTrue);
      // 三态：同一格多点三下不改局面，多点两下就不对；要点两下的格换成点五下也一样。
      final three = rules.generate(_seedOf(PuzzleTier.easy, (puzzle) => puzzle.states == 3), PuzzleTier.easy);
      expect(rules.solved(three.puzzle, [...three.solution, 5, 5, 5]), isTrue);
      expect(rules.solved(three.puzzle, [...three.solution, 5, 5]), isFalse);
      final twice = three.solution.firstWhere((cell) => three.solution.where((other) => other == cell).length == 2);
      expect(rules.solved(three.puzzle, [for (final cell in three.solution) if (cell != twice) cell, ...List.filled(5, twice)]), isTrue);
      expect(rules.solved(three.puzzle, [for (final cell in three.solution) if (cell != twice) cell, twice]), isFalse);
    });

    test('编解码往返（第 2 版写法），坏输入抛 FormatException', () {
      expect(rules.puzzleVersion, 2);
      for (final tier in PuzzleTier.values) {
        final draw = rules.generate(11, tier);
        final puzzle = rules.decodePuzzle(jsonDecode(jsonEncode(rules.encodePuzzle(draw.puzzle))));
        expect(_kindOf(puzzle), _kindOf(draw.puzzle));
        expect(puzzle.cells, draw.puzzle.cells);
        expect(rules.solved(puzzle, rules.decodeAnswer(jsonDecode(jsonEncode(rules.encodeAnswer(draw.solution))))), isTrue);
      }
      // 3×3 环面斜十字点左上角：它和绕过去的四个斜角（右下、下边中间、右边中间、正中）到了灭。
      final wrapped = _board(_lit(3, shape: LightsShape.diagonal, wrap: true, states: 3), [0]);
      expect(rules.encodePuzzle(wrapped), {'side': 3, 'shape': 1, 'wrap': true, 'states': 3, 'lights': '022200200'});
      expect(_kindOf(rules.decodePuzzle(rules.encodePuzzle(wrapped))), '3dT3');
      Map<String, Object?> json({Object? side = 3, Object? shape = 0, Object? wrap = false, Object? states = 2, Object? lights = '011111111'}) => {'side': side, 'shape': shape, 'wrap': wrap, 'states': states, 'lights': lights};
      for (final bad in <Object?>[
        null,
        '011111111',
        {'side': 3, 'lights': '011111111'},
        json(side: 2, lights: '0111'),
        json(side: 8, lights: '0${'1' * 63}'),
        json(side: '3'),
        json(shape: 2),
        json(shape: -1),
        json(wrap: 1),
        json(wrap: null),
        json(states: 1),
        json(states: 4, lights: '033333333'),
        json(lights: 11111111),
        json(lights: '01111111'),
        json(lights: '01111111x'),
        json(lights: '021111111'),
        json(lights: '111111111'),
        json(states: 3, lights: '222222222'),
        json(side: 5, lights: '0${'1' * 24}'),
      ]) {
        expect(() => rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(rules.decodePuzzle(json()).cells.first, 0);
      expect(rules.decodePuzzle(json(states: 3, lights: '012222222')).cells.take(2), [0, 1]);
      expect(() => rules.decodeAnswer('0'), throwsFormatException);
      expect(() => rules.decodeAnswer([49]), throwsFormatException);
      expect(() => rules.decodeAnswer([-1]), throwsFormatException);
      expect(() => rules.decodeAnswer([1.5]), throwsFormatException);
      expect(() => rules.decodeAnswer(List.filled(lightsMaxPresses + 1, 0)), throwsFormatException);
      expect(rules.decodeAnswer(List.filled(lightsMaxPresses, 0)), hasLength(lightsMaxPresses));
    });

    test('登记在格子谜题，能进挑战，报 lights@2；高档要最少下数，碎片是最少下数', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'lights');
      expect(game.group, gridGroup);
      expect(game.challengeable, isTrue);
      expect(challengeGameTokens(['lights']), {'lights@2'});
      final draw = rules.generate(5, PuzzleTier.expert);
      expect(challengeMinimum('lights', draw.puzzle), draw.solution.length);
      expect(challengeStepLimit('lights', draw.solution.length), draw.solution.length);
      expect(challengeFragment('lights', draw.puzzle, draw.solution), draw.solution.length);
    });
  });

  group('点灯对局页', () {
    testWidgets('点格翻转十字，几盏一起过渡；撤销退回；卡片边上也算最近那一格；点完先从中心亮一圈再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedOf(PuzzleTier.entry, (puzzle) => puzzle.side == 3);
      final store = await _open(tester, seed: seed);
      final draw = const LightsRules().generate(seed, PuzzleTier.entry);
      final least = draw.solution.length;
      final cells = [...draw.puzzle.cells];
      String state(int cell) => '第${cell ~/ 3 + 1}行第${cell % 3 + 1}列，${cells[cell] == 1 ? '亮' : '灭'}';
      void expectBoard() {
        for (var cell = 0; cell < 9; cell++) {
          expect(find.bySemanticsLabel(state(cell)), findsOneWidget, reason: state(cell));
        }
      }

      expect(_status(0, least), findsOneWidget);
      expect(find.bySemanticsLabel('十字：点一格变它和上下左右'), findsOneWidget);
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
      lightsPress(draw.puzzle, cells, 4);
      expectBoard();
      expect(_status(1, least), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      lightsPress(draw.puzzle, cells, 4);
      expectBoard();
      expect(_status(0, least), findsOneWidget);

      // 卡片左上角的边（在第一格外面）归第一格。
      await tester.tapAt(tester.getRect(_cell(0, 0)).topLeft - const Offset(3, 3));
      await _step(tester);
      lightsPress(draw.puzzle, cells, 0);
      expectBoard();
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      lightsPress(draw.puzzle, cells, 0);

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
      final next = const LightsRules().generate(seed, PuzzleTier.easy);
      expect(_cell(next.puzzle.side - 1, next.puzzle.side - 1), findsOneWidget);
      expect(_cell(next.puzzle.side, 0), findsNothing);
      expect(store.tierOf('lights'), PuzzleTier.easy);
      expect(_status(0, next.solution.length), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('三态：读屏读灭、暗、亮，暗灯在灭与亮之间；点一下往亮走一级、亮了回到灭，撤销退回一级；按参考解点完解开', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedOf(PuzzleTier.easy, (puzzle) => puzzle.states == 3 && puzzle.cells.contains(0) && puzzle.cells.contains(1));
      await _open(tester, seed: seed, tier: PuzzleTier.easy);
      final draw = const LightsRules().generate(seed, PuzzleTier.easy);
      final side = draw.puzzle.side, cells = [...draw.puzzle.cells];
      const names = ['灭', '暗', '亮'];
      void expectBoard() {
        for (var cell = 0; cell < side * side; cell++) {
          expect(find.bySemanticsLabel('第${cell ~/ side + 1}行第${cell % side + 1}列，${names[cells[cell]]}'), findsOneWidget, reason: '$cell');
        }
      }

      expectBoard();
      expect(find.text('灭 → 暗 → 亮'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('三态：灭、暗、亮轮换')), findsOneWidget);
      // 灭、暗、亮三盏的颜色：暗的离灭和亮都远（不是看着和其中一种一样）。
      Future<Color> lamp(int state) => _colorAt(tester, tester.getCenter(_cell(cells.indexOf(state) ~/ side, cells.indexOf(state) % side)));
      final off = await lamp(0), dim = await lamp(1);
      expect(_distance(dim, off), greaterThan(30));
      if (cells.contains(2)) expect(_distance(dim, await lamp(2)), greaterThan(30));

      // 一格点三下转一圈回到原样，撤销每次退回一下。
      final cell = draw.solution.first;
      for (var time = 0; time < 3; time++) {
        await _tapOn(tester, _cell(cell ~/ side, cell % side));
        await _step(tester);
        lightsPress(draw.puzzle, cells, cell);
        expectBoard();
      }
      expect(cells, draw.puzzle.cells);
      // 撤销每次退回一级（不是再往前走一级）：退一下是点了两下的样子，再退一下是点了一下的样子。
      for (var undone = 1; undone <= 3; undone++) {
        await tester.tap(find.widgetWithText(FilledButton, '撤销'));
        await _step(tester);
        for (var time = 0; time < 2; time++) {
          lightsPress(draw.puzzle, cells, cell);
        }
        expectBoard();
      }
      expect(cells, draw.puzzle.cells);
      for (final pressed in draw.solution) {
        await _tapOn(tester, _cell(pressed ~/ side, pressed % side));
        await _step(tester);
      }
      await tester.pumpAndSettle();
      expect(find.textContaining('${draw.solution.length} 步，正好最少'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('环面与斜十字：上方写规矩，四边有接口；按住角上那格时对边会被改到的格也浮出方块，松手才翻、翻到对边', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedOf(PuzzleTier.normal, (puzzle) => puzzle.wrap);
      await _open(tester, seed: seed, tier: PuzzleTier.normal);
      final draw = const LightsRules().generate(seed, PuzzleTier.normal);
      final side = draw.puzzle.side, cells = [...draw.puzzle.cells];
      expect(find.text('边连对边'), findsOneWidget);
      expect(find.bySemanticsLabel('十字：点一格变它和上下左右；边连对边'), findsOneWidget);

      // 卡片上边对着第一列的接口：环面才有，画在第一格上方的边里。
      final card = tester.getRect(_cell(0, 0));
      final port = Offset(card.center.dx, card.top - card.height * .12);
      final pixels = [await _colorAt(tester, port), await _colorAt(tester, port + Offset(card.width * .5, 0))];
      expect(_distance(pixels[0], pixels[1]), greaterThan(8), reason: '接口与旁边的卡片底色分得开');

      // 按住左上角：右上角与左下角（绕过去的）浮出淡方块，正中（不受影响）不变；还没翻。
      Offset corner(int row, int column) => tester.getRect(_cell(row, column)).topLeft + Offset(card.width * .08, card.height * .5);
      final quiet = await _colorAt(tester, corner(1, 1)), wrapped = await _colorAt(tester, corner(0, side - 1)), below = await _colorAt(tester, corner(side - 1, 0));
      final gesture = await tester.startGesture(tester.getCenter(_cell(0, 0)));
      await tester.pump(const Duration(milliseconds: 120));
      expect(_distance(await _colorAt(tester, corner(0, side - 1)), wrapped), greaterThan(6));
      expect(_distance(await _colorAt(tester, corner(side - 1, 0)), below), greaterThan(6));
      expect(_distance(await _colorAt(tester, corner(1, 1)), quiet), lessThan(1));
      expect(find.bySemanticsLabel(RegExp('^第1行第$side列，${cells[side - 1] == 1 ? '亮' : '灭'}')), findsOneWidget);
      await gesture.up();
      await _step(tester);
      lightsPress(draw.puzzle, cells, 0);
      expect(find.bySemanticsLabel(RegExp('^第1行第$side列，${cells[side - 1] == 1 ? '亮' : '灭'}')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^第$side行第1列，${cells[(side - 1) * side] == 1 ? '亮' : '灭'}')), findsOneWidget);

      // 斜十字：上方的形状图换成斜角，读屏读斜十字。
      final diagonal = _seedOf(PuzzleTier.easy, (puzzle) => puzzle.shape == LightsShape.diagonal);
      await tester.pumpWidget(const SizedBox());
      await _open(tester, seed: diagonal, tier: PuzzleTier.easy);
      expect(find.text('斜十字'), findsOneWidget);
      expect(find.bySemanticsLabel('斜十字：点一格变它和四个斜角'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('减少动画：点下去直接到位，解开不放收尾直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final seed = _seedOf(PuzzleTier.entry, (puzzle) => puzzle.side == 3);
      await _open(tester, seed: seed);
      final draw = const LightsRules().generate(seed, PuzzleTier.entry);
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
