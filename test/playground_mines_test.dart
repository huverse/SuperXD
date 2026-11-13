import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/mines/mines_page.dart';
import 'package:superxd/playground/puzzle/mines/mines_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';

const _rules = MinesRules();

PlaygroundGame get _game => playgroundCatalog.firstWhere((game) => game.id == 'mines');

// 5×5、起点在正中（S），* 是雷，数字与 0 是开局就翻开的格，. 是没翻开的。
MinesPuzzle _small(String mines) => _rules.decodePuzzle({'width': 5, 'height': 5, 'mines': mines, 'start': 12});
MinesPuzzle _raw(String mines) => MinesPuzzle(width: 5, height: 5, mines: [for (final char in mines.split('')) char == '1'], start: 12);

// 只靠单格：(1,2) 的 1 只剩一个未翻邻格，是雷；再看 (1,0) 的 1，左上角安全。
// . * . . .
// 1 1 1 0 0
// 0 0 S 0 0
final _singleOnly = '01000${'0' * 20}';
// 要子集：(1,0) 的 1 管 {左上、上二}，(1,1) 的 1 管 {左上、上二、上三}，同样一颗雷，上三安全；之后单格推完。
// . * . * .
// 1 1 2 1 1
// 0 0 S 0 0
final _needsSubset = '01010${'0' * 20}';
// 要全局：雷一共 3 颗，左右两颗单格推得出，最后一颗只能在 (3,1) 的 2 管的 {下一、下二、下三} 里，右下两格安全。
// 0 0 0 0 0
// 0 0 0 0 0
// 1 1 S 1 1
// * 2 1 2 *
// . . * . .
const _needsGlobal = '0000000000000001000100100';
// 要猜：两颗雷在 {左上、上四} 或 {上二、右上} 两种摆法都对得上，总雷数也分不开。
// * . . * .
// 1 1 1 1 1
final _needsGuess = '10010${'0' * 20}';

// 每档的边长、雷数、至少几轮子集或全局推理与难度分区间（同 mines_rules.dart 的注释）。
const _bands = {
  PuzzleTier.entry: (side: 6, mines: 5, deep: 0, score: (1, 2)),
  PuzzleTier.easy: (side: 8, mines: 10, deep: 0, score: (3, 4)),
  PuzzleTier.normal: (side: 9, mines: 15, deep: 1, score: (5, 6)),
  PuzzleTier.hard: (side: 12, mines: 28, deep: 2, score: (7, 8)),
  PuzzleTier.expert: (side: 14, mines: 40, deep: 3, score: (9, 10)),
};

String _place(MinesPuzzle puzzle, int cell) => '第${cell ~/ puzzle.width + 1}行第${cell % puzzle.width + 1}列';
Finder _cell(MinesPuzzle puzzle, int cell) => find.bySemanticsLabel(RegExp('^${_place(puzzle, cell)}，'));
Finder _cellIs(MinesPuzzle puzzle, int cell, String state) => find.bySemanticsLabel('${_place(puzzle, cell)}，$state');
Finder get _anyCell => find.bySemanticsLabel(RegExp(r'^第\d+行第\d+列，'));

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；每步先出一帧让动画起跑，再推过一片翻开的淡出（最长约 440ms）。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

FilledButton _undoButton(WidgetTester tester) => tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销'));

// 开局的局面：每格周围几颗雷、哪些格开局就翻开了。
({List<int> counts, List<bool> open}) _opening(MinesPuzzle puzzle) {
  final counts = minesCounts(puzzle);
  return (counts: counts, open: minesStartOpen(puzzle, counts));
}

// 找一个这一档的种子，让开局满足条件（固定种子出的题固定，测试可重复）。
int _seedWhere(PuzzleTier tier, bool Function(MinesPuzzle puzzle, List<int> counts, List<bool> open) test) {
  for (var seed = 0;; seed++) {
    final puzzle = _rules.generate(seed, tier).puzzle;
    final (:counts, :open) = _opening(puzzle);
    if (test(puzzle, counts, open)) return seed;
  }
}

// 开局时没翻开的 0 格（点了会连开一片）与没翻开的数字格。
int? _hiddenZero(MinesPuzzle puzzle, List<int> counts, List<bool> open) =>
    [for (var cell = 0; cell < open.length; cell++) if (!open[cell] && !puzzle.mines[cell] && counts[cell] == 0) cell].firstOrNull;
int? _hiddenNumber(MinesPuzzle puzzle, List<int> counts, List<bool> open) =>
    [for (var cell = 0; cell < open.length; cell++) if (!open[cell] && !puzzle.mines[cell] && counts[cell] > 0) cell].firstOrNull;

// 翻开 0 格之后的局面（不改原来的）。
List<bool> _flooded(MinesPuzzle puzzle, List<int> counts, List<bool> open, int zero) {
  final flooded = [...open];
  minesOpen(puzzle, counts, flooded, zero);
  return flooded;
}

// 开局翻开的数字里，周围未翻格既有雷又有安全格的那一个（插好旗再点它就能连开）。
int? _chordable(MinesPuzzle puzzle, List<int> counts, List<bool> open) {
  for (var cell = 0; cell < open.length; cell++) {
    if (!open[cell] || counts[cell] == 0) continue;
    final hidden = minesAround(puzzle.width, puzzle.height, cell).where((other) => !open[other]);
    if (hidden.any((other) => !puzzle.mines[other])) return cell;
  }
  return null;
}

// advance 为真时每换一道题种子加一（测「换一道题」真的换了）。
Future<void> _open(WidgetTester tester, PlaygroundStore store, int seed, {bool advance = false}) async {
  var next = seed;
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: MinesPage(game: _game, store: store, seeds: advance ? () => next++ : () => seed)));
  await tester.pumpAndSettle();
}

Future<void> _chooseMode(WidgetTester tester, String mode) async {
  await tester.tap(find.text(mode));
  await _step(tester);
}

// 记下触感：playTick 是选择触感（selectionClick），playRejected 是重震（heavyImpact）。
List<Object?> _haptics(WidgetTester tester) {
  final calls = <Object?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

// 按住一格到长按时长再多一点，手指还没抬（调用方先看插没插上旗，再自己抬手）。
Future<TestGesture> _press(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  return gesture;
}

Future<void> _longPress(WidgetTester tester, Finder finder) async {
  final gesture = await _press(tester, finder);
  await gesture.up();
  await _step(tester);
}

// 每一格读屏读出的状态都对得上这道题的开局。
void _expectOpening(MinesPuzzle puzzle) {
  final (:counts, :open) = _opening(puzzle);
  for (var cell = 0; cell < open.length; cell++) {
    expect(_cellIs(puzzle, cell, !open[cell] ? '未翻开' : counts[cell] == 0 ? '空白' : '数字 ${counts[cell]}'), findsOneWidget, reason: '$cell');
  }
}

// 读屏节点上挂的自定义操作。
List<int> _customActions(WidgetTester tester, Finder finder) => tester.getSemantics(finder).getSemanticsData().customSemanticsActionIds ?? const [];

void main() {
  group('规则', () {
    test('求解器：单格推得完的不用子集；要子集的只靠单格推不完；要全局的只靠子集推不完；两种摆法都对得上的推不完', () {
      final single = minesSolve(_small(_singleOnly));
      expect(single.solved, isTrue);
      expect((single.subsets, single.globals), (0, 0));
      expect(single.taps, [0]);

      final subset = _small(_needsSubset);
      expect(minesSolve(subset, maxRule: MinesRule.single).solved, isFalse);
      final bySubset = minesSolve(subset, maxRule: MinesRule.subset);
      expect(bySubset.solved, isTrue);
      expect(bySubset.subsets, greaterThanOrEqualTo(1));
      // 子集推出上三安全之后，(1,2) 的 2 只剩两格、都是雷，左上与右上安全：参考解三下翻完。
      expect(bySubset.taps.toSet(), {0, 2, 4});

      final global = _small(_needsGlobal);
      expect(minesSolve(global, maxRule: MinesRule.subset).solved, isFalse);
      final byGlobal = minesSolve(global);
      expect(byGlobal.solved, isTrue);
      expect(byGlobal.globals, greaterThanOrEqualTo(1));
      expect(_rules.solved(global, byGlobal.taps), isTrue);

      // 上三在两种摆法里都安全，子集推得出来；翻开以后仍分不开，卡住。
      final guess = minesSolve(_raw(_needsGuess));
      expect(guess.solved, isFalse);
      expect(guess.taps, [2]);
    });

    test('求解器推出来的都对：随机撒雷（推得完与推不完的都有），按推理顺序点的格都不是雷、重放每步都合法，推完的判定解开', () {
      var solved = 0, stuck = 0;
      for (var seed = 0; seed < 300; seed++) {
        final random = PuzzleRandom(seed);
        final width = 5 + random.nextInt(8), height = 5 + random.nextInt(8);
        final start = (1 + random.nextInt(height - 2)) * width + 1 + random.nextInt(width - 2);
        final keep = {start, ...minesAround(width, height, start)};
        final density = .12 + random.nextDouble() * .14;
        final puzzle = MinesPuzzle(width: width, height: height, mines: [for (var cell = 0; cell < width * height; cell++) !keep.contains(cell) && random.chance(density)], start: start);
        final result = minesSolve(puzzle);
        expect(result.taps.where((cell) => puzzle.mines[cell]), isEmpty, reason: '$seed');
        expect(minesReplay(puzzle, result.taps), isNotNull, reason: '$seed');
        expect(_rules.solved(puzzle, result.taps), result.solved, reason: '$seed');
        if (result.solved) {
          solved++;
        } else {
          stuck++;
        }
      }
      expect(solved, greaterThan(50));
      expect(stuck, greaterThan(20));
    });

    test('每档出 20 道：边长与雷数、起点不靠边且周围没有雷、求解器从起点推完且推理够深、参考解通过、少点一下不算、难度分在本档区间', () {
      for (final tier in PuzzleTier.values) {
        final band = _bands[tier]!;
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect((puzzle.width, puzzle.height), (band.side, band.side), reason: reason);
          expect(puzzle.mines.where((mine) => mine).length, band.mines, reason: reason);
          final (row, column) = (puzzle.start ~/ puzzle.width, puzzle.start % puzzle.width);
          expect(row > 0 && row < puzzle.height - 1 && column > 0 && column < puzzle.width - 1, isTrue, reason: reason);
          expect([puzzle.start, ...minesAround(puzzle.width, puzzle.height, puzzle.start)].where((cell) => puzzle.mines[cell]), isEmpty, reason: reason);
          final result = minesSolve(puzzle);
          expect(result.solved, isTrue, reason: reason);
          expect(minesDeep(result), greaterThanOrEqualTo(band.deep), reason: reason);
          expect(draw.solution, result.taps, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          expect(_rules.solved(puzzle, draw.solution.sublist(0, draw.solution.length - 1)), isFalse, reason: reason);
          expect(_rules.difficulty(puzzle), inInclusiveRange(band.score.$1, band.score.$2), reason: reason);
        }
      }
      // 高档必须用到子集推理：只靠单格的推不完。
      for (var seed = 0; seed < 20; seed++) {
        for (final tier in [PuzzleTier.normal, PuzzleTier.hard, PuzzleTier.expert]) {
          expect(minesSolve(_rules.generate(seed, tier).puzzle, maxRule: MinesRule.single).solved, isFalse, reason: '$tier $seed');
        }
      }
      String shape(MinesPuzzle puzzle) => '${_rules.encodePuzzle(puzzle)}';
      expect(shape(_rules.generate(7, PuzzleTier.hard).puzzle), shape(_rules.generate(7, PuzzleTier.hard).puzzle));
      expect(shape(_rules.generate(7, PuzzleTier.hard).puzzle), isNot(shape(_rules.generate(8, PuzzleTier.hard).puzzle)));
    });

    test('出题耗时：每档 30 道，单题最慢不到 100 毫秒，整批不到 2 秒', () {
      final watch = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 100; seed < 130; seed++) {
          final single = Stopwatch()..start();
          _rules.generate(seed, tier);
          expect(single.elapsedMilliseconds, lessThan(100), reason: '$tier $seed');
        }
      }
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('难度分：同档最多差 1 分，下一档最低不低于上一档最高，平均分逐档上升；推理量过门槛才加 1', () {
      final scores = {for (final tier in PuzzleTier.values) tier: [for (var seed = 0; seed < 30; seed++) _rules.difficulty(_rules.generate(seed, tier).puzzle)]};
      double average(List<int> values) => values.reduce((sum, value) => sum + value) / values.length;
      int lowest(List<int> values) => values.reduce((a, b) => a < b ? a : b);
      int highest(List<int> values) => values.reduce((a, b) => a > b ? a : b);
      for (final (index, tier) in PuzzleTier.values.indexed) {
        final list = scores[tier]!;
        expect(highest(list) - lowest(list), lessThanOrEqualTo(1), reason: '$tier $list');
        if (index == 0) continue;
        final previous = scores[PuzzleTier.values[index - 1]]!;
        expect(lowest(list), greaterThanOrEqualTo(highest(previous)), reason: '$tier');
        expect(average(list), greaterThan(average(previous)), reason: '$tier');
      }
      expect((minesDifficulty(5, 0), minesDifficulty(5, 1)), (1, 2));
      expect((minesDifficulty(15, 2), minesDifficulty(15, 3)), (5, 6));
      expect((minesDifficulty(40, 4), minesDifficulty(40, 5)), (9, 10));
      expect(minesDifficulty(99, 99), 10);
    });

    test('按规则重放：翻未翻格、点数字连开都算；翻到雷、漏翻、越界、重复翻已翻的、点 0 格、解开后多点都不算', () {
      final puzzle = _small(_singleOnly);
      expect(_rules.solved(puzzle, [0]), isTrue);
      // 点 (1,0) 的 1：按插对了旗重放，周围没翻的安全格（左上）一起翻开。
      expect(_rules.solved(puzzle, [5]), isTrue);
      expect(_rules.solved(puzzle, [1]), isFalse);
      expect(_rules.solved(puzzle, const []), isFalse);
      expect(_rules.solved(puzzle, [0, 0]), isFalse);
      expect(_rules.solved(puzzle, [12, 0]), isFalse);
      expect(_rules.solved(puzzle, [25]), isFalse);
      expect(_rules.solved(puzzle, [-1, 0]), isFalse);
      expect(_rules.solved(puzzle, [0, 7]), isFalse);
      // 要子集的那道：判定不和参考解逐项比，换个顺序、用两边的 1 连开也算；点中间的 2 时它周围只剩雷，翻不出东西不算。
      final subset = _small(_needsSubset);
      expect(_rules.solved(subset, [2, 0, 4]), isTrue);
      expect(_rules.solved(subset, [4, 2, 0]), isTrue);
      expect(_rules.solved(subset, [5, 9, 2]), isTrue);
      expect(_rules.solved(subset, [2, 7, 0, 4]), isFalse);
      expect(_rules.solved(subset, [2, 0]), isFalse);
    });

    test('翻开 0 格连开一片、按圈排；点数字连开从第 1 圈起；点不出新格的返回 null', () {
      // 7×5，第 4 列整列是雷：起点在左边，右边那片开局没翻开、总雷数都在左边找到了，靠全局推理知道右边全安全。
      final mines = [for (var cell = 0; cell < 35; cell++) cell % 7 == 3];
      final puzzle = MinesPuzzle(width: 7, height: 5, mines: mines, start: 15);
      final (:counts, :open) = _opening(puzzle);
      expect({for (var cell = 0; cell < 35; cell++) if (open[cell]) cell % 7}, {0, 1, 2});
      final result = minesSolve(puzzle);
      expect(result.solved, isTrue);
      expect(result.globals, greaterThanOrEqualTo(1));
      // 点右边中间的 0 格：整片 15 格一起翻开，自己是第 0 圈，越往外圈越大。
      final opened = minesStep(puzzle, counts, open, 19)!;
      expect(opened.length, 15);
      expect(opened.first, (19, 0));
      final rings = [for (final (_, ring) in opened) ring];
      expect(rings, orderedEquals([...rings]..sort()));
      expect(rings.toSet(), {0, 1, 2});
      expect(open.where((cell) => cell).length, 30);
      // 已翻开的数字周围只剩雷、0 格周围全翻开了、雷与越界：都翻不出新格。
      expect(minesStep(puzzle, counts, open, 2), isNull);
      expect(minesStep(puzzle, counts, open, 19), isNull);
      expect(minesStep(puzzle, counts, open, 3), isNull);
      expect(minesStep(puzzle, counts, open, 35), isNull);

      // 点数字连开：只有起点那一片翻开的小题里点 (1,0) 的 1，左上角作为第 1 圈翻开。
      final single = _small(_singleOnly);
      final start = _opening(single);
      expect(minesStep(single, start.counts, start.open, 5), [(0, 1)]);
    });

    test('编解码往返，坏输入抛 FormatException（含要猜的与开局就全翻开的题）', () {
      final draw = _rules.generate(9, PuzzleTier.expert);
      final puzzle = _rules.decodePuzzle(_rules.encodePuzzle(draw.puzzle));
      expect('${_rules.encodePuzzle(puzzle)}', '${_rules.encodePuzzle(draw.puzzle)}');
      expect(_rules.solved(puzzle, _rules.decodeAnswer(_rules.encodeAnswer(draw.solution))), isTrue);
      Map<String, Object?> small(Map<String, Object?> change) => {'width': 5, 'height': 5, 'mines': _singleOnly, 'start': 12, ...change};
      expect(_rules.decodePuzzle(small({})).start, 12);
      for (final broken in [
        small({'width': minesMinSide - 1}),
        small({'height': minesMaxSide + 1}),
        small({'width': '5'}),
        small({'mines': _singleOnly.substring(1)}),
        small({'mines': '2${_singleOnly.substring(1)}'}),
        small({'mines': 25}),
        small({'start': 25}),
        small({'start': -1}),
        small({'start': 1}),
        small({'start': '12'}),
        small({'mines': _needsGuess}),
        // 只有角上一颗雷：起点连开就把其余格全翻开了，没有可玩的。
        small({'mines': '1${'0' * 24}'}),
      ]) {
        expect(() => _rules.decodePuzzle(broken), throwsFormatException, reason: '$broken');
      }
      expect(() => _rules.decodePuzzle(null), throwsFormatException);
      expect(() => _rules.decodePuzzle('扫雷'), throwsFormatException);
      expect(_rules.decodeAnswer([0, 5]), [0, 5]);
      for (final bad in <Object?>[null, '0,1', [0, '1'], [-1], [minesMaxSide * minesMaxSide], List.filled(minesMaxSide * minesMaxSide + 1, 0)]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('对局页', () {
    testWidgets('翻开没翻的 0 格连开一片、翻数字只开一格；切到插旗插上与拔掉，剩余雷数跟着变；插着旗的格不让翻；撤销按步退回', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedWhere(PuzzleTier.entry, (puzzle, counts, open) {
        final zero = _hiddenZero(puzzle, counts, open);
        return zero != null && _hiddenNumber(puzzle, counts, _flooded(puzzle, counts, open, zero)) != null;
      });
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final (:counts, :open) = _opening(puzzle);
      await _open(tester, store, seed);
      // 读屏每格一个按钮，开局翻开的读数字或空白，其余读未翻开。
      expect(_anyCell, findsNWidgets(36));
      for (var cell = 0; cell < 36; cell++) {
        expect(_cellIs(puzzle, cell, !open[cell] ? '未翻开' : counts[cell] == 0 ? '空白' : '数字 ${counts[cell]}'), findsOneWidget, reason: '$cell');
      }
      expect(find.textContaining('剩 5 颗雷'), findsOneWidget);
      expect(_undoButton(tester).onPressed, isNull);

      // 没翻开的 0 格：一下连开一片。
      final zero = _hiddenZero(puzzle, counts, open)!;
      await _tapOn(tester, _cell(puzzle, zero));
      await _step(tester);
      final flooded = [...open];
      final region = minesOpen(puzzle, counts, flooded, zero);
      expect(region.length, greaterThan(1));
      expect(find.text('踩到雷了'), findsNothing);
      for (final (cell, _) in region) {
        expect(_cellIs(puzzle, cell, counts[cell] == 0 ? '空白' : '数字 ${counts[cell]}'), findsOneWidget, reason: '$cell');
      }
      // 没翻开的数字格：只开它自己。
      final number = _hiddenNumber(puzzle, counts, flooded)!;
      final before = find.bySemanticsLabel(RegExp('，未翻开\$')).evaluate().length;
      await _tapOn(tester, _cell(puzzle, number));
      await _step(tester);
      expect(_cellIs(puzzle, number, '数字 ${counts[number]}'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('，未翻开\$')).evaluate().length, before - 1);

      // 插旗：插上剩 4、拔掉回到 5。
      final mine = puzzle.mines.indexOf(true);
      await _chooseMode(tester, '插旗');
      await _tapOn(tester, _cell(puzzle, mine));
      await _step(tester);
      expect(_cellIs(puzzle, mine, '已插旗'), findsOneWidget);
      expect(find.textContaining('剩 4 颗雷'), findsOneWidget);
      await _tapOn(tester, _cell(puzzle, mine));
      await _step(tester);
      expect(_cellIs(puzzle, mine, '未翻开'), findsOneWidget);
      expect(find.textContaining('剩 5 颗雷'), findsOneWidget);
      // 插上旗再切回翻开：点它不翻（插着旗的格防手滑）。
      await _tapOn(tester, _cell(puzzle, mine));
      await _step(tester);
      await _chooseMode(tester, '翻开');
      await _tapOn(tester, _cell(puzzle, mine));
      await _step(tester);
      expect(_cellIs(puzzle, mine, '已插旗'), findsOneWidget);
      expect(find.text('踩到雷了'), findsNothing);

      // 撤销按步退回：插旗、拔旗、插旗三步，再退回翻数字与连开的两步。
      for (final expected in ['未翻开', '已插旗', '未翻开']) {
        await tester.tap(find.widgetWithText(FilledButton, '撤销'));
        await _step(tester);
        expect(_cellIs(puzzle, mine, expected), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_cellIs(puzzle, number, '未翻开'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_cellIs(puzzle, zero, '未翻开'), findsOneWidget);
      expect(_undoButton(tester).onPressed, isNull);
      semantics.dispose();
    });

    testWidgets('点已翻开的数字：插旗数不等于数字时不动，插对了旗再点，周围其余格一起翻开', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final seed = _seedWhere(PuzzleTier.entry, (puzzle, counts, open) => _chordable(puzzle, counts, open) != null);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final (:counts, :open) = _opening(puzzle);
      final number = _chordable(puzzle, counts, open)!;
      final hidden = [for (final other in minesAround(puzzle.width, puzzle.height, number)) if (!open[other]) other];
      final safe = hidden.where((cell) => !puzzle.mines[cell]).toList(), mines = hidden.where((cell) => puzzle.mines[cell]).toList();
      await _open(tester, store, seed);

      // 一面旗都没插：点数字不连开，也不算一步。
      await _tapOn(tester, _cell(puzzle, number));
      await _step(tester);
      for (final cell in safe) {
        expect(_cellIs(puzzle, cell, '未翻开'), findsOneWidget);
      }
      expect(_undoButton(tester).onPressed, isNull);

      await _chooseMode(tester, '插旗');
      for (final cell in mines) {
        await _tapOn(tester, _cell(puzzle, cell));
        await _step(tester);
      }
      // 插旗模式下点数字一样连开。
      await _tapOn(tester, _cell(puzzle, number));
      await _step(tester);
      for (final cell in safe) {
        expect(_cell(puzzle, cell), findsOneWidget);
        expect(_cellIs(puzzle, cell, '未翻开'), findsNothing, reason: '$cell');
        expect(_cellIs(puzzle, cell, '已插旗'), findsNothing, reason: '$cell');
      }
      for (final cell in mines) {
        expect(_cellIs(puzzle, cell, '已插旗'), findsOneWidget);
      }
      semantics.dispose();
    });

    // 用户 11-13 选定踩雷即结束（人工决策在 mines_page.dart 的 _lose 上方）。
    testWidgets('踩雷即结束：揭开所有雷、标出踩到的与插错的旗、重震，棋盘锁住、撤销不在、不记成绩；底部「这一题从头来」回到开局、照常计时', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = PlaygroundStore.memory();
      // 要一个没翻开的数字格（翻开只开它自己）和另外两个没翻开的安全格。
      List<int> pick(MinesPuzzle puzzle, List<int> counts, List<bool> open) {
        final number = _hiddenNumber(puzzle, counts, open);
        if (number == null) return const [];
        return [number, for (var cell = 0; cell < 36; cell++) if (!open[cell] && !puzzle.mines[cell] && cell != number) cell];
      }

      final seed = _seedWhere(PuzzleTier.entry, (puzzle, counts, open) => pick(puzzle, counts, open).length >= 3);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final (:counts, :open) = _opening(puzzle);
      final mines = [for (var cell = 0; cell < 36; cell++) if (puzzle.mines[cell]) cell];
      final hidden = pick(puzzle, counts, open);
      final wrong = hidden[1];
      await _open(tester, store, seed);
      // 先在一个不是雷的格上插旗（输了要标成插错），再正常翻开一个数字格（踩雷前有可撤销的步）。
      await _chooseMode(tester, '插旗');
      await _tapOn(tester, _cell(puzzle, wrong));
      await _step(tester);
      await _chooseMode(tester, '翻开');
      await _tapOn(tester, _cell(puzzle, hidden[0]));
      await _step(tester);
      expect(_undoButton(tester).onPressed, isNotNull);
      haptics.clear();

      await _tapOn(tester, _cell(puzzle, mines.first));
      await _step(tester);
      expect(haptics, contains('HapticFeedbackType.heavyImpact'));
      expect(_cellIs(puzzle, mines.first, '踩到的雷'), findsOneWidget);
      for (final cell in mines.skip(1)) {
        expect(_cellIs(puzzle, cell, '雷'), findsOneWidget, reason: '$cell');
      }
      expect(_cellIs(puzzle, wrong, '插错的旗'), findsOneWidget);
      // 状态行改写「踩到雷了」，读屏另有播报；不弹提示条、没有撤销，分段控件换成两个按钮。
      expect(find.text('踩到雷了'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('踩到雷了')), isSemantics(label: '踩到雷了', isLiveRegion: true));
      expect(find.widgetWithText(TextButton, '撤销'), findsNothing);
      expect(find.widgetWithText(FilledButton, '撤销'), findsNothing);
      expect(find.text('插旗'), findsNothing);
      expect(find.widgetWithText(FilledButton, '这一题从头来'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '换一道题'), findsOneWidget);
      // 棋盘锁住：点、长按都不动，读屏也不能点、没有插旗操作。
      await _tapOn(tester, _cell(puzzle, hidden[2]));
      await _step(tester);
      expect(_cellIs(puzzle, hidden[2], '未翻开'), findsOneWidget);
      await _longPress(tester, _cell(puzzle, hidden[2]));
      expect(_cellIs(puzzle, hidden[2], '未翻开'), findsOneWidget);
      expect(tester.getSemantics(_cell(puzzle, hidden[2])), isSemantics(hasTapAction: false));
      expect(_customActions(tester, _cell(puzzle, hidden[2])), isEmpty);
      expect(find.text('踩到雷了'), findsOneWidget);
      expect(store.best('mines', PuzzleTier.entry), isNull);
      // 停表经 PlaySession.end 通知对局页：走表停下，动画走完后不再空转出帧。
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse, reason: '踩雷后对局页停走表');

      // 这一题从头来：回到开局，旗也清掉，撤销按钮回来但不可用。
      await tester.tap(find.widgetWithText(FilledButton, '这一题从头来'));
      await _step(tester);
      expect(find.text('踩到雷了'), findsNothing);
      _expectOpening(puzzle);
      expect(find.textContaining('剩 5 颗雷'), findsOneWidget);
      expect(_undoButton(tester).onPressed, isNull);
      // 照常计时：走一步再换难度要确认（开始计时了才问）。
      await _tapOn(tester, _cell(puzzle, hidden[0]));
      await _step(tester);
      await tester.tap(find.widgetWithText(TextButton, '入门'));
      await _step(tester);
      await tester.tap(find.text('简单'));
      await _step(tester);
      expect(find.text('换成简单？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await _step(tester);

      // 再踩一次：这一局结束了，换难度不用确认，直接换题。
      await _tapOn(tester, _cell(puzzle, mines.first));
      await _step(tester);
      expect(find.text('踩到雷了'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '入门'));
      await _step(tester);
      await tester.tap(find.text('简单'));
      await _step(tester);
      expect(find.text('换成简单？'), findsNothing);
      expect(_anyCell, findsNWidgets(64));
      expect(find.textContaining('剩 10 颗雷'), findsOneWidget);
      expect(store.best('mines', PuzzleTier.entry), isNull);
      semantics.dispose();
    });

    testWidgets('踩雷后「换一道题」换成新的一道题；⋯ 里的同名项照旧能用', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final first = _rules.generate(10, PuzzleTier.entry).puzzle, second = _rules.generate(11, PuzzleTier.entry).puzzle;
      expect('${_rules.encodePuzzle(first)}', isNot('${_rules.encodePuzzle(second)}'));
      await _open(tester, store, 10, advance: true);
      await _tapOn(tester, _cell(first, first.mines.indexOf(true)));
      await _step(tester);
      expect(find.text('踩到雷了'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '换一道题'));
      await _step(tester);
      expect(find.text('踩到雷了'), findsNothing);
      _expectOpening(second);
      expect(find.widgetWithText(FilledButton, '换一道题'), findsNothing);
      expect(store.best('mines', PuzzleTier.entry), isNull);

      // 再踩一次，用 ⋯ 里的「这一题从头来」（菜单浮在最上层，同名的两个取菜单里那个）：回到这一道的开局。
      await _tapOn(tester, _cell(second, second.mines.indexOf(true)));
      await _step(tester);
      expect(find.text('踩到雷了'), findsOneWidget);
      await tester.tap(find.byTooltip('更多操作'));
      await _step(tester);
      await tester.tap(find.text('这一题从头来').last);
      await _step(tester);
      expect(find.text('踩到雷了'), findsNothing);
      _expectOpening(second);
      semantics.dispose();
    });

    // 用户 11-13 选定加长按插旗：任何模式下长按只管旗，免得插旗模式下长按误翻到雷。
    testWidgets('长按插旗：翻开与插旗模式下长按未翻的格都是插旗、长按旗子拔旗，长按到时就有触感、抬手不翻开；中途挪动不算', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = PlaygroundStore.memory();
      final seed = _seedWhere(PuzzleTier.entry, (puzzle, counts, open) => [for (var cell = 0; cell < 36; cell++) if (!open[cell] && !puzzle.mines[cell]) cell].length >= 2);
      final puzzle = _rules.generate(seed, PuzzleTier.entry).puzzle;
      final (:counts, :open) = _opening(puzzle);
      final mine = puzzle.mines.indexOf(true);
      final safe = [for (var cell = 0; cell < 36; cell++) if (!open[cell] && !puzzle.mines[cell]) cell];
      await _open(tester, store, seed);

      // 翻开模式长按雷：插上旗（不是翻开），到长按时长就插、手指还按着，触感跟着来；抬手不翻开。
      final gesture = await _press(tester, _cell(puzzle, mine));
      expect(_cellIs(puzzle, mine, '已插旗'), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await gesture.up();
      await _step(tester);
      expect(_cellIs(puzzle, mine, '已插旗'), findsOneWidget);
      expect(find.text('踩到雷了'), findsNothing);
      expect(find.textContaining('剩 4 颗雷'), findsOneWidget);
      await _longPress(tester, _cell(puzzle, mine));
      expect(_cellIs(puzzle, mine, '未翻开'), findsOneWidget);
      expect(find.textContaining('剩 5 颗雷'), findsOneWidget);

      // 插旗模式长按：同样是插旗（抬手不再按插旗模式点一下把它拔掉），再长按拔旗。
      await _chooseMode(tester, '插旗');
      await _longPress(tester, _cell(puzzle, safe[0]));
      expect(_cellIs(puzzle, safe[0], '已插旗'), findsOneWidget);
      await _longPress(tester, _cell(puzzle, safe[0]));
      expect(_cellIs(puzzle, safe[0], '未翻开'), findsOneWidget);
      await _chooseMode(tester, '翻开');

      // 按住以后挪出拖动阈值：不算长按，抬手也不算点，格子不动。
      final drift = await tester.startGesture(tester.getCenter(_cell(puzzle, safe[1])));
      await tester.pump(const Duration(milliseconds: 200));
      await drift.moveBy(const Offset(0, kTouchSlop + 6));
      await tester.pump(kLongPressTimeout);
      await drift.up();
      await _step(tester);
      expect(_cellIs(puzzle, safe[1], '未翻开'), findsOneWidget);
      // 短按照常翻开；长按翻开的格不插旗。
      await _tapOn(tester, _cell(puzzle, safe[1]));
      await _step(tester);
      expect(_cellIs(puzzle, safe[1], '未翻开'), findsNothing);
      await _longPress(tester, _cell(puzzle, safe[1]));
      expect(_cellIs(puzzle, safe[1], '已插旗'), findsNothing);
      // 长按插拔旗也是一步步记下的：撤销先退回刚才翻开的那一下。
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_cellIs(puzzle, safe[1], '未翻开'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('读屏：未翻的格带「插旗」自定义操作，插上后变成「拔旗」，不用切模式；翻开的格没有', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final puzzle = _rules.generate(3, PuzzleTier.entry).puzzle;
      final (:counts, :open) = _opening(puzzle);
      final mine = puzzle.mines.indexOf(true), shown = open.indexOf(true);
      await _open(tester, store, 3);
      const flag = CustomSemanticsAction(label: '插旗'), unflag = CustomSemanticsAction(label: '拔旗');
      Future<void> perform(CustomSemanticsAction action) async {
        final node = tester.getSemantics(_cell(puzzle, mine));
        node.owner!.performAction(node.id, SemanticsAction.customAction, CustomSemanticsAction.getIdentifier(action));
        await _step(tester);
      }

      expect(_customActions(tester, _cell(puzzle, mine)), [CustomSemanticsAction.getIdentifier(flag)]);
      expect(_customActions(tester, _cell(puzzle, shown)), isEmpty);
      // 翻开模式下用自定义操作插旗：不会翻开这颗雷。
      await perform(flag);
      expect(_cellIs(puzzle, mine, '已插旗'), findsOneWidget);
      expect(_customActions(tester, _cell(puzzle, mine)), [CustomSemanticsAction.getIdentifier(unflag)]);
      await perform(unflag);
      expect(_cellIs(puzzle, mine, '未翻开'), findsOneWidget);
      expect(find.text('踩到雷了'), findsNothing);
      semantics.dispose();
    });

    testWidgets('按参考解翻完：旗子全部插好、雷位亮一下再弹出新纪录，换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final draw = _rules.generate(3, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      await _open(tester, store, 3);
      for (final cell in draw.solution) {
        await _tapOn(tester, _cell(puzzle, cell));
        await _step(tester);
      }
      // 收尾还在放：旗子已经全部插上，结果还没弹。
      for (var cell = 0; cell < 36; cell++) {
        if (puzzle.mines[cell]) expect(_cellIs(puzzle, cell, '已插旗'), findsOneWidget, reason: '$cell');
      }
      expect(find.textContaining('剩 0 颗雷'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('新纪录'), findsOneWidget);
      // 说明行按「 · 」分项排（DotSeparatedText），每项各是一段文字。
      expect(find.textContaining(RegExp(r'^6×6 · ')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^5 颗雷')), findsOneWidget);
      expect(store.best('mines', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('mines'), PuzzleTier.easy);
      expect(_anyCell, findsNWidgets(64));
      expect(find.textContaining('剩 10 颗雷'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('14×14 格子不到 48：双指张开放大到 48（第一根手指先按住一会儿也不会长按插旗），放大后单指拖动平移，都不算一步', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await store.chooseTier('mines', PuzzleTier.expert);
      await _open(tester, store, 5);
      final puzzle = _rules.generate(5, PuzzleTier.expert).puzzle;
      final middle = 7 * 14 + 7;
      final before = tester.getRect(_cell(puzzle, middle)).width;
      expect(before, lessThan(48));
      final center = tester.getCenter(_cell(puzzle, middle));
      // 第一根手指按住 300ms 才落第二根，整个缩放加起来超过长按时长：第二根手指落下就不再算长按。
      final first = await tester.startGesture(center - const Offset(20, 0));
      await tester.pump(const Duration(milliseconds: 300));
      final second = await tester.startGesture(center + const Offset(20, 0));
      await tester.pump();
      for (var step = 0; step < 6; step++) {
        await first.moveBy(const Offset(-12, 0));
        await second.moveBy(const Offset(12, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.bySemanticsLabel(RegExp('，已插旗\$')), findsNothing);
      await first.up();
      await second.up();
      await _step(tester);
      final after = tester.getRect(_cell(puzzle, middle));
      expect(after.width, greaterThan(before * 1.2));
      expect(after.width, lessThanOrEqualTo(48.01));

      await tester.dragFrom(after.center, const Offset(40, 30));
      await _step(tester);
      final moved = tester.getRect(_cell(puzzle, middle));
      expect(moved.left, greaterThan(after.left));
      expect(moved.top, greaterThan(after.top));
      expect(_undoButton(tester).onPressed, isNull);
      expect(find.textContaining('剩 40 颗雷'), findsOneWidget);
      semantics.dispose();
    });

    // iOS 的页面任意位置右滑返回（campus_transitions.dart 的 _IosBackSwipe）约 18dp 就认横向拖动：棋盘上的拖动（缩放的第一根手指、
    // 放大后的平移）必须归棋盘，别处的右滑照常返回。
    testWidgets('iOS 上棋盘里横滑不触发右滑返回（放大前后都是），棋盘外右滑照常返回', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await store.chooseTier('mines', PuzzleTier.expert);
      final puzzle = _rules.generate(5, PuzzleTier.expert).puzzle;
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), navigatorKey: navigator, home: const SizedBox.expand(child: Text('上一页'))));
      unawaited(navigator.currentState!.push(CampusPageRoute<void>(builder: (_) => MinesPage(game: _game, store: store, seeds: () => 5))));
      await tester.pumpAndSettle();

      Future<void> dragRight(Offset from) async {
        final gesture = await tester.startGesture(from);
        for (var step = 0; step < 8; step++) {
          await gesture.moveBy(const Offset(12, 0));
          await tester.pump();
          expect(navigator.currentState!.userGestureInProgress, isFalse);
        }
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(MinesPage), findsOneWidget);
        expect(tester.getTopLeft(find.byType(MinesPage)).dx, 0);
      }

      // 棋盘的外框（没放大时左上角、右下角两格围成的范围）。
      final board = tester.getRect(_cell(puzzle, 0)).expandToInclude(tester.getRect(_cell(puzzle, 14 * 14 - 1)));
      await dragRight(tester.getCenter(_cell(puzzle, 7 * 14 + 2)));
      // 放大后再横滑：平移棋盘，不返回。
      final center = tester.getCenter(_cell(puzzle, 7 * 14 + 7));
      final first = await tester.startGesture(center - const Offset(20, 0));
      await tester.pump();
      final second = await tester.startGesture(center + const Offset(20, 0));
      await tester.pump();
      for (var step = 0; step < 6; step++) {
        await first.moveBy(const Offset(-12, 0));
        await second.moveBy(const Offset(12, 0));
        await tester.pump();
        expect(navigator.currentState!.userGestureInProgress, isFalse);
      }
      await first.up();
      await second.up();
      await _step(tester);
      final zoomed = tester.getRect(_cell(puzzle, 7 * 14 + 7));
      await dragRight(zoomed.center);
      expect(tester.getRect(_cell(puzzle, 7 * 14 + 7)).left, greaterThan(zoomed.left));
      expect(_undoButton(tester).onPressed, isNull);

      // 棋盘左边的空白处右滑：返回上一页。
      final width = tester.getSize(find.byType(MaterialApp)).width;
      final beside = Offset(board.left / 2, board.center.dy);
      expect(board.left, greaterThan(40));
      await tester.timedDragFrom(beside, Offset(width * .7, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byType(MinesPage), findsNothing);
      expect(find.text('上一页'), findsOneWidget);
      semantics.dispose();
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

    testWidgets('减少动画时直接到位：最后一下翻完马上插好旗、弹结果', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      final draw = _rules.generate(4, PuzzleTier.entry);
      await _open(tester, store, 4);
      for (final cell in draw.solution) {
        await _tapOn(tester, _cell(draw.puzzle, cell));
        await tester.pump();
      }
      // 正常动画下这时还在淡出与收尾（至少 160ms 加 920ms）。
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });
  });
}
