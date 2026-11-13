import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/knights/knights_page.dart';
import 'package:superxd/playground/puzzle/knights/knights_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

const _rules = KnightsRules();

KnightsClaim _claim(KnightsClaimKind kind, int first, [int second = -1]) => KnightsClaim(kind, first, second);

int _mask(List<bool> knights) => knights.indexed.fold(0, (mask, entry) => entry.$2 ? mask | 1 << entry.$1 : mask);

// 每档新加的句式（同 knights_rules.dart 的 _plans）。
const _counts = {KnightsClaimKind.exactly, KnightsClaimKind.atLeast, KnightsClaimKind.atMost};
const _logic = {KnightsClaimKind.implies, KnightsClaimKind.eitherKnave, KnightsClaimKind.wouldSay};
const _basic = {KnightsClaimKind.knight, KnightsClaimKind.knave, KnightsClaimKind.same, KnightsClaimKind.different};

Finder _card(int person) => find.bySemanticsLabel(RegExp('^${knightsNames[person]}说：'));
Finder _chip(int person, bool knight) => find.widgetWithText(CampusGlassChip, knight ? '骑士' : '无赖').at(person);
Finder _status(int settled, int people) => find.bySemanticsLabel(RegExp('已定 $settled/$people\$'));

String _label(KnightsPuzzle puzzle, int person, String mark, {bool mismatch = false}) =>
    '${knightsNames[person]}说：${knightsSentence(puzzle.claims[person], person, puzzle.people)} 标记：$mark${mismatch ? '，这句话和他的身份对不上' : ''}';

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；点按后只推进固定时长。
Future<void> _step(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapChip(WidgetTester tester, int person, bool knight) async {
  await tester.ensureVisible(_chip(person, knight));
  await tester.pump();
  await tester.tap(_chip(person, knight));
  await _step(tester);
}

Future<PlaygroundStore> _open(WidgetTester tester, {required int seed, PuzzleTier tier = PuzzleTier.entry}) async {
  final store = PlaygroundStore.memory();
  await store.chooseTier('knights', tier);
  final game = playgroundCatalog.firstWhere((game) => game.id == 'knights');
  await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: KnightsPage(game: game, store: store, seeds: () => seed)));
  await tester.pumpAndSettle();
  return store;
}

// 记下触感：落子、选择是选择触感，判错是重震。
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
  group('骑士与无赖规则', () {
    test('每句话的真假：同类与否、计数含说话人自己、条件与「至少一个无赖」等价、转述等于两人不同类', () {
      // 甲骑士、乙无赖、丙骑士。
      const knights = 0x5;
      expect(knightsTruth(_claim(KnightsClaimKind.knight, 2), 1, knights), isTrue);
      expect(knightsTruth(_claim(KnightsClaimKind.knave, 0), 1, knights), isFalse);
      expect(knightsTruth(_claim(KnightsClaimKind.same, 2), 0, knights), isTrue);
      expect(knightsTruth(_claim(KnightsClaimKind.different, 1), 0, knights), isTrue);
      expect(knightsTruth(_claim(KnightsClaimKind.exactly, 2), 1, knights), isTrue);
      expect(knightsTruth(_claim(KnightsClaimKind.atLeast, 3), 1, knights), isFalse);
      expect(knightsTruth(_claim(KnightsClaimKind.atMost, 2), 1, knights), isTrue);
      for (var mask = 0; mask < 8; mask++) {
        bool knight(int person) => mask >> person & 1 == 1;
        expect(knightsTruth(_claim(KnightsClaimKind.implies, 0, 2), 1, mask), !knight(0) || !knight(2));
        expect(knightsTruth(_claim(KnightsClaimKind.eitherKnave, 0, 2), 1, mask), !knight(0) || !knight(2));
        expect(knightsTruth(_claim(KnightsClaimKind.wouldSay, 0, 2), 1, mask), knight(0) != knight(2));
      }
    });

    test('合法的句子：不说自己是骑士或无赖、计数不收永远成立的、「X 和 Y」小的在前、转述的不是自己', () {
      expect(knightsClaimLegal(_claim(KnightsClaimKind.knight, 0), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.same, 1), 0, 3), isTrue);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.different, 3), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.exactly, 0), 0, 3), isTrue);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.exactly, 3), 0, 3), isTrue);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.atLeast, 0), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.atMost, 3), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.implies, 0, 2), 0, 3), isTrue);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.implies, 2, 2), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.eitherKnave, 2, 1), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.wouldSay, 0, 1), 0, 3), isFalse);
      expect(knightsClaimLegal(_claim(KnightsClaimKind.wouldSay, 1, 0), 0, 3), isTrue);
    });

    test('成立的身份组合与推理过程：单句一路推完是深度 1；单句一个都定不下、要两句合起来推的是深度 2', () {
      // 甲「我和乙是同一类人」→ 乙是骑士（单句就定）；乙是骑士说「甲是无赖」→ 甲是无赖。
      const chain = KnightsPuzzle([KnightsClaim(KnightsClaimKind.same, 1), KnightsClaim(KnightsClaimKind.knave, 0)]);
      expect(knightsSolutions(chain), [_mask([false, true])]);
      expect(knightsReasoning(chain), (direct: 1, single: 2, depth: 1, joined: 0));
      // 甲「乙是骑士」、乙「丙是骑士」、丙「我们三个人里恰好有一个骑士」：三人同类，全是骑士时丙的话为假，所以全是无赖。
      // 哪句单看都定不下谁；乙、丙两句合起来（丙是骑士 → 乙也是 → 至少两个骑士，矛盾）一次定下三个人。
      const joint = KnightsPuzzle([KnightsClaim(KnightsClaimKind.knight, 1), KnightsClaim(KnightsClaimKind.knight, 2), KnightsClaim(KnightsClaimKind.exactly, 1)]);
      expect(knightsSolutions(joint), [0]);
      expect(knightsReasoning(joint), (direct: 0, single: 0, depth: 2, joined: 3));
      // 甲「乙是骑士」、乙「甲是骑士」：两人同类就都成立，不唯一。
      expect(knightsSolutions(const KnightsPuzzle([KnightsClaim(KnightsClaimKind.knight, 1), KnightsClaim(KnightsClaimKind.knight, 0)])), hasLength(2));
    });

    test('每档出 20 道：人数对、恰好一组身份成立且就是参考解、句式与推理过程合这一档的要求；出题快，同一个种子出同一道题', () {
      final watch = Stopwatch()..start();
      final draws = {for (final tier in PuzzleTier.values) tier: [for (var seed = 0; seed < 20; seed++) _rules.generate(seed, tier)]};
      // 对局页同步出题：100 道（专家档每道平均重来几十次）在 2 秒量级以内。
      expect(watch.elapsedMilliseconds, lessThan(2000));
      for (final MapEntry(key: tier, value: list) in draws.entries) {
        final allowed = {..._basic, if (tier.index >= PuzzleTier.normal.index) ..._counts, if (tier.index >= PuzzleTier.hard.index) ..._logic};
        for (final (seed, draw) in list.indexed) {
          final puzzle = draw.puzzle;
          final reason = '$tier $seed';
          expect(puzzle.people, tier.index + 2, reason: reason);
          expect(knightsSolutions(puzzle), [_mask(draw.solution)], reason: reason);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: reason);
          for (final (speaker, claim) in puzzle.claims.indexed) {
            expect(knightsClaimLegal(claim, speaker, puzzle.people), isTrue, reason: reason);
            expect(allowed, contains(claim.kind), reason: reason);
          }
          final kinds = puzzle.claims.map((claim) => claim.kind).toList();
          final reasoning = knightsReasoning(puzzle);
          switch (tier) {
            case PuzzleTier.entry || PuzzleTier.easy:
              // 只用「是骑士 / 无赖」「同类 / 不同类」：单句一路推完，开头只有一个人能直接定。
              expect(reasoning, (direct: 1, single: puzzle.people, depth: 1, joined: 0), reason: reason);
            case PuzzleTier.normal:
              expect(kinds.where(_counts.contains), isNotEmpty, reason: reason);
              expect(reasoning.direct, lessThanOrEqualTo(1), reason: reason);
              expect(reasoning.depth, lessThanOrEqualTo(2), reason: reason);
              expect(reasoning.joined, lessThanOrEqualTo(2), reason: reason);
            case PuzzleTier.hard:
              // 至少有一个人的身份必须联合两句才推得出来。
              expect(kinds.where(_logic.contains), isNotEmpty, reason: reason);
              expect(reasoning.direct, lessThanOrEqualTo(1), reason: reason);
              expect(reasoning.depth, 2, reason: reason);
              expect(reasoning.single, lessThan(puzzle.people), reason: reason);
            case PuzzleTier.expert:
              expect(kinds.where(_logic.contains).length, greaterThanOrEqualTo(2), reason: reason);
              expect(reasoning.direct, 0, reason: reason);
              expect(reasoning.depth, inInclusiveRange(2, 3), reason: reason);
              expect(reasoning.joined, inInclusiveRange(2, 6), reason: reason);
          }
        }
      }
      expect(_rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle), _rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle));
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(11, PuzzleTier.hard).puzzle)), isNot(jsonEncode(_rules.encodePuzzle(_rules.generate(12, PuzzleTier.hard).puzzle))));
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
      expect(_rules.difficulty(_rules.generate(0, PuzzleTier.entry).puzzle), 1);
      expect(_rules.difficulty(_rules.generate(0, PuzzleTier.expert).puzzle), greaterThanOrEqualTo(9));
    });

    test('按规则判定：任何一组让每句话都和身份对得上的都算（不和参考解比）；改错一个人、人数不对都不算，并标出对不上的人', () {
      // 不唯一的题面（出题与解码都会拦下）：两组都成立，两组都算解开。
      const twin = KnightsPuzzle([KnightsClaim(KnightsClaimKind.knight, 1), KnightsClaim(KnightsClaimKind.knight, 0)]);
      expect(_rules.solved(twin, [true, true]), isTrue);
      expect(_rules.solved(twin, [false, false]), isTrue);
      expect(_rules.solved(twin, [true, false]), isFalse);
      final draw = _rules.generate(5, PuzzleTier.hard);
      for (var person = 0; person < draw.solution.length; person++) {
        final wrong = [...draw.solution]..[person] = !draw.solution[person];
        expect(_rules.solved(draw.puzzle, wrong), isFalse);
        final mismatches = knightsMismatches(draw.puzzle, _mask(wrong));
        expect(mismatches, isNotEmpty);
        for (final (speaker, claim) in draw.puzzle.claims.indexed) {
          expect(mismatches.contains(speaker), knightsTruth(claim, speaker, _mask(wrong)) != wrong[speaker]);
        }
      }
      expect(_rules.solved(draw.puzzle, draw.solution.sublist(1)), isFalse);
      expect(_rules.solved(draw.puzzle, [...draw.solution, true]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(9, tier);
        final json = jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle)));
        final puzzle = _rules.decodePuzzle(json);
        expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
        final answer = jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution)));
        expect(answer, isA<String>());
        expect(_rules.solved(puzzle, _rules.decodeAnswer(answer)), isTrue);
      }
      expect(_rules.decodeAnswer('101'), [true, false, true]);
      // 甲「我们两个人全是无赖」、乙「甲是无赖」：唯一解（甲无赖、乙骑士）。
      expect(_rules.decodePuzzle({'claims': [[4, 0], [1, 0]]}).people, 2);
      for (final bad in <Object?>[
        null,
        '[[4,0],[1,0]]',
        {'claims': null},
        {'claims': [[4, 0]]},
        {'claims': List.filled(knightsMaxPeople + 1, [4, 0])},
        {'claims': [[4, 0], [99, 0]]},
        {'claims': [[4, 0], [1]]},
        {'claims': [[4, 0], [1, 0, 1]]},
        {'claims': [[4, 0], [1, 1]]},
        {'claims': [[4, 0], [1, 2]]},
        {'claims': [[4, 0], [1, -1]]},
        {'claims': [[4, 0], [1, 1.5]]},
        {'claims': [[4, 0], [1, '0']]},
        {'claims': [[4, 0], '1,0']},
        {'claims': [[5, 0], [1, 0]]},
        {'claims': [[6, 2], [1, 0]]},
        {'claims': [[4, 3], [1, 0]]},
        {'claims': [[8, 1, 0], [1, 0]]},
        {'claims': [[9, 0, 1], [1, 0]]},
        // 甲「乙是骑士」、乙「甲是骑士」：两组都成立，不是题。
        {'claims': [[0, 1], [0, 0]]},
        // 甲「我们两个人全是无赖」、乙「甲是骑士」：没有一组成立。
        {'claims': [[4, 0], [0, 0]]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>[null, 1, '', '1', '1010101', '10x', '1 0', [1, 0]]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });

    test('句子按结构说成口语，名字只用天干；登记在逻辑推理、能进挑战，一句话玩法十个字以内', () {
      String say(KnightsClaim claim, int speaker, int people) => knightsSentence(claim, speaker, people);
      expect(say(_claim(KnightsClaimKind.knave, 2), 0, 3), '丙是无赖。');
      expect(say(_claim(KnightsClaimKind.same, 3), 0, 4), '我和丁是同一类人。');
      expect(say(_claim(KnightsClaimKind.different, 3), 0, 4), '我和丁不是同一类人。');
      expect(say(_claim(KnightsClaimKind.atLeast, 2), 0, 5), '我们五个人里至少有两个骑士。');
      expect(say(_claim(KnightsClaimKind.atMost, 1), 0, 4), '我们四个人里最多只有一个骑士。');
      expect(say(_claim(KnightsClaimKind.exactly, 0), 0, 4), '我们四个人全是无赖。');
      expect(say(_claim(KnightsClaimKind.exactly, 3), 0, 6), '我们六个人里恰好有三个骑士。');
      expect(say(_claim(KnightsClaimKind.implies, 1, 4), 0, 5), '如果乙是骑士，那么戊就是无赖。');
      expect(say(_claim(KnightsClaimKind.eitherKnave, 1, 4), 0, 5), '乙和戊至少有一个是无赖。');
      expect(say(_claim(KnightsClaimKind.eitherKnave, 1, 4), 4, 5), '我和乙至少有一个是无赖。');
      expect(say(_claim(KnightsClaimKind.wouldSay, 1, 2), 2, 5), '乙会说我是无赖。');
      expect(knightsPhrases(_claim(KnightsClaimKind.atLeast, 2), 0, 5), ['我们五个人里', '至少有两个骑士。']);
      expect(knightsNames, ['甲', '乙', '丙', '丁', '戊', '己']);
      final game = playgroundCatalog.firstWhere((game) => game.id == 'knights');
      expect(game.group, logicGroup);
      expect(game.challengeable, isTrue);
      expect(game.summary.length, lessThanOrEqualTo(10));
    });
  });

  group('骑士与无赖对局页', () {
    testWidgets('标签直接选、再点取消，撤销按步退回；全部定了判错只标对不上的人并重震；改对后卡片依次翻一下再弹新纪录，可换到下一档', (tester) async {
      final semantics = tester.ensureSemantics();
      final haptics = _haptics(tester);
      final store = await _open(tester, seed: 4);
      final draw = _rules.generate(4, PuzzleTier.entry);
      final puzzle = draw.puzzle, solution = draw.solution;
      expect(_status(0, 2), findsOneWidget);
      expect(find.bySemanticsLabel(_label(puzzle, 0, '未定')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);
      // 标签触区至少 48。
      expect(tester.getSize(_chip(0, true)).height, greaterThanOrEqualTo(48));

      // 选骑士、再点一次取消；撤销两步：先回到骑士，再回到未定。
      await _tapChip(tester, 0, true);
      expect(find.bySemanticsLabel(_label(puzzle, 0, '骑士')), findsOneWidget);
      expect(tester.getSemantics(_chip(0, true)), isSemantics(label: '骑士', isButton: true, isSelected: true));
      expect(_status(1, 2), findsOneWidget);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      await _tapChip(tester, 0, true);
      expect(find.bySemanticsLabel(_label(puzzle, 0, '未定')), findsOneWidget);
      expect(_status(0, 2), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(find.bySemanticsLabel(_label(puzzle, 0, '骑士')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _step(tester);
      expect(find.bySemanticsLabel(_label(puzzle, 0, '未定')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '撤销')).onPressed, isNull);

      // 甲标反、乙标对：全部定了就判，只有话和身份对不上的人标出来，重震一下，不弹结果。
      final wrong = [!solution[0], solution[1]];
      final mismatches = knightsMismatches(puzzle, _mask(wrong));
      expect(mismatches, isNotEmpty);
      haptics.clear();
      await _tapChip(tester, 0, wrong[0]);
      await _tapChip(tester, 1, wrong[1]);
      for (var person = 0; person < 2; person++) {
        expect(find.bySemanticsLabel(_label(puzzle, person, wrong[person] ? '骑士' : '无赖', mismatch: mismatches.contains(person))), findsOneWidget);
      }
      expect(haptics.last, 'HapticFeedbackType.heavyImpact');
      expect(find.text('新纪录'), findsNothing);
      expect(_status(2, 2), findsOneWidget);

      // 甲直接改选另一个标签：解开。卡片先翻（中途看上去只剩薄薄一条），翻完才弹结果。
      final height = tester.getRect(_card(0)).height;
      await tester.ensureVisible(_chip(0, solution[0]));
      await tester.tap(_chip(0, solution[0]));
      await tester.pump();
      var thinnest = height;
      for (var frame = 0; frame < 20 && find.text('新纪录').evaluate().isEmpty; frame++) {
        thinnest = math.min(thinnest, tester.getRect(_card(0)).height);
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(thinnest, lessThan(height * .5));
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('2 人'), findsOneWidget);
      expect(find.textContaining('判错 1 次'), findsOneWidget);
      expect(store.best('knights', PuzzleTier.entry), isNotNull);

      await tester.tap(find.text('换到简单'));
      await tester.pumpAndSettle();
      expect(store.tierOf('knights'), PuzzleTier.easy);
      expect(_status(0, 3), findsOneWidget);
      expect(_card(2), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('判错时对不上的卡片左右晃一下，晃完回原位；这一题从头来清掉标记', (tester) async {
      final semantics = tester.ensureSemantics();
      await _open(tester, seed: 6, tier: PuzzleTier.normal);
      final draw = _rules.generate(6, PuzzleTier.normal);
      final wrong = [...draw.solution]..[0] = !draw.solution[0];
      final mismatch = knightsMismatches(draw.puzzle, _mask(wrong)).first;
      for (var person = 0; person < wrong.length - 1; person++) {
        await _tapChip(tester, person, wrong[person]);
      }
      final last = wrong.length - 1;
      await tester.ensureVisible(_chip(last, wrong[last]));
      await tester.pump();
      final rest = tester.getRect(_card(mismatch)).left;
      await tester.tap(_chip(last, wrong[last]));
      await tester.pump();
      var farthest = 0.0;
      for (var frame = 0; frame < 12; frame++) {
        await tester.pump(const Duration(milliseconds: 40));
        farthest = math.max(farthest, (tester.getRect(_card(mismatch)).left - rest).abs());
      }
      expect(farthest, greaterThan(2));
      await _step(tester);
      expect(tester.getRect(_card(mismatch)).left, closeTo(rest, .01));

      await tester.tap(find.byTooltip('更多操作'));
      await _step(tester);
      await tester.tap(find.text('这一题从头来'));
      await _step(tester);
      expect(_status(0, 4), findsOneWidget);
      expect(find.bySemanticsLabel(_label(draw.puzzle, 0, '未定')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('对不上')), findsNothing);
      semantics.dispose();
    });

    testWidgets('减少动画：判错不晃，解开不翻、直接弹结果', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await _open(tester, seed: 2);
      final solution = _rules.generate(2, PuzzleTier.entry).solution;
      await _tapChip(tester, 0, !solution[0]);
      final rest = tester.getRect(_card(0));
      await tester.tap(_chip(1, solution[1]));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(_card(0)), rest);
      await tester.tap(_chip(0, solution[0]));
      await tester.pump();
      await tester.pump();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('专家档六张卡在 360 宽、1.3 倍字号下不溢出，滚动区带边缘渐隐，滚到底能点到最后一个人', (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(720, 1400);
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _open(tester, seed: 1, tier: PuzzleTier.expert);
      expect(find.byType(CampusScrollFade), findsOneWidget);
      expect(_status(0, 6), findsOneWidget);
      final viewport = tester.getRect(find.byType(SingleChildScrollView));
      expect(tester.getRect(_card(5)).bottom, greaterThan(viewport.bottom));
      await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(tester.getRect(_card(5)).bottom, lessThanOrEqualTo(viewport.bottom));
      await tester.tap(_chip(5, false));
      await _step(tester);
      expect(_status(1, 6), findsOneWidget);
      semantics.dispose();
    });
  });
}
