import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_page.dart';
import 'package:superxd/playground/puzzle/cipher/cipher_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const _rules = CipherRules();

CipherRow _row(List<int> guess, int exact, int misplaced) => CipherRow(guess, exact, misplaced);

// 全部候选密码（暴力枚举，和求解器对照）。
List<List<int>> _codes(int length, int digits) {
  final codes = <List<int>>[];
  void walk(List<int> current) {
    if (current.length == length) {
      codes.add(current);
      return;
    }
    for (var digit = 0; digit < digits; digit++) {
      if (!current.contains(digit)) walk([...current, digit]);
    }
  }

  walk([]);
  return codes;
}

// 和每一行线索都对得上的密码有几个（暴力，按 cipherHint 逐行比）。
int _bruteCount(CipherPuzzle puzzle) => _codes(puzzle.length, puzzle.digits).where((code) => puzzle.rows.every((row) => cipherHint(code, row.guess) == row.hint)).length;

// 各档的位数、数字个数与行数区间（同 cipher_rules.dart 的 _plans）。
const _shapes = {
  PuzzleTier.entry: (3, 6, 2, 4),
  PuzzleTier.easy: (3, 10, 3, 6),
  PuzzleTier.normal: (4, 10, 4, 7),
  PuzzleTier.hard: (4, 10, 4, 7),
  PuzzleTier.expert: (5, 10, 5, 8),
};

// 3 位、0–5：单行一路推完的题（第二行说密码就是 2、3、0 这三个数字，第一行再定下 3 在第三位，其余跟着定）。
const _chain = CipherPuzzle(length: 3, digits: 6, rows: [CipherRow([4, 5, 3], 1, 0), CipherRow([2, 3, 0], 1, 2)]);
// 3 位、0–5：三行都是「一个对且位置对、一个对但位置不对」，哪一行单看都推不出东西，两行合起来才推得动。
const _joint = CipherPuzzle(length: 3, digits: 6, rows: [CipherRow([5, 3, 0], 1, 1), CipherRow([3, 0, 5], 1, 1), CipherRow([2, 1, 5], 1, 1)]);

Finder _key(int digit) => find.widgetWithText(FilledButton, '$digit');
Finder _slot(int slot, Object digit) => find.bySemanticsLabel('答案第 ${slot + 1} 位：$digit');
Finder _clue(int row, {bool conflict = false}) => find.bySemanticsLabel(RegExp('^第 ${row + 1} 行线索：.*${conflict ? '，和你的答案对不上' : '[^上]'}\$'));
Finder _tile(int digit, CipherMark mark) => find.bySemanticsLabel('数字 $digit，${mark.label}');
Finder _status(int filled, int length) => find.bySemanticsLabel(RegExp('已填 $filled/$length\$'));
Finder get _confirm => find.widgetWithText(FilledButton, '确认');
Finder get _undo => find.widgetWithText(FilledButton, '撤销');
Finder get _backspace => find.byWidgetPredicate((widget) => widget is IconButton && widget.tooltip == '退格');
// 答案格的方块本身（收尾时它在缩放变换里，量它才看得出鼓起）。
Finder _slotBox(int slot, int digit) => find.descendant(of: _slot(slot, digit), matching: find.byType(Container)).first;

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后只推进固定时长。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _step(tester);
}

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('cipher', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'cipher');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: CipherPage(game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：操作是选择触感，违规与判错是重震。
List<String> _haptics(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

// 提示条收起后（含退场）再点底部的按钮：提示条会接住点在它上面的点按。
Future<void> _dismissToast(WidgetTester tester) async {
  hideCampusToast();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

void main() {
  group('密码破译规则', () {
    test('提示：位置对的先数，数字对按两边出现次数的较小值合计再减去位置对的；有重复数字不多算，两边对调相同', () {
      expect(cipherHint([1, 2, 3], [1, 2, 3]), (exact: 3, misplaced: 0));
      expect(cipherHint([1, 2, 3], [3, 1, 2]), (exact: 0, misplaced: 3));
      expect(cipherHint([1, 2, 3], [1, 3, 4]), (exact: 1, misplaced: 1));
      expect(cipherHint([1, 2, 3], [4, 5, 6]), (exact: 0, misplaced: 0));
      expect(cipherHint([6, 8, 2], [2, 0, 6]), (exact: 0, misplaced: 2));
      // 重复数字：第二个 1 没有可配的，不算「数字对」；两个 1 对一个 1 也只算一次。
      expect(cipherHint([1, 2, 3], [1, 1, 4]), (exact: 1, misplaced: 0));
      expect(cipherHint([1, 2, 3], [4, 1, 1]), (exact: 0, misplaced: 1));
      expect(cipherHint([1, 1, 2], [1, 2, 1]), (exact: 1, misplaced: 2));
      expect(cipherHint([1, 1, 2], [2, 2, 1]), (exact: 0, misplaced: 2));
      final random = math.Random(3);
      for (var round = 0; round < 200; round++) {
        final code = [for (var position = 0; position < 4; position++) random.nextInt(6)];
        final guess = [for (var position = 0; position < 4; position++) random.nextInt(6)];
        expect(cipherHint(code, guess), cipherHint(guess, code), reason: '$code $guess');
      }
    });

    test('求解器：筛出和每行都对得上的候选，同暴力枚举一致，数到 limit 个就停（默认第 2 个）', () {
      const loose = CipherPuzzle(length: 3, digits: 10, rows: [CipherRow([1, 2, 3], 1, 0)]);
      final total = _bruteCount(loose);
      expect(total, greaterThan(100));
      expect(cipherSolve(loose).count, 2);
      expect(cipherSolve(loose, limit: 10).count, 10);
      expect(cipherSolve(loose, limit: 100000).count, total);
      // record 里的 List 按身份比，拆开比。
      expect(cipherSolve(_chain).count, 1);
      expect(cipherSolve(_chain).first, [2, 0, 3]);
      expect(cipherSolve(_joint).first, [1, 3, 5]);
      expect(_bruteCount(_joint), 1);
      // 矛盾的线索：一个都对不上。
      expect(cipherSolve(const CipherPuzzle(length: 3, digits: 6, rows: [CipherRow([0, 1, 2], 0, 0), CipherRow([3, 4, 5], 0, 0)])).count, 0);
    });

    test('推理过程：单行一路推完是深度 1；单行一条都推不出、要两行合起来的是深度 2', () {
      final chain = cipherReasoning(_chain);
      expect((chain.direct, chain.depth, chain.joined), (2, 1, 0));
      expect(chain.rounds, greaterThanOrEqualTo(1));
      final joint = cipherReasoning(_joint);
      expect((joint.direct, joint.rounds, joint.depth, joint.joined), (0, 0, 2, 2));
    });

    test('每档出 20 道：位数、数字范围与行数对，每行数字各不相同、提示由密码算出且不是全对；唯一且每行都少不了，推理过程合这一档的要求；同一个种子出同一道题', () {
      for (final tier in PuzzleTier.values) {
        final (length, digits, minRows, maxRows) = _shapes[tier]!;
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect((puzzle.length, puzzle.digits), (length, digits), reason: reason);
          expect(puzzle.rows.length, inInclusiveRange(minRows, maxRows), reason: reason);
          expect(cipherValidCode(puzzle, draw.solution), isTrue, reason: reason);
          for (final row in puzzle.rows) {
            expect(cipherValidCode(puzzle, row.guess), isTrue, reason: reason);
            expect(cipherHint(draw.solution, row.guess), row.hint, reason: reason);
            expect(row.exact, lessThan(length), reason: reason);
          }
          final solved = cipherSolve(puzzle);
          expect(solved.count, 1, reason: reason);
          expect(solved.first, draw.solution, reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          for (var index = 0; index < puzzle.rows.length; index++) {
            final fewer = CipherPuzzle(length: length, digits: digits, rows: [...puzzle.rows]..removeAt(index));
            expect(cipherSolve(fewer).count, 2, reason: '$reason 第 ${index + 1} 行是多余的');
          }
          final reasoning = cipherReasoning(puzzle);
          switch (tier) {
            case PuzzleTier.entry || PuzzleTier.easy || PuzzleTier.normal:
              // 只靠单行一路推完，不用联合。
              expect((reasoning.depth, reasoning.joined), (1, 0), reason: reason);
            case PuzzleTier.hard:
              expect(reasoning.depth, inInclusiveRange(2, 3), reason: reason);
              expect(reasoning.joined, inInclusiveRange(1, 6), reason: reason);
            case PuzzleTier.expert:
              expect(reasoning.depth, inInclusiveRange(2, 3), reason: reason);
              expect(reasoning.joined, inInclusiveRange(2, 9), reason: reason);
          }
        }
      }
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle)), jsonEncode(_rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle)));
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle)), isNot(jsonEncode(_rules.encodePuzzle(_rules.generate(12, PuzzleTier.hard).puzzle))));
    });

    test('出题耗时：每档 20 道，单题不超过 400ms，一共 100 道在 5 秒以内（专家档平均几十毫秒）', () {
      var slowest = 0;
      final total = Stopwatch()..start();
      for (final tier in PuzzleTier.values) {
        for (var seed = 100; seed < 120; seed++) {
          final watch = Stopwatch()..start();
          _rules.generate(seed, tier);
          slowest = math.max(slowest, watch.elapsedMilliseconds);
        }
      }
      expect(slowest, lessThan(400));
      expect(total.elapsedMilliseconds, lessThan(5000));
    });

    test('难度分：1–10，同档最多差 1 分，下一档最低高过上一档最高', () {
      int? lowerTop;
      for (final tier in PuzzleTier.values) {
        final scores = [for (var seed = 0; seed < 20; seed++) _rules.difficulty(_rules.generate(seed, tier).puzzle)];
        final lowest = scores.reduce(math.min), highest = scores.reduce(math.max);
        expect(lowest, greaterThanOrEqualTo(1));
        expect(highest, lessThanOrEqualTo(10));
        expect(highest - lowest, lessThanOrEqualTo(1), reason: '$tier $scores');
        if (lowerTop != null) expect(lowest, greaterThan(lowerTop), reason: '$tier 要高过下一档');
        lowerTop = highest;
      }
      expect(_rules.difficulty(_chain), 1);
      // 要联合的 3 位 0–5 题加 2 分。
      expect(_rules.difficulty(_joint), 3);
    });

    test('按规则判定：和每一行都对得上的合规密码都算（不和参考解比）；和某行对不上、位数不对、数字重复或超出范围都不算，并列出对不上的行', () {
      // 不唯一的题面（出题与解码都会拦下）：几个对得上的密码都算解开。
      const loose = CipherPuzzle(length: 3, digits: 6, rows: [CipherRow([3, 4, 5], 0, 0)]);
      expect(_rules.solved(loose, [0, 1, 2]), isTrue);
      expect(_rules.solved(loose, [2, 1, 0]), isTrue);
      // 对每一行的提示都一样，但不是合规的密码：数字重复、超出 0–5、位数不对。
      expect(cipherConflicts(loose, [1, 1, 2]), isEmpty);
      expect(_rules.solved(loose, [1, 1, 2]), isFalse);
      expect(_rules.solved(loose, [0, 1, 7]), isFalse);
      expect(_rules.solved(loose, [0, 1]), isFalse);
      expect(_rules.solved(loose, [0, 1, 2, 3]), isFalse);
      expect(_rules.solved(loose, [0, 1, 3]), isFalse);
      expect(cipherConflicts(loose, [0, 1, 3]), [0]);
      final draw = _rules.generate(5, PuzzleTier.hard);
      final rotated = [...draw.solution.skip(1), draw.solution.first];
      expect(_rules.solved(draw.puzzle, rotated), isFalse);
      final conflicts = cipherConflicts(draw.puzzle, rotated);
      expect(conflicts, isNotEmpty);
      for (final (index, row) in draw.puzzle.rows.indexed) {
        expect(conflicts.contains(index), cipherHint(rotated, row.guess) != row.hint);
      }
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(9, tier);
        final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        final puzzle = _rules.decodePuzzle(json);
        expect(jsonEncode(_rules.encodePuzzle(puzzle)), jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        final answer = jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution)));
        expect(answer, draw.solution);
        expect(_rules.solved(puzzle, _rules.decodeAnswer(answer)), isTrue);
      }
      Map<String, Object?> chain({Object? length = 3, Object? digits = 6, Object? rows}) => {
        'length': length,
        'digits': digits,
        'rows': rows ?? [[[4, 5, 3], 1, 0], [[2, 3, 0], 1, 2]],
      };
      expect(cipherSolve(_rules.decodePuzzle(chain())).first, [2, 0, 3]);
      for (final bad in <Object?>[
        null,
        'cipher',
        chain(length: 2),
        chain(length: 6),
        chain(length: '3'),
        chain(digits: 3),
        chain(digits: 11),
        chain(rows: <Object?>[]),
        chain(rows: List.filled(cipherMaxRows + 1, [[4, 5, 3], 1, 0])),
        chain(rows: [[[4, 5, 3], 1, 0], 'row']),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 0], 1]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3], 1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 0, 1], 1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 3], 1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 6], 1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, -1], 1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 0], -1, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 0], 2, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], [[2, 3, 0], 1.0, 2]]),
        chain(rows: [[[4, 5, 3], 1, 0], ['2', 1, 2]]),
        // 只有一行：对得上的密码不止一个，不是题。
        chain(rows: [[[4, 5, 3], 1, 0]]),
        // 两行都说一个都不对：没有一个密码对得上。
        chain(rows: [[[0, 1, 2], 0, 0], [[3, 4, 5], 0, 0]]),
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodeAnswer([2, 0, 3]), [2, 0, 3]);
      for (final bad in <Object?>[null, '203', [2, 0], [2, 0, 3, 1, 4, 5], [2, 0, 10], [2, 0, -1], [2, 0, '3'], [2, 0, 3.0]]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('提示说成口语；登记在逻辑推理、能进挑战，一句话玩法十个字以内', () {
      expect(cipherHintText(_row([1, 2, 3], 0, 0)), '没有一个数字对');
      expect(cipherHintText(_row([1, 2, 3], 1, 0)), '一个数字对，位置也对');
      expect(cipherHintText(_row([1, 2, 3], 2, 0)), '两个数字对，位置也都对');
      expect(cipherHintText(_row([1, 2, 3], 0, 1)), '一个数字对，但位置不对');
      expect(cipherHintText(_row([1, 2, 3], 0, 3)), '三个数字对，但位置都不对');
      expect(cipherHintPhrases(_row([1, 2, 3, 4], 1, 2)), ['一个数字对且位置对，', '另有两个数字对但位置不对']);
      final game = playgroundCatalog.firstWhere((game) => game.id == 'cipher');
      expect(game.name, '密码破译');
      expect(game.group, logicGroup);
      expect(game.challengeable, isTrue);
      expect(game.summary.length, lessThanOrEqualTo(10));
      expect(playgroundCatalog.last, same(game));
    });
  });

  group('密码破译对局页', () {
    testWidgets('键盘只有这一档的数字；填数、重复数字不收并提示、填满后键盘停用、退格与点答案格清掉', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      await _open(tester, seed: 3);
      final draw = _rules.generate(3, PuzzleTier.entry);
      expect(find.bySemanticsLabel('3 位 · 数字 0–5 · 不重复'), findsOneWidget);
      for (var digit = 0; digit < 6; digit++) {
        expect(_key(digit), findsOneWidget);
      }
      expect(_key(6), findsNothing);
      expect(_status(0, 3), findsOneWidget);
      expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
      expect(tester.widget<IconButton>(_backspace).onPressed, isNull);

      await _tap(tester, _key(4));
      expect(_slot(0, 4), findsOneWidget);
      expect(_slot(1, '空'), findsOneWidget);
      expect(_status(1, 3), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      // 4 已经填过：不收，重震并提示，不算一步。
      await _tap(tester, _key(4));
      expect(_slot(1, '空'), findsOneWidget);
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('密码里的数字各不相同'), findsOneWidget);
      // 接着做了一步正常操作，过时的提示收起。
      await _tap(tester, _key(1));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('密码里的数字各不相同'), findsNothing);
      await _tap(tester, _key(0));
      expect(_status(3, 3), findsOneWidget);
      expect(tester.widget<FilledButton>(_key(2)).onPressed, isNull);
      expect(tester.widget<FilledButton>(_confirm).onPressed, isNotNull);

      // 点答案格清那一格，再填数填进这一格；退格清最后填的一格。
      await _tap(tester, _slot(1, 1));
      expect(_slot(1, '空'), findsOneWidget);
      expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
      await _tap(tester, _key(5));
      expect(_slot(1, 5), findsOneWidget);
      await _tap(tester, find.byTooltip('退格'));
      expect(_slot(2, '空'), findsOneWidget);
      expect(_slot(1, 5), findsOneWidget);
      expect(draw.puzzle.length, 3);
      // 触区：线索里的数字、答案格与数字键都至少 48。
      expect(tester.getSize(_tile(draw.puzzle.rows.first.guess.first, CipherMark.none).first).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(_tile(draw.puzzle.rows.first.guess.first, CipherMark.none).first).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(_slot(0, 4)).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(_key(0)).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });

    testWidgets('点线索里的数字做记号：排除、确定、清掉，同一个数字在各行与键盘上一起变；撤销按步退回记号与填数', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 3);
      final puzzle = _rules.generate(3, PuzzleTier.entry).puzzle;
      // 挑一个在不止一行里出现的数字。
      final counts = <int, int>{};
      for (final row in puzzle.rows) {
        for (final digit in row.guess) {
          counts[digit] = (counts[digit] ?? 0) + 1;
        }
      }
      final digit = counts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      final appears = counts[digit]!;
      expect(_tile(digit, CipherMark.none), findsNWidgets(appears));
      expect(tester.widget<FilledButton>(_undo).onPressed, isNull);

      await _tap(tester, _tile(digit, CipherMark.none).first);
      expect(_tile(digit, CipherMark.absent), findsNWidgets(appears));
      expect(find.bySemanticsLabel('$digit，不在密码里'), findsOneWidget);
      await _tap(tester, _tile(digit, CipherMark.absent).last);
      expect(_tile(digit, CipherMark.present), findsNWidgets(appears));
      expect(find.bySemanticsLabel('$digit，在密码里'), findsOneWidget);
      await _tap(tester, _key(digit));
      expect(_slot(0, digit), findsOneWidget);

      // 撤销三步：先退填数，再退回排除，再退回没做记号。
      await _tap(tester, _undo);
      expect(_slot(0, '空'), findsOneWidget);
      expect(_tile(digit, CipherMark.present), findsNWidgets(appears));
      await _tap(tester, _undo);
      expect(_tile(digit, CipherMark.absent), findsNWidgets(appears));
      await _tap(tester, _undo);
      expect(_tile(digit, CipherMark.none), findsNWidgets(appears));
      expect(find.bySemanticsLabel('$digit'), findsOneWidget);
      expect(tester.widget<FilledButton>(_undo).onPressed, isNull);
      semantics.dispose();
    });

    testWidgets('填满点确认判错：只标出和答案对不上的线索行、重震并提示，答案改了标记就清掉；改对后答案格依次亮起再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = await _open(tester, seed: 4);
      final draw = _rules.generate(4, PuzzleTier.entry);
      final puzzle = draw.puzzle, solution = draw.solution;
      final wrong = [solution[1], solution[2], solution[0]];
      final conflicts = cipherConflicts(puzzle, wrong);
      expect(conflicts, isNotEmpty);
      for (final digit in wrong) {
        await _tap(tester, _key(digit));
      }
      haptics.clear();
      await _tap(tester, _confirm);
      for (var row = 0; row < puzzle.rows.length; row++) {
        expect(_clue(row, conflict: conflicts.contains(row)), findsOneWidget, reason: '第 ${row + 1} 行');
      }
      expect(haptics, ['HapticFeedbackType.heavyImpact']);
      expect(find.text('还不对，标红的线索对不上'), findsOneWidget);
      expect(find.text('新纪录'), findsNothing);
      // 答案格晃完回到原位。
      await tester.pump(const Duration(milliseconds: 300));

      // 退格三次：答案一改，对不上的标记就清掉；再填对的。
      for (var count = 0; count < 3; count++) {
        await _tap(tester, find.byTooltip('退格'));
      }
      expect(find.bySemanticsLabel(RegExp('对不上')), findsNothing);
      for (final digit in solution) {
        await _tap(tester, _key(digit));
      }
      await _dismissToast(tester);
      final slotBefore = tester.getRect(_slotBox(0, solution[0]));
      await tester.ensureVisible(_confirm);
      await tester.tap(_confirm);
      await tester.pump();
      // 收尾：第一格先鼓起，结果弹层在亮完之后才出现。
      var largest = slotBefore.width;
      for (var frame = 0; frame < 30 && find.text('新纪录').evaluate().isEmpty; frame++) {
        largest = math.max(largest, tester.getRect(_slotBox(0, solution[0])).width);
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(largest, greaterThan(slotBefore.width + 1));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('新纪录'), findsOneWidget);
      // 结果里的说明行按「 · 」分项排（项尾带不换行空格与点），按开头认。
      Finder sheet(Pattern text) => find.descendant(of: find.byType(CampusSheetPanel), matching: find.textContaining(text));
      expect(sheet(RegExp('^3 位')), findsOneWidget);
      expect(sheet(RegExp('^判错 1 次')), findsOneWidget);
      expect(store.best('cipher', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.tierOf('cipher'), PuzzleTier.easy);
      expect(_status(0, 3), findsOneWidget);
      expect(find.bySemanticsLabel('3 位 · 数字 0–9 · 不重复'), findsOneWidget);
      expect(_key(9), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('减少动画：判对直接弹结果；这一题从头来清掉记号与答案', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 2);
      final draw = _rules.generate(2, PuzzleTier.entry);
      final first = draw.puzzle.rows.first.guess.first;
      await _tap(tester, _tile(first, CipherMark.none).first);
      await _tap(tester, _key(draw.solution.first));
      await tester.tap(find.byTooltip('更多操作'));
      await _step(tester);
      await tester.tap(find.text('这一题从头来'));
      await _step(tester);
      expect(_status(0, 3), findsOneWidget);
      expect(_tile(first, CipherMark.absent), findsNothing);
      for (final digit in draw.solution) {
        await _tap(tester, _key(digit));
      }
      await tester.tap(_confirm);
      await tester.pump();
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('专家档在 360 宽、1.3 倍字号下放得下：线索区单独滚、带边缘渐隐，答案格与键盘停在底部，滚到底能点到最后一行', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, seed: 1, tier: PuzzleTier.expert);
      final puzzle = _rules.generate(1, PuzzleTier.expert).puzzle;
      expect(find.byType(CampusScrollFade), findsOneWidget);
      expect(_status(0, 5), findsOneWidget);
      const screen = Rect.fromLTWH(0, 0, 360, 700);
      // 五个答案格、退格与十个数字键都在屏幕里、不重叠。
      for (var slot = 0; slot < 5; slot++) {
        final rect = tester.getRect(_slot(slot, '空'));
        expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight), isTrue, reason: '第 ${slot + 1} 格 $rect');
        expect(rect.width, greaterThanOrEqualTo(48));
      }
      expect(screen.contains(tester.getRect(find.byTooltip('退格')).bottomRight), isTrue);
      for (var digit = 0; digit < 10; digit++) {
        final rect = tester.getRect(_key(digit));
        expect(screen.contains(rect.topLeft) && screen.contains(rect.bottomRight), isTrue, reason: '数字键 $digit $rect');
      }
      final last = puzzle.rows.length - 1;
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(viewport.bottom, lessThanOrEqualTo(tester.getRect(_slot(0, '空')).top));
      expect(tester.getRect(_clue(last)).bottom, greaterThan(viewport.bottom));
      // 一行五个数字不折行：同一行的数字在一条水平线上。
      final tiles = [for (final digit in puzzle.rows.first.guess) tester.getRect(_tile(digit, CipherMark.none).first)];
      expect(tiles.map((rect) => rect.top).toSet(), hasLength(1));
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(tester.getRect(_clue(last)).bottom, lessThanOrEqualTo(viewport.bottom + .5));
      final digit = puzzle.rows[last].guess.last;
      final tile = find.descendant(of: _clue(last), matching: find.bySemanticsLabel('数字 $digit，没做记号'));
      await tester.tap(tile);
      await _step(tester);
      expect(_tile(digit, CipherMark.absent), findsWidgets);
      await _tap(tester, _key(7));
      expect(_status(1, 5), findsOneWidget);
      semantics.dispose();
    });
  });
}
