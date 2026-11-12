import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/queens/queens_page.dart';
import 'package:superxd/playground/puzzle/queens/queens_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

PlaygroundGame get _game => playgroundCatalog.firstWhere((game) => game.id == 'queens');

Finder _cell(int row, int column) => find.bySemanticsLabel(RegExp('^第${row + 1}行第${column + 1}列，'));
Finder _cellIs(int row, int column, String state) => find.bySemanticsLabel('第${row + 1}行第${column + 1}列，$state');

// 读屏节点本身不接点按（点按落在下面的棋盘上），按它的位置点。
Future<void> _tapOn(WidgetTester tester, Finder finder) => tester.tapAt(tester.getCenter(finder));

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；走棋时只推进固定时长（先出一帧让动画起跑）。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

List<int> _lockedRows(QueensPuzzle puzzle) => [for (var row = 0; row < puzzle.size; row++) if (puzzle.given[row] >= 0) row];
List<int> _freeRows(QueensPuzzle puzzle) => [for (var row = 0; row < puzzle.size; row++) if (puzzle.given[row] < 0) row];

Future<void> _open(WidgetTester tester, PlaygroundStore store, int seed) async {
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: QueensPage(game: _game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
}

void main() {
  group('规则', () {
    const rules = QueensRules();
    const sizes = {PuzzleTier.entry: 5, PuzzleTier.easy: 6, PuzzleTier.normal: 8, PuzzleTier.hard: 10, PuzzleTier.expert: 12};

    test('求解器：空棋盘 4 皇后 2 个解、8 皇后 92 个解，锁定的皇后互相攻击无解', () {
      expect(queensSolve(const QueensPuzzle(size: 4, given: [-1, -1, -1, -1]), limit: 10).count, 2);
      expect(queensSolve(QueensPuzzle(size: 8, given: List.filled(8, -1)), limit: 100).count, 92);
      expect(queensSolve(const QueensPuzzle(size: 5, given: [0, 1, -1, -1, -1])).count, 0);
      final unique = queensSolve(const QueensPuzzle(size: 5, given: [0, -1, 4, -1, -1]));
      expect(unique.count, 1);
      expect(unique.first, [0, 2, 4, 1, 3]);
    });

    test('每档出 20 道：补法唯一、参考解判定通过、锁定的皇后都在参考解里，出题够快，同一个种子出同一道题', () {
      final watch = Stopwatch()..start();
      final draws = {for (final tier in PuzzleTier.values) tier: [for (var seed = 0; seed < 20; seed++) rules.generate(seed, tier)]};
      // 对局页同步出题：100 道（专家档每道要比 8 道候选）在 2 秒量级以内。
      expect(watch.elapsedMilliseconds, lessThan(2000));
      for (final MapEntry(key: tier, value: list) in draws.entries) {
        for (final (seed, draw) in list.indexed) {
          final puzzle = draw.puzzle;
          expect(puzzle.size, sizes[tier], reason: '$tier $seed');
          final result = queensSolve(puzzle);
          expect(result.count, 1, reason: '$tier $seed 补法要唯一');
          expect(result.first, draw.solution);
          expect(rules.solved(puzzle, draw.solution), isTrue);
          expect(rules.solved(puzzle, List.filled(puzzle.size, -1)), isFalse);
          expect(_lockedRows(puzzle), isNotEmpty);
          for (final row in _lockedRows(puzzle)) {
            expect(draw.solution[row], puzzle.given[row]);
          }
          // 留下的锁定皇后每一个都少不了：拿掉任何一个补法就不唯一。
          for (final row in _lockedRows(puzzle)) {
            final fewer = [...puzzle.given]..[row] = -1;
            expect(queensSolve(QueensPuzzle(size: puzzle.size, given: fewer)).count, 2, reason: '$tier $seed 第 $row 行的锁定皇后是多余的');
          }
        }
      }
      expect(rules.generate(11, PuzzleTier.hard).puzzle.given, rules.generate(11, PuzzleTier.hard).puzzle.given);
      expect(rules.generate(11, PuzzleTier.hard).puzzle.given, isNot(rules.generate(12, PuzzleTier.hard).puzzle.given));
    });

    test('难度分：1–10，同档最多差 1 分，下一档最低不低于上一档最高，平均分逐档上升', () {
      final scores = {for (final tier in PuzzleTier.values) tier: [for (var seed = 0; seed < 20; seed++) rules.difficulty(rules.generate(seed, tier).puzzle)]};
      double average(List<int> values) => values.reduce((sum, value) => sum + value) / values.length;
      for (final (index, tier) in PuzzleTier.values.indexed) {
        final list = scores[tier]!;
        for (final score in list) {
          expect(score, inInclusiveRange(1, 10));
        }
        expect(list.reduce((a, b) => a > b ? a : b) - list.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(1), reason: '$tier $list');
        if (index == 0) continue;
        final previous = scores[PuzzleTier.values[index - 1]]!;
        expect(list.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(previous.reduce((a, b) => a > b ? a : b)), reason: '$tier');
        expect(average(list), greaterThan(average(previous)), reason: '$tier');
      }
      expect(scores[PuzzleTier.entry]!.every((score) => score <= 2), isTrue);
      expect(scores[PuzzleTier.expert]!.every((score) => score >= 9), isTrue);
    });

    test('按规则判定：任何合规的补法都算，同列、同斜线、缺一个、挪动锁定的都不算', () {
      // 第一行锁在第 1 列的 5 皇后有两种补法：判定不和参考解逐项比，两种都算解开。
      const puzzle = QueensPuzzle(size: 5, given: [0, -1, -1, -1, -1]);
      expect(rules.solved(puzzle, [0, 2, 4, 1, 3]), isTrue);
      expect(rules.solved(puzzle, [0, 3, 1, 4, 2]), isTrue);
      expect(rules.solved(puzzle, [0, 2, 4, 1, 1]), isFalse);
      expect(rules.solved(puzzle, [0, 2, 4, 3, 1]), isFalse);
      expect(rules.solved(puzzle, [0, 2, 4, 1, -1]), isFalse);
      expect(rules.solved(puzzle, [0, 2, 4, 1]), isFalse);
      // 本身是一个合规的 5 皇后摆法，但第一行的锁定皇后被挪走了。
      expect(rules.solved(puzzle, [2, 0, 3, 1, 4]), isFalse);
      expect(rules.solved(puzzle, [0, 2, 4, 1, 5]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      final draw = rules.generate(9, PuzzleTier.expert);
      final puzzle = rules.decodePuzzle(rules.encodePuzzle(draw.puzzle));
      expect(puzzle.size, 12);
      expect(puzzle.given, draw.puzzle.given);
      expect(rules.solved(puzzle, rules.decodeAnswer(rules.encodeAnswer(draw.solution))), isTrue);
      expect(rules.decodeAnswer([-1, 3]), [-1, 3]);
      for (final bad in <Object?>[
        null,
        'size',
        {'size': 3, 'given': [-1, -1, -1]},
        {'size': queensMaxSize + 1, 'given': List.filled(queensMaxSize + 1, -1)},
        {'size': '5', 'given': [-1, -1, -1, -1, -1]},
        {'size': 5, 'given': [-1, -1, -1, -1]},
        {'size': 5, 'given': [-1, -1, -1, -1, 5]},
        {'size': 5, 'given': [-1, -1, -1, -1, -2]},
        {'size': 5, 'given': [-1, -1, 1.5, -1, -1]},
        {'size': 5, 'given': 'xxxxx'},
        // 锁定的皇后在同一条斜线上：永远解不开的坏题。
        {'size': 5, 'given': [0, 1, -1, -1, -1]},
      ]) {
        expect(() => rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>[null, '0,1', [0, '1'], [0, queensMaxSize], [-2], List.filled(queensMaxSize + 1, 0)]) {
        expect(() => rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('对局页', () {
    testWidgets('点空格放、再点拿掉；冲突的两个都标出来；锁定的点了不动；撤销按步退回；补齐弹出新纪录', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await _open(tester, store, 7);
      final draw = const QueensRules().generate(7, PuzzleTier.entry);
      final puzzle = draw.puzzle;
      final locked = _lockedRows(puzzle), free = _freeRows(puzzle);
      final lockedRow = locked.first, lockedColumn = puzzle.given[lockedRow];
      expect(find.textContaining('已放 ${locked.length}/5'), findsOneWidget);
      expect(_cellIs(lockedRow, lockedColumn, '锁定的皇后'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      // 锁定的点了不动，也不算一步。
      await _tapOn(tester, _cell(lockedRow, lockedColumn));
      await _step(tester);
      expect(_cellIs(lockedRow, lockedColumn, '锁定的皇后'), findsOneWidget);
      expect(find.textContaining('已放 ${locked.length}/5'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      // 放在锁定皇后的同一列：不拦着，两个都标冲突。
      await _tapOn(tester, _cell(free.first, lockedColumn));
      await _step(tester);
      expect(_cellIs(free.first, lockedColumn, '皇后，冲突'), findsOneWidget);
      expect(_cellIs(lockedRow, lockedColumn, '锁定的皇后，冲突'), findsOneWidget);
      expect(find.textContaining('已放 ${locked.length + 1}/5'), findsOneWidget);
      // 再点一次拿掉，冲突跟着消失。
      await _tapOn(tester, _cell(free.first, lockedColumn));
      await _step(tester);
      expect(_cellIs(free.first, lockedColumn, '空'), findsOneWidget);
      expect(_cellIs(lockedRow, lockedColumn, '锁定的皇后'), findsOneWidget);
      // 撤销两次：先退回「拿掉」，再退回「放上」。
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_cellIs(free.first, lockedColumn, '皇后，冲突'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(_cellIs(free.first, lockedColumn, '空'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      for (final row in free) {
        await _tapOn(tester, _cell(row, draw.solution[row]));
        await _step(tester);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('5×5'), findsOneWidget);
      expect(store.best('queens', PuzzleTier.entry), isNotNull);

      // 换到下一档：换一道 6×6 的题，棋盘清空。
      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      final next = const QueensRules().generate(7, PuzzleTier.easy).puzzle;
      expect(find.textContaining('已放 ${_lockedRows(next).length}/6'), findsOneWidget);
      expect(store.tierOf('queens'), PuzzleTier.easy);
      semantics.dispose();
    });

    testWidgets('按住皇后是在看攻击范围，松手不拿掉；这一题从头来清掉自己放的', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await _open(tester, store, 8);
      final draw = const QueensRules().generate(8, PuzzleTier.entry);
      final row = _freeRows(draw.puzzle).first, column = draw.solution[row];
      await _tapOn(tester, _cell(row, column));
      await _step(tester);
      expect(_cellIs(row, column, '皇后'), findsOneWidget);

      final gesture = await tester.createGesture();
      await gesture.down(tester.getCenter(_cell(row, column)));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.up(timeStamp: const Duration(milliseconds: 700));
      await _step(tester);
      expect(_cellIs(row, column, '皇后'), findsOneWidget);

      await tester.tap(find.byTooltip('更多操作'));
      await _step(tester);
      await tester.tap(find.text('这一题从头来'));
      await _step(tester);
      expect(_cellIs(row, column, '空'), findsOneWidget);
      expect(find.textContaining('已放 ${_lockedRows(draw.puzzle).length}/5'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('12×12 格子不到 48：双指张开放大到 48，放大后单指拖动平移、都不算落子', (tester) async {
      final semantics = tester.ensureSemantics();
      final store = PlaygroundStore.memory();
      await store.chooseTier('queens', PuzzleTier.expert);
      await _open(tester, store, 5);
      final lockedCount = _lockedRows(const QueensRules().generate(5, PuzzleTier.expert).puzzle).length;
      final before = tester.getRect(_cell(6, 6)).width;
      expect(before, lessThan(48));
      final center = tester.getCenter(_cell(6, 6));
      final first = await tester.startGesture(center - const Offset(20, 0));
      await tester.pump();
      final second = await tester.startGesture(center + const Offset(20, 0));
      await tester.pump();
      for (var step = 0; step < 6; step++) {
        await first.moveBy(const Offset(-12, 0));
        await second.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await first.up();
      await second.up();
      await _step(tester);
      final after = tester.getRect(_cell(6, 6));
      expect(after.width, greaterThan(before * 1.2));
      expect(after.width, lessThanOrEqualTo(48.01));
      expect(find.textContaining('已放 $lockedCount/12'), findsOneWidget);

      await tester.dragFrom(after.center, const Offset(40, 30));
      await _step(tester);
      final moved = tester.getRect(_cell(6, 6));
      expect(moved.left, greaterThan(after.left));
      expect(moved.top, greaterThan(after.top));
      expect(find.textContaining('已放 $lockedCount/12'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);
      semantics.dispose();
    });
  });
}
