import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_page.dart';
import 'package:superxd/playground/puzzle/logicgrid/logicgrid_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const _rules = LogicGridRules();

LogicGridClue _clue(LogicGridClueKind kind, List<(int, int)> refs) => LogicGridClue(kind, [for (final (category, value) in refs) LogicGridRef(category, value)]);

// 3 个人，宠物（猫、狗、鱼）与座位（1 到 3 号位）。引用里 0 是人、1 是宠物、2 是座位。
LogicGridPuzzle _seated(List<LogicGridClue> clues) => LogicGridPuzzle(people: 3, categories: const [LogicGridCategory(1, [0, 1, 2]), LogicGridCategory(6, [0, 1, 2])], clues: clues);

// 3 个人，宠物（猫、狗、鱼）与衣服（红衣、黄衣、蓝衣）。引用里 0 是人、1 是宠物、2 是衣服。
LogicGridPuzzle _plain(List<LogicGridClue> clues) => LogicGridPuzzle(people: 3, categories: const [LogicGridCategory(1, [0, 1, 2]), LogicGridCategory(0, [0, 1, 2])], clues: clues);

// 每档的人数与属性类数（同 logicgrid_rules.dart 的 _plans）。
const _shape = {PuzzleTier.entry: (3, 2), PuzzleTier.easy: (3, 3), PuzzleTier.normal: (4, 3), PuzzleTier.hard: (4, 4), PuzzleTier.expert: (5, 4)};
const _basic = {LogicGridClueKind.same, LogicGridClueKind.differ};
const _seatedKinds = {LogicGridClueKind.leftOf, LogicGridClueKind.nextTo, LogicGridClueKind.before};

LogicGridPuzzle _without(LogicGridPuzzle puzzle, int index) =>
    LogicGridPuzzle(people: puzzle.people, categories: puzzle.categories, clues: [for (final (other, clue) in puzzle.clues.indexed) if (other != index) clue]);

// 外部输入一律先过 JSON（题库、存档都是 JSON），往返后再解码。
Object? _json(Object value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _mutable(LogicGridPuzzle puzzle) => (_json(_rules.encodePuzzle(puzzle))! as Map).cast<String, Object?>();

// ---------- 对局页的小工具 ----------

Finder _cell(LogicGridPuzzle puzzle, int category, int person) => find.bySemanticsLabel(RegExp('^${logicGridPeople[person]}的${puzzle.categories[category].pool.name}：'));
String _cellLabel(LogicGridPuzzle puzzle, int category, int person, {int? value, List<int> ruledOut = const []}) {
  final group = puzzle.categories[category];
  final name = '${logicGridPeople[person]}的${group.pool.name}';
  return value != null ? '$name：${group.label(value)}' : '$name：未填${ruledOut.isEmpty ? '' : '，不是${ruledOut.map(group.label).join('、')}'}';
}

Finder _clueCard(int index) => find.bySemanticsLabel(RegExp('^第 ${index + 1} 条：'));
String _clueLabel(LogicGridPuzzle puzzle, int index, {bool used = false, bool wrong = false}) =>
    '第 ${index + 1} 条：${logicGridSentence(puzzle, puzzle.clues[index])}${used ? '，用过了' : ''}${wrong ? '，和表里填的对不上' : ''}';
Finder _status(int filled, int total) => find.bySemanticsLabel(RegExp('已填 $filled/$total\$'));
Finder get _undo => find.widgetWithText(FilledButton, '撤销');

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后只推进固定时长（弹层进出也在这段里走完）。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _openCell(WidgetTester tester, LogicGridPuzzle puzzle, int category, int person) async {
  await tester.ensureVisible(_cell(puzzle, category, person));
  await tester.pump();
  await tester.tap(_cell(puzzle, category, person));
  await _step(tester);
}

// 点一格、在弹层的「是」里点这个值（弹层随即关掉）。
Future<void> _choose(WidgetTester tester, LogicGridPuzzle puzzle, int category, int person, int value) async {
  await _openCell(tester, puzzle, category, person);
  await tester.tap(find.bySemanticsLabel('是${puzzle.categories[category].label(value)}'));
  await _step(tester);
}

Future<void> _tapUndo(WidgetTester tester) async {
  await tester.ensureVisible(_undo);
  await tester.tap(_undo);
  await _step(tester);
}

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('logicgrid', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'logicgrid');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: LogicGridPage(game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：填值、标记是选择触感，判错是重震。
List<String> _haptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

void main() {
  group('逻辑网格推理规则', () {
    test('每种句式的真假：甲养猫坐 2 号位、乙养狗坐 1 号位、丙养鱼坐 3 号位', () {
      final puzzle = _seated(const []);
      const answer = [
        [0, 1, 2],
        [1, 0, 2],
      ];
      bool truth(LogicGridClueKind kind, List<(int, int)> refs) => logicGridTruth(puzzle, _clue(kind, refs), answer);
      // 是 / 不是。
      expect(truth(LogicGridClueKind.same, [(0, 0), (1, 0)]), isTrue);
      expect(truth(LogicGridClueKind.same, [(0, 0), (1, 1)]), isFalse);
      expect(truth(LogicGridClueKind.same, [(1, 0), (2, 1)]), isTrue);
      expect(truth(LogicGridClueKind.differ, [(0, 1), (1, 0)]), isTrue);
      expect(truth(LogicGridClueKind.differ, [(0, 1), (1, 1)]), isFalse);
      // 要么…要么…：恰好成立一样；两样都成立、都不成立都是假；B、C 同一类时就是「是其中之一」。
      expect(truth(LogicGridClueKind.either, [(1, 0), (0, 0), (2, 0)]), isTrue);
      expect(truth(LogicGridClueKind.either, [(1, 0), (0, 0), (2, 1)]), isFalse);
      expect(truth(LogicGridClueKind.either, [(1, 0), (0, 1), (2, 0)]), isFalse);
      expect(truth(LogicGridClueKind.either, [(1, 0), (0, 0), (0, 1)]), isTrue);
      expect(truth(LogicGridClueKind.either, [(1, 0), (0, 1), (0, 2)]), isFalse);
      // 左边一位、挨着、左边（不一定挨着）。
      expect(truth(LogicGridClueKind.leftOf, [(0, 1), (0, 0)]), isTrue);
      expect(truth(LogicGridClueKind.leftOf, [(0, 0), (0, 1)]), isFalse);
      expect(truth(LogicGridClueKind.leftOf, [(1, 1), (1, 2)]), isFalse);
      expect(truth(LogicGridClueKind.nextTo, [(0, 0), (0, 2)]), isTrue);
      expect(truth(LogicGridClueKind.nextTo, [(0, 1), (0, 2)]), isFalse);
      expect(truth(LogicGridClueKind.before, [(1, 1), (1, 2)]), isTrue);
      expect(truth(LogicGridClueKind.before, [(0, 2), (0, 1)]), isFalse);
      // 不成立的线索按下标列出。
      final judged = _seated([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)]), _clue(LogicGridClueKind.leftOf, [(0, 0), (0, 1)]), _clue(LogicGridClueKind.differ, [(0, 1), (1, 1)])]);
      expect(logicGridViolations(judged, answer), [1, 2]);
    });

    test('句子按结构生成：主语、谓语、宾语各有说法，座位说成几号位', () {
      final puzzle = _seated(const []);
      String say(LogicGridClueKind kind, List<(int, int)> refs) => logicGridSentence(puzzle, _clue(kind, refs));
      expect(say(LogicGridClueKind.same, [(0, 0), (1, 0)]), '甲养猫。');
      expect(say(LogicGridClueKind.differ, [(0, 1), (2, 2)]), '乙不坐3号位。');
      expect(say(LogicGridClueKind.either, [(1, 2), (0, 2), (2, 0)]), '养鱼的要么是丙，要么坐1号位。');
      expect(say(LogicGridClueKind.leftOf, [(0, 1), (1, 0)]), '乙坐在养猫的人左边一位。');
      expect(say(LogicGridClueKind.nextTo, [(1, 0), (0, 2)]), '养猫的挨着丙坐。');
      expect(say(LogicGridClueKind.before, [(0, 1), (0, 2)]), '乙坐在丙左边，不一定挨着。');
      expect(logicGridPhrases(puzzle, _clue(LogicGridClueKind.either, [(1, 2), (0, 2), (2, 0)])), ['养鱼的', '要么是丙，', '要么坐1号位。']);
    });

    test('线索的写法：类不同、规范先后、座位类线索要有座位且不引用座位', () {
      bool legal(LogicGridClueKind kind, List<(int, int)> refs, {int? seat = 1}) => logicGridClueLegal(_clue(kind, refs), 3, 2, seat);
      expect(legal(LogicGridClueKind.same, [(0, 0), (1, 0)]), isTrue);
      expect(legal(LogicGridClueKind.same, [(1, 0), (0, 0)]), isFalse);
      expect(legal(LogicGridClueKind.differ, [(1, 0), (1, 1)]), isFalse);
      expect(legal(LogicGridClueKind.same, [(0, 3), (1, 0)]), isFalse);
      expect(legal(LogicGridClueKind.same, [(0, 0), (3, 0)]), isFalse);
      expect(legal(LogicGridClueKind.either, [(1, 0), (0, 0), (2, 0)]), isTrue);
      expect(legal(LogicGridClueKind.either, [(1, 0), (2, 0), (0, 0)]), isFalse);
      expect(legal(LogicGridClueKind.either, [(1, 0), (1, 1), (2, 0)]), isFalse);
      expect(legal(LogicGridClueKind.either, [(1, 0), (0, 1), (0, 1)]), isFalse);
      expect(legal(LogicGridClueKind.leftOf, [(1, 0), (0, 0)]), isTrue);
      expect(legal(LogicGridClueKind.leftOf, [(1, 0), (0, 0)], seat: null), isFalse);
      expect(legal(LogicGridClueKind.leftOf, [(2, 0), (0, 0)]), isFalse);
      expect(legal(LogicGridClueKind.before, [(1, 0), (1, 0)]), isFalse);
      expect(legal(LogicGridClueKind.nextTo, [(0, 0), (1, 0)]), isTrue);
      expect(legal(LogicGridClueKind.nextTo, [(1, 0), (0, 0)]), isFalse);
      expect(legal(LogicGridClueKind.same, [(0, 0)]), isFalse);
    });

    test('约束传播：直接定下、每行每列唯一、传递、座位移位，矛盾返回 null', () {
      // 甲养猫：甲只剩猫，乙、丙划掉猫。
      expect(logicGridPropagate(_plain([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)])]))![0], [1, 6, 6]);
      // 甲养猫、养猫的穿红衣：传递出甲穿红衣。
      expect(logicGridPropagate(_plain([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)]), _clue(LogicGridClueKind.same, [(1, 0), (2, 0)])]))![1], [1, 6, 6]);
      // 养猫的穿红衣、甲不穿红衣：传递出甲不养猫（两条线索都没直接提甲和猫）。
      expect(logicGridPropagate(_plain([_clue(LogicGridClueKind.same, [(1, 0), (2, 0)]), _clue(LogicGridClueKind.differ, [(0, 0), (2, 0)])]))![0], [6, 7, 7]);
      // 甲坐在乙左边一位：甲不坐 3 号位、乙不坐 1 号位。
      expect(logicGridPropagate(_seated([_clue(LogicGridClueKind.leftOf, [(0, 0), (0, 1)])]))![1], [3, 6, 7]);
      // 甲坐在乙左边（不一定挨着）、乙坐在丙左边：座位全定。
      expect(logicGridPropagate(_seated([_clue(LogicGridClueKind.before, [(0, 0), (0, 1)]), _clue(LogicGridClueKind.before, [(0, 1), (0, 2)])]))![1], [1, 2, 4]);
      // 养鱼的要么是丙、要么穿红衣，丙不养鱼：养鱼的穿红衣。
      final either = logicGridPropagate(_plain([_clue(LogicGridClueKind.either, [(1, 2), (0, 2), (2, 0)]), _clue(LogicGridClueKind.differ, [(0, 2), (1, 2)])]))!;
      expect(either[0][2], 3);
      // 甲、乙都养猫：矛盾。
      expect(logicGridPropagate(_plain([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)]), _clue(LogicGridClueKind.same, [(0, 1), (1, 0)])])), isNull);
    });

    test('数解：数到上限就停，没有线索时 3 人 2 类共 36 组', () {
      final empty = _seated(const []);
      expect(logicGridCount(empty), 2);
      expect(logicGridCount(empty, limit: 7), 7);
      expect(logicGridCount(empty, limit: 1000), 36);
      // 只说甲养猫：剩下狗、鱼两种分法乘座位 6 种。
      expect(logicGridCount(_seated([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)])]), limit: 1000), 12);
      expect(logicGridCount(_plain([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)]), _clue(LogicGridClueKind.same, [(0, 1), (1, 0)])])), 0);
    });

    test('每档出 10 道：规模对、答案唯一、拿掉任何一条线索都不再唯一、参考解通过、不用猜；同一个种子出同一道题', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 10; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '${tier.name} seed $seed';
          expect((puzzle.people, puzzle.categories.length), _shape[tier], reason: reason);
          expect(logicGridCount(puzzle), 1, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          for (var index = 0; index < puzzle.clues.length; index++) {
            expect(logicGridCount(_without(puzzle, index)), 2, reason: '$reason 第 $index 条是多余的');
          }
          for (final clue in puzzle.clues) {
            expect(logicGridClueLegal(clue, puzzle.people, puzzle.categories.length, puzzle.seat), isTrue, reason: reason);
          }
          expect(logicGridReasoning(puzzle).guess, isFalse, reason: reason);
          expect(jsonEncode(_rules.encodePuzzle(_rules.generate(seed, tier).puzzle)), jsonEncode(_rules.encodePuzzle(puzzle)), reason: reason);
        }
      }
    });

    test('句式与试探随档：入门、简单只有是与不是、不用试探；普通加要么；困难、专家有座位与座位类线索，专家才有不一定挨着', () {
      final kinds = <PuzzleTier, Set<LogicGridClueKind>>{};
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 12; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          final reason = '${tier.name} seed $seed';
          final used = puzzle.clues.map((clue) => clue.kind).toList();
          (kinds[tier] ??= {}).addAll(used);
          final trials = logicGridReasoning(puzzle).trials;
          switch (tier) {
            case PuzzleTier.entry || PuzzleTier.easy:
              expect(_basic.containsAll(used), isTrue, reason: reason);
              expect(puzzle.seat, isNull, reason: reason);
              expect(trials, 0, reason: reason);
            case PuzzleTier.normal:
              expect({..._basic, LogicGridClueKind.either}.containsAll(used), isTrue, reason: reason);
              expect(used, contains(LogicGridClueKind.either), reason: reason);
              expect(puzzle.seat, isNull, reason: reason);
              expect(trials, lessThanOrEqualTo(1), reason: reason);
            case PuzzleTier.hard:
              expect(puzzle.seat, puzzle.categories.length - 1, reason: reason);
              expect(used, isNot(contains(LogicGridClueKind.before)), reason: reason);
              expect(used.where(_seatedKinds.contains), isNotEmpty, reason: reason);
              expect(trials, lessThanOrEqualTo(3), reason: reason);
            case PuzzleTier.expert:
              expect(puzzle.seat, puzzle.categories.length - 1, reason: reason);
              expect(used.where(_seatedKinds.contains).length, greaterThanOrEqualTo(2), reason: reason);
              expect(trials, lessThanOrEqualTo(4), reason: reason);
          }
          // 属性值都是属性池里的、不重复，座位只用前 N 个。
          for (final category in puzzle.categories) {
            expect(category.values.toSet(), hasLength(puzzle.people), reason: reason);
            if (category.pool.ordered) expect(category.values, [for (var value = 0; value < puzzle.people; value++) value], reason: reason);
          }
        }
      }
      expect(kinds[PuzzleTier.expert], containsAll(_seatedKinds));
      expect(kinds[PuzzleTier.hard], containsAll({LogicGridClueKind.leftOf, LogicGridClueKind.nextTo, LogicGridClueKind.either}));
    });

    test('出题耗时：每档 10 道，单题最慢在一两百毫秒量级', () {
      for (final tier in PuzzleTier.values) {
        var slowest = 0;
        final total = Stopwatch()..start();
        for (var seed = 100; seed < 110; seed++) {
          final watch = Stopwatch()..start();
          _rules.generate(seed, tier);
          if (watch.elapsedMilliseconds > slowest) slowest = watch.elapsedMilliseconds;
        }
        // 本机实测专家档平均四五十毫秒、百道里最慢一百五十毫秒左右，留出 CI 慢机的余量。
        expect(slowest, lessThan(tier == PuzzleTier.expert ? 600 : 300), reason: tier.name);
        expect(total.elapsedMilliseconds, lessThan(tier == PuzzleTier.expert ? 2000 : 1000), reason: tier.name);
      }
    });

    test('难度分：入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10，同档最多差 1、档间不倒挂；不唯一的题按 10 分', () {
      const ranges = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 6), PuzzleTier.hard: (7, 8), PuzzleTier.expert: (9, 10)};
      var previous = 0;
      final deep = <bool>{};
      for (final tier in PuzzleTier.values) {
        final puzzles = [for (var seed = 0; seed < 12; seed++) _rules.generate(seed, tier).puzzle];
        final scores = [for (final puzzle in puzzles) _rules.difficulty(puzzle)];
        // 口径：规模的基础分，要试探或传播轮数达到「人数 + 类数 − 2」再加 1。
        for (final (index, puzzle) in puzzles.indexed) {
          final reasoning = logicGridReasoning(puzzle);
          final bonus = reasoning.trials > 0 || reasoning.rounds >= puzzle.people + puzzle.categories.length - 2;
          deep.add(bonus);
          expect(scores[index], 2 * (puzzle.people - 3) + 2 * (puzzle.categories.length - 2) + 1 + (bonus ? 1 : 0), reason: '${tier.name} seed $index');
        }
        final (low, high) = ranges[tier]!;
        for (final score in scores) {
          expect(score, inInclusiveRange(low, high), reason: tier.name);
        }
        expect(scores.reduce((a, b) => a < b ? a : b), greaterThan(previous), reason: tier.name);
        previous = scores.reduce((a, b) => a > b ? a : b);
      }
      // 加分与不加分的题都出过。
      expect(deep, {true, false});
      expect(_rules.difficulty(_seated([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)])])), 10);
    });

    test('按规则判：参考解通过；换两个人、重复的值、越界、形状不对都不算', () {
      final draw = _rules.generate(3, PuzzleTier.normal);
      final puzzle = draw.puzzle, solution = draw.solution;
      expect(_rules.solved(puzzle, solution), isTrue);
      final swapped = [for (final row in solution) List.of(row)];
      final first = swapped[0][0];
      swapped[0][0] = swapped[0][1];
      swapped[0][1] = first;
      expect(_rules.solved(puzzle, swapped), isFalse);
      expect(logicGridViolations(puzzle, swapped), isNotEmpty);
      final repeated = [for (final row in solution) List.of(row)];
      repeated[1][0] = repeated[1][1];
      expect(_rules.solved(puzzle, repeated), isFalse);
      expect(_rules.solved(puzzle, [for (final row in solution) [for (final value in row) value == 0 ? 9 : value]]), isFalse);
      expect(_rules.solved(puzzle, solution.sublist(1)), isFalse);
      // 线索都成立、但不是一一对应（三个人都养猫）：不算。
      final cat = _plain([_clue(LogicGridClueKind.same, [(0, 0), (1, 0)])]);
      expect(logicGridViolations(cat, const [[0, 0, 0], [0, 1, 2]]), isEmpty);
      expect(_rules.solved(cat, const [[0, 0, 0], [0, 1, 2]]), isFalse);
      expect(_rules.solved(cat, const [[0, 1, 2], [0, 1, 2]]), isTrue);
      expect(_rules.solved(puzzle, [for (final row in solution) row.sublist(1)]), isFalse);
    });

    test('编解码：题面与答案往返不变；坏输入抛 FormatException，不唯一的题不收', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(7, tier);
        final decoded = _rules.decodePuzzle(_json(_rules.encodePuzzle(draw.puzzle)));
        expect(jsonEncode(_rules.encodePuzzle(decoded)), jsonEncode(_rules.encodePuzzle(draw.puzzle)), reason: tier.name);
        final answer = _rules.decodeAnswer(_json(_rules.encodeAnswer(draw.solution)));
        expect(_rules.solved(decoded, answer), isTrue, reason: tier.name);
        expect(jsonEncode(answer), jsonEncode(draw.solution), reason: tier.name);
      }

      final puzzle = _rules.generate(5, PuzzleTier.hard).puzzle;
      Map<String, Object?> base() => _mutable(puzzle);
      List<Object?> categories(Map<String, Object?> json) => json['categories']! as List<Object?>;
      List<Object?> clues(Map<String, Object?> json) => json['clues']! as List<Object?>;
      final bad = <Object?>[
        null,
        'x',
        <Object?>[],
        <String, Object?>{},
        base()..['people'] = 2,
        base()..['people'] = 6,
        base()..['people'] = '4',
        base()..['categories'] = 'x',
        base()..['categories'] = categories(base()).sublist(0, 1),
        base()..['categories'] = [...categories(base()), ...categories(base()).sublist(0, 1)],
        // 同一类出现两次。
        base()..['categories'] = [categories(base())[0], categories(base())[0], ...categories(base()).sublist(2)],
        // 属性池里没有的类、值、值的个数不对、值没按从小到大、座位不是从 1 号起。
        base()..['categories'] = [[logicGridKinds.length, [0, 1, 2, 3]], ...categories(base()).sublist(1)],
        base()..['categories'] = [[(categories(base())[0]! as List)[0], [0, 1, 2, 9]], ...categories(base()).sublist(1)],
        base()..['categories'] = [[(categories(base())[0]! as List)[0], [0, 1, 2]], ...categories(base()).sublist(1)],
        base()..['categories'] = [[(categories(base())[0]! as List)[0], [3, 2, 1, 0]], ...categories(base()).sublist(1)],
        base()..['categories'] = [...categories(base()).sublist(0, 3), [6, [1, 2, 3, 4]]],
        base()..['clues'] = <Object?>[],
        base()..['clues'] = 'x',
        base()..['clues'] = [for (var index = 0; index < logicGridMaxClues + 1; index++) clues(base())[0]],
        base()..['clues'] = [[9, 0, 0, 1, 0], ...clues(base()).sublist(1)],
        base()..['clues'] = [[0, 0, 0, 1], ...clues(base()).sublist(1)],
        base()..['clues'] = [[0, 1, 0, 0, 0], ...clues(base()).sublist(1)],
        base()..['clues'] = [[0, 0, 4, 1, 0], ...clues(base()).sublist(1)],
        base()..['clues'] = [[0, 0, 0, 5, 0], ...clues(base()).sublist(1)],
        base()..['clues'] = [[3, 4, 0, 0, 1], ...clues(base()).sublist(1)],
        base()..['clues'] = [['0', 0, 0, 1, 0], ...clues(base()).sublist(1)],
        // 拿掉一条线索：不再唯一。
        base()..['clues'] = clues(base()).sublist(1),
      ];
      for (final (index, json) in bad.indexed) {
        expect(() => _rules.decodePuzzle(json), throwsFormatException, reason: '第 $index 个坏题面');
      }
      // 没有座位的题不收座位类线索。
      final plain = _mutable(_rules.generate(5, PuzzleTier.normal).puzzle);
      expect(() => _rules.decodePuzzle(plain..['clues'] = [[3, 0, 0, 0, 1], ...clues(plain).sublist(1)]), throwsFormatException);

      for (final json in <Object?>[null, 'x', <Object?>[], [<Object?>[]], [[0, 1]], [[0, 1, 2], [0, 1]], [[0, 1, 5]], [['0', '1', '2']], [for (var row = 0; row < 5; row++) [0, 1, 2]], [[0, 1, 2, 3, 4, 0]]]) {
        expect(() => _rules.decodeAnswer(json), throwsFormatException, reason: '$json');
      }
    });
  });

  group('逻辑网格推理对局页', () {
    testWidgets('点格在「是」里填值，同一类的值从别人那里挪过来；「不是」标排除、弹层不关；撤销按步退回；线索标用过不算一步', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 4);
      final puzzle = _rules.generate(4, PuzzleTier.entry).puzzle;
      expect(_status(0, 6), findsOneWidget);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 0)), findsOneWidget);
      expect(tester.widget<FilledButton>(_undo).onPressed, isNull);
      // 格子触区至少 48。
      final size = tester.getSize(_cell(puzzle, 0, 0));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));

      // 甲填第 0 个值；乙也填这个值：甲那一格变空。撤销一步两格一起退回。
      await _choose(tester, puzzle, 0, 0, 0);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 0, value: 0)), findsOneWidget);
      expect(_status(1, 6), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await _choose(tester, puzzle, 0, 1, 0);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 0)), findsOneWidget);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 1, value: 0)), findsOneWidget);
      expect(_status(1, 6), findsOneWidget);
      await _tapUndo(tester);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 0, value: 0)), findsOneWidget);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 1)), findsOneWidget);

      // 再点已填的值是清空。
      await _openCell(tester, puzzle, 0, 0);
      expect(tester.getSemantics(find.bySemanticsLabel('是${puzzle.categories[0].label(0)}')), isSemantics(label: '是${puzzle.categories[0].label(0)}', isButton: true, isSelected: true, hasTapAction: true));
      await tester.tap(find.bySemanticsLabel('是${puzzle.categories[0].label(0)}'));
      await _step(tester);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 0)), findsOneWidget);
      expect(_status(0, 6), findsOneWidget);

      // 丙标掉两个值：弹层一直开着，标过的选中；关掉后格子读出「不是…」，只剩一个可能时格子里写出它。
      await _openCell(tester, puzzle, 0, 2);
      for (final value in [0, 1]) {
        await tester.tap(find.bySemanticsLabel('不是${puzzle.categories[0].label(value)}'));
        await _step(tester);
      }
      expect(find.text('不是'), findsOneWidget);
      expect(tester.getSemantics(find.bySemanticsLabel('不是${puzzle.categories[0].label(1)}')), isSemantics(label: '不是${puzzle.categories[0].label(1)}', isButton: true, isSelected: true, hasTapAction: true));
      await tester.tap(find.byTooltip('关闭'));
      await _step(tester);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 2, ruledOut: [0, 1])), findsOneWidget);
      expect(find.descendant(of: find.byType(Table), matching: find.text(puzzle.categories[0].label(2))), findsOneWidget);
      // 「是」里点一个标掉的值：填上并去掉这个排除。撤销退回到标掉两个。
      await _choose(tester, puzzle, 0, 2, 1);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 2, value: 1)), findsOneWidget);
      await _tapUndo(tester);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 2, ruledOut: [0, 1])), findsOneWidget);
      await _tapUndo(tester);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 2, ruledOut: [0])), findsOneWidget);

      // 线索：点一下标成用过了，再点取消；不算一步，撤销不碰它。
      final steps = haptics.length;
      await tester.ensureVisible(_clueCard(0));
      await tester.tap(_clueCard(0));
      await _step(tester);
      expect(find.bySemanticsLabel(_clueLabel(puzzle, 0, used: true)), findsOneWidget);
      expect(tester.getSemantics(_clueCard(0)), isSemantics(label: _clueLabel(puzzle, 0, used: true), isButton: true, hasTapAction: true));
      expect(haptics, hasLength(steps + 1));
      await _tapUndo(tester);
      expect(find.bySemanticsLabel(_clueLabel(puzzle, 0, used: true)), findsOneWidget);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 0, 2)), findsOneWidget);
      await tester.tap(_clueCard(0));
      await _step(tester);
      expect(find.bySemanticsLabel(_clueLabel(puzzle, 0)), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('填满判错：只标不成立的线索、重震并提示，接着改一步提示收起；改对后表格依次亮一下再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = await _open(tester, seed: 9);
      final draw = _rules.generate(9, PuzzleTier.entry);
      final puzzle = draw.puzzle, solution = draw.solution;
      // 甲、乙在第一类里对调，其余照参考解：题目唯一，所以一定有线索不成立。
      final wrong = [for (final row in solution) List.of(row)];
      wrong[0][0] = solution[0][1];
      wrong[0][1] = solution[0][0];
      final violations = logicGridViolations(puzzle, wrong);
      expect(violations, isNotEmpty);
      for (var category = 0; category < puzzle.categories.length; category++) {
        for (var person = 0; person < puzzle.people; person++) {
          await _choose(tester, puzzle, category, person, wrong[category][person]);
        }
      }
      expect(_status(6, 6), findsOneWidget);
      for (var index = 0; index < puzzle.clues.length; index++) {
        expect(find.bySemanticsLabel(_clueLabel(puzzle, index, wrong: violations.contains(index))), findsOneWidget, reason: '第 $index 条');
      }
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('有 ${violations.length} 条线索对不上'), findsOneWidget);
      expect(find.text('新纪录'), findsNothing);

      // 甲改成参考解的值：乙那一格空出来，不再判，警示与提示都收起。
      await _choose(tester, puzzle, 0, 0, solution[0][0]);
      expect(find.text('有 ${violations.length} 条线索对不上'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('对不上\$')), findsNothing);
      expect(_status(5, 6), findsOneWidget);

      // 乙填上：解开。表格先一行一行亮，亮完才弹结果。
      await _openCell(tester, puzzle, 0, 1);
      await tester.tap(find.bySemanticsLabel('是${puzzle.categories[0].label(solution[0][1])}'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('新纪录'), findsNothing);
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('3 人'), findsOneWidget);
      expect(find.textContaining('2 类'), findsOneWidget);
      expect(find.textContaining('判错 1 次'), findsOneWidget);
      expect(store.best('logicgrid', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('logicgrid'), PuzzleTier.easy);
      expect(_status(0, 9), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('专家档 5 人 4 类在 360 宽、1.3 倍字号下放得下：格子不小于 48，表格与线索各自滚动，能点到最后一个人与最后一条线索', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, seed: 2, tier: PuzzleTier.expert);
      final puzzle = _rules.generate(2, PuzzleTier.expert).puzzle;
      expect(_status(0, 20), findsOneWidget);
      expect(find.byType(CampusScrollFade), findsNWidgets(2));
      for (var category = 0; category < 4; category++) {
        final size = tester.getSize(_cell(puzzle, category, 0));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(tester.getRect(_cell(puzzle, category, 0)).right, lessThanOrEqualTo(360));
      }
      // 表格里的字都不小于 14（没有缩字）。
      for (final text in tester.widgetList<Text>(find.descendant(of: find.byType(Table), matching: find.byType(Text)))) {
        expect(text.style?.fontSize, greaterThanOrEqualTo(14));
      }
      // 最后一个人在最后一类里填一个值（表格放不下时自己滚过去）。
      await _choose(tester, puzzle, 3, 4, 0);
      expect(find.bySemanticsLabel(_cellLabel(puzzle, 3, 4, value: 0)), findsOneWidget);
      // 线索滚到底，最后一条能点。
      final last = puzzle.clues.length - 1;
      expect(_clueCard(last), findsNothing);
      await tester.scrollUntilVisible(_clueCard(last), 200, scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
      await tester.pump();
      await tester.tap(_clueCard(last));
      await _step(tester);
      expect(find.bySemanticsLabel(_clueLabel(puzzle, last, used: true)), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  });
}
