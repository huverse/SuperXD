import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/river/river_page.dart';
import 'package:superxd/playground/puzzle/river/river_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

const _rules = RiverRules();

RiverPuzzle _farmer() => const RiverPuzzle(variant: RiverVariant.farmer, capacity: 2, people: [
  (role: RiverRole.farmer, family: -1),
  (role: RiverRole.wolf, family: -1),
  (role: RiverRole.goat, family: -1),
  (role: RiverRole.cabbage, family: -1),
]);

// 页面上每个人的读屏名字（大人、小孩按出场顺序叫「第几个」）。
List<String> _labels(RiverPuzzle puzzle) {
  final people = puzzle.people;
  return [
    for (var index = 0; index < people.length; index++)
      people[index].role == RiverRole.adult || people[index].role == RiverRole.kid
          ? '第${people.take(index + 1).where((item) => item.role == people[index].role).length}个${riverName(people[index])}'
          : riverName(people[index]),
  ];
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；动画按固定时长推进。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// 把船上的人调成 wanted：先把多余的点下船，再把不在船上的点上船（船坐满时先上会被拒）。
Future<void> _seat(WidgetTester tester, List<String> labels, Set<int> wanted) async {
  for (final boarding in [false, true]) {
    for (var index = 0; index < labels.length; index++) {
      final aboard = find.bySemanticsLabel(RegExp('^${labels[index]}，在船上')).evaluate().isNotEmpty;
      if (aboard != wanted.contains(index) && aboard != boarding) {
        await tester.tap(find.bySemanticsLabel(RegExp('^${labels[index]}，')));
        await _frames(tester, 260);
      }
    }
  }
}

void main() {
  group('过河问题规则', () {
    test('开船前的检查：空船、超载、不在这一岸、没人会划、留下的与到岸的都要合规', () {
      final puzzle = _farmer();
      final everyone = puzzle.everyone;
      expect(riverCheck(puzzle, everyone, riverLeft, 0)!.fault, RiverFault.empty);
      expect(riverCheck(puzzle, everyone, riverLeft, riverMask([0, 1, 2]))!.fault, RiverFault.crowded);
      expect(riverCheck(puzzle, everyone, riverLeft, riverMask([2]))!.fault, RiverFault.noRower);
      // 农夫单独走：左岸剩狼、羊、白菜，狼吃羊。
      final alone = riverCheck(puzzle, everyone, riverLeft, riverMask([0]))!;
      expect((alone.fault, alone.place), (RiverFault.eaten, RiverPlace.left));
      expect(alone.people, [1, 2]);
      // 带羊走合规；船在右岸时左岸的人不能上船。
      expect(riverCheck(puzzle, everyone, riverLeft, riverMask([0, 2])), isNull);
      expect(riverCheck(puzzle, riverMask([0, 1, 3]), riverRight, riverMask([1]))!.fault, RiverFault.absent);

      // 大人与小孩：到岸后小孩比大人多（有大人时）不行，全是小孩可以。
      const guardians = RiverPuzzle(variant: RiverVariant.guardians, capacity: 2, people: [
        (role: RiverRole.adult, family: -1), (role: RiverRole.adult, family: -1), (role: RiverRole.kid, family: -1), (role: RiverRole.kid, family: -1), (role: RiverRole.kid, family: -1),
      ]);
      expect(riverTrouble(guardians, riverMask([0, 2, 3]), RiverPlace.right)!.fault, RiverFault.outnumbered);
      expect(riverTrouble(guardians, riverMask([2, 3, 4]), RiverPlace.right), isNull);

      // 父子：孩子的爸爸不在时不能和别人家的爸爸在一起，船上也算。
      const families = RiverPuzzle(variant: RiverVariant.families, capacity: 2, people: [
        (role: RiverRole.father, family: 0), (role: RiverRole.son, family: 0), (role: RiverRole.father, family: 1), (role: RiverRole.son, family: 1),
      ]);
      final onBoat = riverCheck(families, families.everyone, riverLeft, riverMask([1, 2]))!;
      expect((onBoat.fault, onBoat.place), (RiverFault.unguarded, RiverPlace.boat));
      expect(onBoat.people, [1, 2]);
      expect(riverTrouble(families, riverMask([0, 1, 2]), RiverPlace.left), isNull);
    });

    test('每档出的题解得开，最少次数落在区间里，参考解判定通过，难度分逐档不降且出题快', () {
      final watch = Stopwatch()..start();
      var previous = 0;
      for (final tier in PuzzleTier.values) {
        final scores = <int>{};
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          expect(_rules.solved(draw.puzzle, draw.solution), isTrue, reason: '$tier $seed');
          expect(_rules.solved(draw.puzzle, const []), isFalse);
          expect(riverSolve(draw.puzzle)!.length, draw.solution.length);
          scores.add(_rules.difficulty(draw.puzzle));
        }
        expect(scores.reduce((low, score) => score < low ? score : low), greaterThanOrEqualTo(previous), reason: '$tier');
        previous = scores.reduce((high, score) => score > high ? score : high);
      }
      expect(_rules.generate(4, PuzzleTier.normal).solution, _rules.generate(4, PuzzleTier.normal).solution);
      expect(watch.elapsedMilliseconds, lessThan(4000));
    });

    test('按规则判定：任何一次违规、没送完、超长都不算解开', () {
      final puzzle = _farmer();
      final solution = riverSolve(puzzle)!;
      expect(solution.length, 7);
      expect(_rules.solved(puzzle, solution), isTrue);
      expect(_rules.solved(puzzle, solution.sublist(0, 6)), isFalse);
      expect(_rules.solved(puzzle, [[0], ...solution]), isFalse);
      expect(_rules.solved(puzzle, [[0, 9]]), isFalse);
      expect(_rules.solved(puzzle, List.filled(riverMaxCrossings + 1, [0])), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        final draw = _rules.generate(7, tier);
        final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle))));
        expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
        expect(_rules.solved(puzzle, _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))))), isTrue);
      }
      for (final bad in <Object?>[
        null,
        {'variant': 'boat', 'capacity': 2, 'people': [0, 1, 2, 3]},
        {'variant': 'farmer', 'capacity': 3, 'people': [0, 1, 2, 3]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 1, 3]},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 4]},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 5, 0]},
        {'variant': 'families', 'capacity': 2, 'people': [10, 11, 12]},
        {'variant': 'families', 'capacity': 2, 'people': [10, 13]},
        {'variant': 'families', 'capacity': 9, 'people': [10, 11, 12, 13]},
        {'variant': 'families', 'capacity': 2, 'people': [10, 11, 12, 13, 99]},
        {'variant': 'farmer', 'capacity': 2, 'people': '0123'},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      for (final bad in <Object?>['0', [<int>[]], [[0, 0]], [[0, 1, 2, 3, 4]], [[-1]], [[10]], List.filled(riverMaxCrossings + 1, [0])]) {
        expect(() => _rules.decodeAnswer(bad), throwsFormatException, reason: '$bad');
      }
    });
  });

  group('过河问题对局页', () {
    Future<RiverPuzzle> open(WidgetTester tester, PuzzleTier tier, int seed) async {
      final store = PlaygroundStore.memory();
      await store.chooseTier('river', tier);
      final game = playgroundCatalog.firstWhere((game) => game.id == 'river');
      await tester.pumpWidget(MaterialApp(theme: campusTheme(), home: RiverPage(game: game, store: store, seeds: () => seed)));
      await tester.pumpAndSettle();
      return _rules.generate(seed, tier).puzzle;
    }

    testWidgets('违规不开船、说明原因并不计次；撤销按整次退回；按最少走法走完弹新纪录', (tester) async {
      final semantics = tester.ensureSemantics();
      final puzzle = await open(tester, PuzzleTier.entry, 1);
      final labels = _labels(puzzle);
      expect(find.textContaining('最少 7 次'), findsOneWidget);

      // 农夫单独走：左岸剩狼和羊（或羊和白菜），开不了船。
      await _seat(tester, labels, {0});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.text('左岸没人看着，狼会吃掉羊'), findsOneWidget);
      expect(find.textContaining('渡河 0 次'), findsOneWidget);
      await _frames(tester, 4500);

      // 带羊过去再撤销：回到开局，农夫和羊都在左岸。
      final goat = puzzle.people.indexWhere((person) => person.role == RiverRole.goat);
      await _seat(tester, labels, {0, goat});
      await tester.tap(find.text('开船'));
      await _frames(tester, 600);
      expect(find.textContaining('渡河 1 次'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 600);
      expect(find.textContaining('渡河 0 次'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^羊，在(左岸|船上)')), findsOneWidget);

      for (final crossing in riverSolve(puzzle)!) {
        await _seat(tester, labels, crossing.toSet());
        await tester.tap(find.text('开船'));
        await _frames(tester, 600);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('7 次'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('父子题：孩子和别人家的爸爸同船开不了，按最少走法走完', (tester) async {
      final semantics = tester.ensureSemantics();
      final puzzle = await open(tester, PuzzleTier.normal, 2);
      final labels = _labels(puzzle);
      final people = puzzle.people;
      final son = people.indexWhere((person) => person.role == RiverRole.son);
      final other = people.indexWhere((person) => person.role == RiverRole.father && person.family != people[son].family);
      await _seat(tester, labels, {son, other});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.textContaining('不能和${riverName(people[other])}待在一起'), findsOneWidget);
      await _frames(tester, 4500);
      for (final crossing in riverSolve(puzzle)!) {
        await _seat(tester, labels, crossing.toSet());
        await tester.tap(find.text('开船'));
        await _frames(tester, 600);
      }
      await tester.pumpAndSettle();
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });
  });
}
