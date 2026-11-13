import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/schulte/schulte_page.dart';
import 'package:superxd/playground/puzzle/schulte/schulte_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

const _rules = SchulteRules();

// 每档的边长与题型（同 schulte_rules.dart 的 _tiers）。
const _shapes = {
  PuzzleTier.entry: (3, SchulteVariant.single),
  PuzzleTier.easy: (4, SchulteVariant.single),
  PuzzleTier.normal: (5, SchulteVariant.single),
  PuzzleTier.hard: (6, SchulteVariant.single),
  PuzzleTier.expert: (5, SchulteVariant.redBlack),
};

// 每档的难度分（口径在 SchulteRules.difficulty 的注释）。
const _scores = {PuzzleTier.entry: 2, PuzzleTier.easy: 3, PuzzleTier.normal: 5, PuzzleTier.hard: 6, PuzzleTier.expert: 8};

String _name(SchultePuzzle puzzle, int cell) => puzzle.variant == SchulteVariant.redBlack ? '${puzzle.red[cell] ? '红' : '黑'} ${puzzle.numbers[cell]}' : '${puzzle.numbers[cell]}';

// 读屏节点：每格读「数，已点 / 未点」。
Finder _cell(SchultePuzzle puzzle, int cell) => find.bySemanticsLabel(RegExp('^${_name(puzzle, cell)}，'));
Finder _status(String next, int misses) => find.bySemanticsLabel(RegExp('· $next · 点错 $misses 次\$'));

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后先出一帧让过渡开始，再推进固定时长。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

// 格里数字的不透明度：点过的格只留三成。
double _ink(WidgetTester tester, SchultePuzzle puzzle, int cell) => tester.widget<Text>(find.text('${puzzle.numbers[cell]}').first).style!.color!.a;

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('schulte', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'schulte');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: SchultePage(key: UniqueKey(), game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：点对是选择触感，点错是重震。
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
  group('舒尔特方格规则', () {
    test('每档出题：边长与题型对，格里正好是该点的数各一次，参考解通过；同一种子可复现、换种子换排法', () {
      for (final tier in PuzzleTier.values) {
        final (side, variant) = _shapes[tier]!;
        for (var seed = 0; seed < 30; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          expect((puzzle.side, puzzle.variant), (side, variant), reason: '$tier $seed');
          final count = side * side;
          if (variant == SchulteVariant.single) {
            expect([...puzzle.numbers]..sort(), [for (var number = 1; number <= count; number++) number]);
            expect(puzzle.red, everyElement(isFalse));
          } else {
            expect([for (var cell = 0; cell < count; cell++) if (!puzzle.red[cell]) puzzle.numbers[cell]]..sort(), [for (var number = 1; number <= 13; number++) number]);
            expect([for (var cell = 0; cell < count; cell++) if (puzzle.red[cell]) puzzle.numbers[cell]]..sort(), [for (var number = 1; number <= 12; number++) number]);
          }
          expect(draw.solution, hasLength(count));
          expect(_rules.solved(puzzle, draw.solution), isTrue);
        }
      }
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.numbers, _rules.generate(7, PuzzleTier.hard).puzzle.numbers);
      expect(_rules.generate(7, PuzzleTier.expert).puzzle.red, _rules.generate(7, PuzzleTier.expert).puzzle.red);
      expect(_rules.generate(7, PuzzleTier.hard).puzzle.numbers, isNot(_rules.generate(8, PuzzleTier.hard).puzzle.numbers));
    });

    test('红黑表：黑色先点，黑 1 到 13 从小到大、红 12 到 1 从大到小交替，最后是黑 13', () {
      final order = [for (var step = 0; step < 25; step++) schulteTarget(SchulteVariant.redBlack, 25, step)];
      expect(order.take(5).toList(), [(red: false, number: 1), (red: true, number: 12), (red: false, number: 2), (red: true, number: 11), (red: false, number: 3)]);
      expect(order.last, (red: false, number: 13));
      expect([for (final (step, mark) in order.indexed) if (step.isEven) mark], everyElement(predicate<SchulteMark>((mark) => !mark.red)));
      expect([for (final mark in order) if (!mark.red) mark.number], [for (var number = 1; number <= 13; number++) number]);
      expect([for (final mark in order) if (mark.red) mark.number], [for (var number = 12; number >= 1; number--) number]);
      expect([for (var step = 0; step < 9; step++) schulteTarget(SchulteVariant.single, 9, step).number], [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('按规则判定：顺序错、漏点、多点、点过的再点、越界与同数不同色都不算', () {
      final draw = _rules.generate(5, PuzzleTier.normal);
      final puzzle = draw.puzzle, solution = draw.solution;
      expect(_rules.solved(puzzle, solution), isTrue);
      expect(_rules.solved(puzzle, [solution[1], solution[0], ...solution.skip(2)]), isFalse);
      expect(_rules.solved(puzzle, solution.sublist(0, 24)), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(12), ...solution.skip(13)]), isFalse);
      expect(_rules.solved(puzzle, [...solution, solution.last]), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(24), solution[23]]), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(24), 25]), isFalse);
      expect(_rules.solved(puzzle, [...solution.take(24), -1]), isFalse);
      expect(_rules.solved(puzzle, solution.reversed.toList()), isFalse);
      expect(_rules.solved(puzzle, const []), isFalse);

      // 红黑表：第二下该点红 12，点黑 12 不算。
      final expert = _rules.generate(5, PuzzleTier.expert);
      final black12 = List.generate(25, (cell) => cell).firstWhere((cell) => !expert.puzzle.red[cell] && expert.puzzle.numbers[cell] == 12);
      expect(_rules.solved(expert.puzzle, expert.solution), isTrue);
      expect(_rules.solved(expert.puzzle, [expert.solution[0], black12, ...expert.solution.skip(2)]), isFalse);
      // 不交替、黑色全按升序点完再点红色也不算。
      final blackFirst = [for (var step = 0; step < 25; step += 2) expert.solution[step], for (var step = 1; step < 25; step += 2) expert.solution[step]];
      expect(_rules.solved(expert.puzzle, blackFirst), isFalse);
    });

    test('难度分只看格数与题型：同档相同、逐档上升，专家的红黑表高过 6×6', () {
      int? previous;
      for (final tier in PuzzleTier.values) {
        final scores = {for (var seed = 0; seed < 10; seed++) _rules.difficulty(_rules.generate(seed, tier).puzzle)};
        expect(scores, {_scores[tier]}, reason: '$tier');
        if (previous != null) expect(scores.single, greaterThan(previous), reason: '$tier 要高过下一档');
        previous = scores.single;
      }
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(11, tier);
        final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle))));
        expect((puzzle.side, puzzle.variant), (draw.puzzle.side, draw.puzzle.variant));
        expect(puzzle.numbers, draw.puzzle.numbers);
        expect(puzzle.red, draw.puzzle.red);
        expect(_rules.solved(puzzle, _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))))), isTrue);
      }
      final ordered = [for (var number = 1; number <= 9; number++) number];
      final expert = _rules.encodePuzzle(_rules.generate(3, PuzzleTier.expert).puzzle) as Map<String, Object?>;
      final redText = expert['red']! as String;
      for (final bad in <Object?>[
        null,
        ordered,
        {'side': 2, 'variant': 'single', 'numbers': [1, 2, 3, 4]},
        {'side': 7, 'variant': 'single', 'numbers': [for (var number = 1; number <= 49; number++) number]},
        {'side': '3', 'variant': 'single', 'numbers': ordered},
        {'side': 3, 'numbers': ordered},
        {'side': 3, 'variant': 'triple', 'numbers': ordered},
        {'side': 3, 'variant': 'single', 'numbers': '123456789'},
        {'side': 3, 'variant': 'single', 'numbers': ordered.take(8).toList()},
        {'side': 3, 'variant': 'single', 'numbers': [...ordered, 9]},
        {'side': 3, 'variant': 'single', 'numbers': [1, 1, 3, 4, 5, 6, 7, 8, 9]},
        {'side': 3, 'variant': 'single', 'numbers': [0, 2, 3, 4, 5, 6, 7, 8, 9]},
        {'side': 3, 'variant': 'single', 'numbers': [10, 2, 3, 4, 5, 6, 7, 8, 9]},
        {'side': 3, 'variant': 'single', 'numbers': [1.5, 2, 3, 4, 5, 6, 7, 8, 9]},
        {...expert, 'red': null},
        {...expert, 'red': redText.substring(1)},
        {...expert, 'red': '${redText.substring(1)}x'},
        // 红黑串全是黑色：黑色的数就重了。
        {...expert, 'red': '0' * 25},
        // 数是 1 到 25：红黑表里没有 14 以上的数。
        {...expert, 'numbers': [for (var number = 1; number <= 25; number++) number]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodePuzzle({'side': 3, 'variant': 'single', 'numbers': ordered}).red, everyElement(isFalse));
      expect(() => _rules.decodeAnswer('0'), throwsFormatException);
      expect(() => _rules.decodeAnswer([36]), throwsFormatException);
      expect(() => _rules.decodeAnswer([-1]), throwsFormatException);
      expect(() => _rules.decodeAnswer([1.5]), throwsFormatException);
      expect(() => _rules.decodeAnswer(List.filled(37, 0)), throwsFormatException);
      expect(_rules.decodeAnswer(List.filled(36, 0)), hasLength(36));
    });

    test('登记在记忆与反应，拼手速不进挑战', () {
      final game = playgroundCatalog.firstWhere((game) => game.id == 'schulte');
      expect(game.name, '舒尔特方格');
      expect(game.group, memoryGroup);
      expect(game.challengeable, isFalse);
      expect(identical(playgroundCatalog.last, game), isTrue);
    });
  });

  group('舒尔特方格对局页', () {
    testWidgets('按顺序点完：点对变淡、状态行写下一个，卡边归最近一格；点完先从中心亮一圈再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = await _open(tester, seed: 1);
      final draw = _rules.generate(1, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      // 正中那一格不是最后点的：收尾时看得出它从变淡亮回来。
      expect(puzzle.numbers[4], isNot(9));
      expect(draw.solution.indexOf(0), lessThan(8));
      expect(_status('下一个：1', 0), findsOneWidget);
      for (var cell = 0; cell < 9; cell++) {
        expect(find.bySemanticsLabel('${puzzle.numbers[cell]}，未点'), findsOneWidget);
      }

      for (final (step, cell) in draw.solution.indexed) {
        if (cell == 0) {
          // 卡片左上角的边（在第一格外面）归第一格。
          await tester.tapAt(tester.getRect(_cell(puzzle, 0)).topLeft - const Offset(3, 3));
        } else {
          await _tapOn(tester, _cell(puzzle, cell));
        }
        await _step(tester);
        expect(find.bySemanticsLabel('${puzzle.numbers[cell]}，已点'), findsOneWidget);
        expect(_ink(tester, puzzle, cell), closeTo(.3, .01));
        if (step < 8) expect(_status('下一个：${step + 2}', 0), findsOneWidget);
        if (step == 7) break;
      }
      expect(haptics, everyElement('HapticFeedbackType.selectionClick'));
      expect(haptics, hasLength(8));

      // 最后一下：正中那格先亮回原色再淡下去，亮完才弹结果。
      await _tapOn(tester, _cell(puzzle, draw.solution.last));
      await tester.pump();
      expect(_status('已点完', 0), findsOneWidget);
      expect(find.text('新纪录'), findsNothing);
      var brightest = 0.0;
      for (var frame = 0; frame < 60 && find.text('新纪录').evaluate().isEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.text('新纪录').evaluate().isEmpty) brightest = math.max(brightest, _ink(tester, puzzle, 4));
      }
      expect(brightest, greaterThan(.9));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('没有点错'), findsOneWidget);
      expect(_ink(tester, puzzle, 4), closeTo(.3, .01));
      expect(store.best('schulte', PuzzleTier.entry)!.moves, 9);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('schulte'), PuzzleTier.easy);
      final easy = _rules.generate(1, PuzzleTier.easy).puzzle;
      for (var cell = 0; cell < 16; cell++) {
        expect(find.bySemanticsLabel('${easy.numbers[cell]}，未点'), findsOneWidget);
      }
      expect(_status('下一个：1', 0), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('点错轻震、晃一下，记一次错不往下走；点过的格再点不算错；结果写点错次数', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 2);
      final draw = _rules.generate(2, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      final wrong = draw.solution[5];

      await _tapOn(tester, _cell(puzzle, wrong));
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      // 晃动中这一格离开了原位，晃完回来。
      await tester.pump(const Duration(milliseconds: 40));
      final text = find.text('${puzzle.numbers[wrong]}');
      expect((tester.getCenter(text).dx - tester.getCenter(_cell(puzzle, wrong)).dx).abs(), greaterThan(.5));
      await _step(tester);
      expect(tester.getCenter(text).dx, closeTo(tester.getCenter(_cell(puzzle, wrong)).dx, .01));
      expect(_status('下一个：1', 1), findsOneWidget);
      expect(find.bySemanticsLabel('${puzzle.numbers[wrong]}，未点'), findsOneWidget);
      expect(_ink(tester, puzzle, wrong), 1);

      await _tapOn(tester, _cell(puzzle, draw.solution[0]));
      await _step(tester);
      expect(_status('下一个：2', 1), findsOneWidget);
      // 再点一次已经点过的 1：不震、不计错。
      await _tapOn(tester, _cell(puzzle, draw.solution[0]));
      await _step(tester);
      expect(_status('下一个：2', 1), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.heavyImpact', 'HapticFeedbackType.selectionClick']);

      for (final cell in draw.solution.skip(1)) {
        await _tapOn(tester, _cell(puzzle, cell));
        await _step(tester);
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('点错 1 次'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('两根手指交替点都算；按下后滑出触摸容差这一下作废', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 3, tier: PuzzleTier.easy);
      final draw = _rules.generate(3, PuzzleTier.easy);
      final puzzle = draw.puzzle;
      final first = await tester.startGesture(tester.getCenter(_cell(puzzle, draw.solution[0])));
      final second = await tester.startGesture(tester.getCenter(_cell(puzzle, draw.solution[1])));
      await first.up();
      await tester.pump();
      await second.up();
      await _step(tester);
      expect(_status('下一个：3', 0), findsOneWidget);

      final slide = await tester.startGesture(tester.getCenter(_cell(puzzle, draw.solution[2])));
      await slide.moveBy(const Offset(40, 0));
      await slide.up();
      await _step(tester);
      expect(_status('下一个：3', 0), findsOneWidget);
      expect(find.bySemanticsLabel('3，未点'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('红黑表：状态行写颜色与数，同数不同色算点错，读屏读颜色；按交替顺序点完弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 4, tier: PuzzleTier.expert);
      final draw = _rules.generate(4, PuzzleTier.expert);
      final puzzle = draw.puzzle;
      int cellOf(bool red, int number) => List.generate(25, (cell) => cell).firstWhere((cell) => puzzle.red[cell] == red && puzzle.numbers[cell] == number);
      expect(find.bySemanticsLabel('黑 13，未点'), findsOneWidget);
      expect(find.bySemanticsLabel('红 12，未点'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^红 13，')), findsNothing);
      expect(_status('下一个：黑 1', 0), findsOneWidget);

      await _tapOn(tester, _cell(puzzle, cellOf(false, 1)));
      await _step(tester);
      expect(_status('下一个：红 12', 0), findsOneWidget);
      await _tapOn(tester, _cell(puzzle, cellOf(false, 12)));
      await _step(tester);
      expect(_status('下一个：红 12', 1), findsOneWidget);
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      await _tapOn(tester, _cell(puzzle, cellOf(true, 12)));
      await _step(tester);
      expect(_status('下一个：黑 2', 1), findsOneWidget);
      expect(find.bySemanticsLabel('红 12，已点'), findsOneWidget);

      for (final cell in draw.solution.skip(2)) {
        await _tapOn(tester, _cell(puzzle, cell));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('点错 1 次'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('减少动画：点对直接变淡、点错不晃，解开不放收尾直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 6);
      final draw = _rules.generate(6, PuzzleTier.entry);
      final puzzle = draw.puzzle;

      await _tapOn(tester, _cell(puzzle, draw.solution[3]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final wrong = find.text('${puzzle.numbers[draw.solution[3]]}');
      expect(tester.getCenter(wrong).dx, closeTo(tester.getCenter(_cell(puzzle, draw.solution[3])).dx, .01));

      await _tapOn(tester, _cell(puzzle, draw.solution[0]));
      await tester.pump();
      expect(_ink(tester, puzzle, draw.solution[0]), closeTo(.3, .01));

      for (final cell in draw.solution.skip(1)) {
        await _tapOn(tester, _cell(puzzle, cell));
        await tester.pump();
      }
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('360dp 宽、1.3 倍字号：6×6 与红黑表每格不小于 44，数字不小于 14 且放得进格子', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final tier in [PuzzleTier.hard, PuzzleTier.expert]) {
        await _open(tester, seed: 8, tier: tier);
        final puzzle = _rules.generate(8, tier).puzzle;
        for (var cell = 0; cell < puzzle.count; cell++) {
          final rect = tester.getRect(_cell(puzzle, cell));
          expect(rect.width, greaterThanOrEqualTo(44), reason: '$tier $cell');
          expect(rect.height, greaterThanOrEqualTo(44));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(360));
          expect(rect.bottom, lessThanOrEqualTo(700));
          final text = find.text('${puzzle.numbers[cell]}').at(puzzle.variant == SchulteVariant.redBlack ? puzzle.numbers.take(cell).where((number) => number == puzzle.numbers[cell]).length : 0);
          expect(tester.widget<Text>(text).style!.fontSize, greaterThanOrEqualTo(14));
          final size = tester.getSize(text);
          expect(size.width, lessThan(rect.width * .8), reason: '$tier ${puzzle.numbers[cell]}');
          expect(size.height, lessThan(rect.height * .8));
        }
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    });

    testWidgets('格里数字跟着字号缩放', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final puzzle = _rules.generate(9, PuzzleTier.entry).puzzle;
      double size() => tester.widget<Text>(find.text('${puzzle.numbers[0]}')).style!.fontSize!;
      await _open(tester, seed: 9);
      final standard = size();
      expect(standard, greaterThanOrEqualTo(14));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      await _open(tester, seed: 9);
      expect(size(), closeTo(standard * 1.3, .01));
      semantics.dispose();
    });
  });
}
