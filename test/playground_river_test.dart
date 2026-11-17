import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/playground/playground_catalog.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle/river/river_page.dart';
import 'package:superxd/playground/puzzle/river/river_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_theme.dart';

import '../tool/challenge_bank.dart';

const _rules = RiverRules();

RiverPerson _one(RiverRole role, [int family = -1]) => (role: role, family: family);

RiverPuzzle _farmer() => RiverPuzzle(variant: RiverVariant.farmer, capacity: 2, people: [_one(RiverRole.farmer), _one(RiverRole.wolf), _one(RiverRole.goat), _one(RiverRole.cabbage)], rowers: 1);

// 大人在前、小孩在后；rowers 为空是人人会划。
RiverPuzzle _guardians(int adults, int kids, int capacity, {List<int>? rowers, bool boat = false}) => RiverPuzzle(
  variant: RiverVariant.guardians,
  capacity: capacity,
  people: [for (var index = 0; index < adults; index++) _one(RiverRole.adult), for (var index = 0; index < kids; index++) _one(RiverRole.kid)],
  rowers: rowers == null ? (1 << (adults + kids)) - 1 : riverMask(rowers),
  boat: boat,
);

// 第 f 家在下标 2f（爸爸）、2f + 1（孩子）。
RiverPuzzle _families(int pairs, int capacity, {List<int>? rowers}) => RiverPuzzle(
  variant: RiverVariant.families,
  capacity: capacity,
  people: [for (var family = 0; family < pairs; family++) ...[_one(RiverRole.father, family), _one(RiverRole.son, family)]],
  rowers: rowers == null ? (1 << (pairs * 2)) - 1 : riverMask(rowers),
  boat: true,
);

// 家庭过河原题：0 爸爸、1 妈妈、2 3 儿子、4 5 女儿、6 警察、7 小偷，只有爸爸、妈妈、警察会划船，船坐 2 人。
RiverPuzzle _household({List<int> rowers = const [0, 1, 6]}) => RiverPuzzle(
  variant: RiverVariant.household,
  capacity: 2,
  people: [_one(RiverRole.dad), _one(RiverRole.mom), _one(RiverRole.boy), _one(RiverRole.boy), _one(RiverRole.girl), _one(RiverRole.girl), _one(RiverRole.police), _one(RiverRole.thief)],
  rowers: riverMask(rowers),
  boat: true,
);

RiverPuzzle _bridge(List<int> minutes, {int capacity = 2, int limit = riverMaxLimit}) => RiverPuzzle(
  variant: RiverVariant.bridge,
  capacity: capacity,
  people: [for (final _ in minutes) _one(RiverRole.walker)],
  rowers: (1 << minutes.length) - 1,
  minutes: minutes,
  limit: limit,
);

// 测试另写的最少次数（桥与火把是最短分钟）：不走求解器的查表，直接拿 riverCheck 逐个坐法试，按代价从小到大展开（火把不限）。
int _bruteLeast(RiverPuzzle puzzle) {
  final open = RiverPuzzle(variant: puzzle.variant, capacity: puzzle.capacity, people: puzzle.people, rowers: puzzle.rowers, boat: puzzle.boat, minutes: puzzle.minutes, limit: puzzle.timed ? riverMaxLimit : 0);
  final groups = [for (var group = 1; group <= open.everyone; group++) if (riverBits(group) <= open.capacity) group];
  final cost = <int, int>{open.everyone * 2: 0};
  final done = <int>{};
  while (true) {
    int? best;
    for (final MapEntry(key: state, value: spent) in cost.entries) {
      if (!done.contains(state) && (best == null || spent < cost[best]!)) best = state;
    }
    if (best == null) return -1;
    if (best == riverRight) return cost[best]!;
    done.add(best);
    final left = best >> 1, side = best & 1;
    for (final group in groups) {
      if (riverCheck(open, left, side, group) != null) continue;
      final next = riverAfter(left, side, group) * 2 + 1 - side;
      final reach = cost[best]! + riverCost(open, group);
      if ((cost[next] ?? reach + 1) > reach) cost[next] = reach;
    }
  }
}

// 各档难易分的区间与坐船题最少次数的下限（同 RiverRules 的 _bands、_floors）。
const _bands = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 5), PuzzleTier.hard: (6, 7), PuzzleTier.expert: (8, 10)};
const _floors = {PuzzleTier.entry: 5, PuzzleTier.easy: 5, PuzzleTier.normal: 7, PuzzleTier.hard: 9, PuzzleTier.expert: 11};

// 页面上每个人的读屏名字（大人、小孩按出场顺序叫「第几个」，桥与火把按分钟）。
List<String> _labels(RiverPuzzle puzzle) {
  final people = puzzle.people;
  return [
    for (var index = 0; index < people.length; index++)
      switch (people[index].role) {
        RiverRole.walker => '过桥 ${puzzle.minutes[index]} 分钟的人',
        RiverRole.adult || RiverRole.kid => '第${people.take(index + 1).where((item) => item.role == people[index].role).length}个${riverName(puzzle, index)}',
        _ => riverName(puzzle, index),
      },
  ];
}

int _seedWhere(PuzzleTier tier, bool Function(RiverPuzzle puzzle) wanted) {
  for (var seed = 0; seed < 400; seed++) {
    if (wanted(_rules.generate(seed, tier).puzzle)) return seed;
  }
  throw StateError('$tier 档找不到要的题');
}

// 对局中计时器每秒出帧，pumpAndSettle 等不到停；动画按固定时长推进。
Future<void> _frames(WidgetTester tester, int millis) async {
  for (var elapsed = 0; elapsed < millis; elapsed += 16) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

// 把船上（桥头）的人调成 wanted：先把多余的点下船，再把不在船上的点上船（船坐满时先上会被拒）。
Future<void> _seat(WidgetTester tester, List<String> labels, Set<int> wanted) async {
  for (final boarding in [false, true]) {
    for (var index = 0; index < labels.length; index++) {
      final aboard = find.bySemanticsLabel(RegExp('^${RegExp.escape(labels[index])}，(会划船，)?在(船上|桥头)')).evaluate().isNotEmpty;
      if (aboard != wanted.contains(index) && aboard != boarding) {
        await tester.tap(find.bySemanticsLabel(RegExp('^${RegExp.escape(labels[index])}，')));
        await _frames(tester, 260);
      }
    }
  }
}

void main() {
  group('过河问题规则', () {
    test('开船前的检查：空船、超载、不在这一岸、没人会划、吃、管不过来（船上也算）、孩子和别人家的爸爸、骂孩子、小偷、火把不够', () {
      final farmer = _farmer();
      final everyone = farmer.everyone;
      expect(riverCheck(farmer, everyone, riverLeft, 0)!.fault, RiverFault.empty);
      expect(riverCheck(farmer, everyone, riverLeft, riverMask([0, 1, 2]))!.fault, RiverFault.crowded);
      expect(riverCheck(farmer, everyone, riverLeft, riverMask([2]))!.fault, RiverFault.noRower);
      // 农夫单独走：左岸剩狼、羊、白菜，狼吃羊。
      final alone = riverCheck(farmer, everyone, riverLeft, riverMask([0]))!;
      expect((alone.fault, alone.place), (RiverFault.eaten, RiverPlace.left));
      expect(alone.people, [1, 2]);
      expect(riverCheck(farmer, everyone, riverLeft, riverMask([0, 2])), isNull);
      expect(riverCheck(farmer, riverMask([0, 1, 3]), riverRight, riverMask([1]))!.fault, RiverFault.absent);
      // 别的食物链：狗咬猫。
      final dogs = RiverPuzzle(variant: RiverVariant.farmer, capacity: 2, people: [_one(RiverRole.farmer), _one(RiverRole.dog), _one(RiverRole.cat), _one(RiverRole.mouse)], rowers: 1);
      expect(riverCheck(dogs, dogs.everyone, riverLeft, riverMask([0, 3]))!.people, [1, 2]);

      // 大人与小孩：到岸后小孩比大人多（有大人时）不行，全是小孩可以；只有带桨的会划。
      final guardians = _guardians(2, 3, 2, rowers: [2]);
      expect(riverTrouble(guardians, riverMask([0, 2, 3]), RiverPlace.right)!.fault, RiverFault.outnumbered);
      expect(riverTrouble(guardians, riverMask([2, 3, 4]), RiverPlace.right), isNull);
      expect(riverCheck(guardians, guardians.everyone, riverLeft, riverMask([0]))!.fault, RiverFault.noRower);
      // 船上也算：一个大人带两个小孩上船，两岸都没事也开不了；船上不算时开得了。
      final crowded = _guardians(3, 2, 3, boat: true), loose = _guardians(3, 2, 3);
      final onBoat = riverCheck(crowded, riverMask([0, 3, 4]), riverLeft, riverMask([0, 3, 4]))!;
      expect((onBoat.fault, onBoat.place), (RiverFault.outnumbered, RiverPlace.boat));
      expect(onBoat.people, [3, 4]);
      expect(riverCheck(loose, riverMask([0, 3, 4]), riverLeft, riverMask([0, 3, 4])), isNull);

      // 父子：孩子的爸爸不在时不能和别人家的爸爸在一起，船上也算。
      final families = _families(2, 2);
      final mixed = riverCheck(families, families.everyone, riverLeft, riverMask([1, 2]))!;
      expect((mixed.fault, mixed.place), (RiverFault.unguarded, RiverPlace.boat));
      expect(mixed.people, [1, 2]);
      expect(riverTrouble(families, riverMask([0, 1, 2]), RiverPlace.left), isNull);

      // 家庭过河：爸爸不在妈妈骂儿子、妈妈不在爸爸骂女儿、警察不在小偷欺负家里人，船上也算。
      final household = _household();
      expect(riverTrouble(household, riverMask([1, 2]), RiverPlace.left)!.people, [1, 2]);
      expect(riverTrouble(household, riverMask([0, 1, 2]), RiverPlace.left), isNull);
      final scolded = riverTrouble(household, riverMask([0, 5]), RiverPlace.right)!;
      expect(scolded.fault, RiverFault.scolded);
      expect(scolded.people, [0, 5]);
      final robbed = riverTrouble(household, riverMask([7, 3]), RiverPlace.right)!;
      expect(robbed.fault, RiverFault.robbed);
      expect(robbed.people, [7, 3]);
      expect(riverTrouble(household, riverMask([6, 7, 3]), RiverPlace.right), isNull);
      expect(riverTrouble(household, riverMask([7]), RiverPlace.right), isNull);
      final boatScold = riverCheck(household, household.everyone, riverLeft, riverMask([1, 2]))!;
      expect((boatScold.fault, boatScold.place), (RiverFault.scolded, RiverPlace.boat));
      expect(riverCheck(household, household.everyone, riverLeft, riverMask([2, 3]))!.fault, RiverFault.noRower);

      // 桥与火把：按船上最慢的人算分钟，正好烧完可以，多一分钟不行，牵涉的是最慢的那个。
      final bridge = _bridge([1, 2, 5, 10], limit: 17);
      expect(riverCost(bridge, riverMask([0, 3])), 10);
      expect(riverCheck(bridge, bridge.everyone, riverLeft, riverMask([2, 3]), spent: 7), isNull);
      final late = riverCheck(bridge, bridge.everyone, riverLeft, riverMask([2, 3]), spent: 8)!;
      expect(late.fault, RiverFault.overtime);
      expect(late.people, [3]);
      expect(riverCheck(bridge, bridge.everyone, riverLeft, riverMask([0, 1, 2]))!.fault, RiverFault.crowded);
    });

    test('经典原题的最少次数与最短分钟，另写的逐个坐法搜索给出同样的数', () {
      final classics = <(RiverPuzzle, int)>[
        (_farmer(), 7),
        (_guardians(3, 3, 2), 11),
        (_guardians(3, 3, 2, rowers: [0, 3]), 13),
        (_guardians(5, 3, 3, rowers: [5], boat: true), 9),
        (_families(3, 2), 11),
        (_household(), 17),
        (_bridge([1, 2, 5, 10]), 17),
        (_bridge([1, 2, 5, 10], capacity: 3), 13),
      ];
      for (final (puzzle, least) in classics) {
        expect(riverLeast(puzzle), least, reason: puzzle.variant.name);
        expect(_bruteLeast(puzzle), least, reason: puzzle.variant.name);
        final solution = riverSolve(puzzle)!;
        expect(riverReplay(puzzle, solution)!.left, 0);
        expect(puzzle.timed ? riverReplay(puzzle, solution)!.spent : solution.length, least);
      }
      // 每档随机几道也对一遍（桥与火把按分钟）。
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 3; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          expect(riverLeast(puzzle), _bruteLeast(puzzle), reason: '$tier $seed');
        }
      }
    });

    test('每条机制都有用：拿掉哪条规矩、谁会划船或船上也算，最少次数都会变少；桥与火把要用到两个慢的一起走', () {
      for (final puzzle in [_farmer(), _guardians(3, 3, 2), _guardians(3, 3, 2, rowers: [0, 3]), _guardians(5, 3, 3, rowers: [5], boat: true), _families(3, 2), _household(), _bridge([1, 2, 5, 10], limit: 17)]) {
        expect(riverNeeded(puzzle), isTrue, reason: puzzle.variant.name);
      }
      // 两对父子船坐 2 人：没有那条规矩也是 5 次，是摆设。
      expect(riverNeeded(_families(2, 2)), isFalse);
      // 三大人两小孩船坐 3 人：人数规矩与只有一个大人会划都不影响最少次数。
      expect(riverNeeded(_guardians(3, 2, 3)), isFalse);
      expect(riverNeeded(_guardians(3, 2, 3, rowers: [0])), isFalse);
      // 三大人三小孩船坐 3 人：船上也算不改变最少次数。
      expect(riverNeeded(_guardians(3, 3, 3, boat: true)), isFalse);
      // 1、3、4、5 分钟：最快的人一个个送就最快，用不到技巧。
      expect(riverNeeded(_bridge([1, 3, 4, 5], limit: 14)), isFalse);
      expect(riverRelaxed(_bridge([1, 2, 5, 10]), escort: true), 19);
    });

    test('每档出的题：解得开、参考解判定通过、次数不低于下限、每条机制都有用、难易分在这一档（五档不重叠且逐档上升）、碎片是最少次数或分钟、出题快', () {
      final watch = Stopwatch()..start();
      var previous = 0;
      for (final tier in PuzzleTier.values) {
        final (low, high) = _bands[tier]!;
        expect(low, greaterThan(previous), reason: '$tier');
        previous = high;
        for (var seed = 0; seed < 20; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = draw.puzzle, least = riverLeast(puzzle);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: '$tier $seed');
          expect(_rules.solved(puzzle, const []), isFalse);
          expect(riverNeeded(puzzle), isTrue, reason: '$tier $seed');
          expect(_rules.complexity(puzzle), inInclusiveRange(low, high), reason: '$tier $seed');
          expect(_rules.fragment(puzzle, draw.solution), least);
          if (puzzle.timed) {
            expect(puzzle.limit, least);
            expect(riverReplay(puzzle, draw.solution)!.spent, least);
          } else {
            expect(draw.solution.length, least);
            expect(least, greaterThanOrEqualTo(_floors[tier]!), reason: '$tier $seed');
          }
        }
      }
      expect(jsonEncode(_rules.encodePuzzle(_rules.generate(4, PuzzleTier.normal).puzzle)), jsonEncode(_rules.encodePuzzle(_rules.generate(4, PuzzleTier.normal).puzzle)));
      expect(watch.elapsedMilliseconds, lessThan(4000));
    });

    test('每档的题多样：三种以上题型、题面几乎不重样、结构（题型、船位、各身份几个与谁会划）不少于 8 种', () {
      for (final tier in PuzzleTier.values) {
        final variants = <RiverVariant>{}, encodings = <String>{}, shapes = <String>{};
        for (var seed = 0; seed < 40; seed++) {
          final puzzle = _rules.generate(seed, tier).puzzle;
          variants.add(puzzle.variant);
          encodings.add(jsonEncode(_rules.encodePuzzle(puzzle)));
          final roles = [for (var index = 0; index < puzzle.count; index++) '${puzzle.people[index].role.name}${puzzle.rows(index)}${puzzle.timed ? puzzle.minutes[index] : ''}']..sort();
          shapes.add('${puzzle.variant.name} ${puzzle.capacity} ${puzzle.boat} $roles');
        }
        expect(variants.length, greaterThanOrEqualTo(3), reason: '$tier');
        expect(encodings.length, greaterThanOrEqualTo(30), reason: '$tier');
        expect(shapes.length, greaterThanOrEqualTo(8), reason: '$tier');
        // 桥与火把从普通档起才有（要用到技巧）。
        expect(variants.contains(RiverVariant.bridge), tier.index >= PuzzleTier.normal.index, reason: '$tier');
      }
    });

    // [人工决策-2026-11-17 14:17:05]（见 RiverRules.challengeDraw）：挑战里不出桥与火把，自由模式照常出。
    test('挑战出题（题库工具走的入口）各档都不出桥与火把，出的题照样过同样的检查、仍有三种以上题型；自由模式照常出；题库里也没有', () {
      for (final tier in PuzzleTier.values) {
        final (low, high) = _bands[tier]!;
        final variants = <RiverVariant>{};
        var bridges = 0;
        for (var seed = 0; seed < 60; seed++) {
          final draw = _rules.challengeDraw(seed, tier);
          final puzzle = draw.puzzle;
          expect(riverChallengeless.contains(puzzle.variant), isFalse, reason: '$tier $seed');
          variants.add(puzzle.variant);
          expect(_rules.solved(puzzle, draw.solution), isTrue, reason: '$tier $seed');
          expect(riverNeeded(puzzle), isTrue, reason: '$tier $seed');
          expect(_rules.complexity(puzzle), inInclusiveRange(low, high), reason: '$tier $seed');
          expect(draw.solution.length, greaterThanOrEqualTo(_floors[tier]!), reason: '$tier $seed');
          if (_rules.generate(seed, tier).puzzle.variant == RiverVariant.bridge) bridges++;
        }
        expect(variants.length, greaterThanOrEqualTo(3), reason: '$tier');
        expect(bridges > 0, tier.index >= PuzzleTier.normal.index, reason: '$tier 自由模式');
      }
      for (final tier in [PuzzleTier.normal, PuzzleTier.hard, PuzzleTier.expert]) {
        final entries = challengeBankEntries('local-test-seed-0001', 'river', tier, 40);
        expect(entries, hasLength(40));
        for (final entry in entries) {
          expect(_rules.decodePuzzle(jsonDecode(jsonEncode(entry['puzzle']))).variant, isNot(RiverVariant.bridge), reason: '${entry['id']}');
        }
      }
      // 判定照样认得桥与火把的题面（旧数据与判定向量不受影响）。
      final bridge = _rules.generate(_seedWhere(PuzzleTier.normal, (puzzle) => puzzle.timed), PuzzleTier.normal);
      expect(_rules.solved(_rules.decodePuzzle(_rules.encodePuzzle(bridge.puzzle)), bridge.solution), isTrue);
    });

    test('预计用时：五档中位数约 45、70、110、165、245 秒（±25%）且逐档上升，难度分由它取对数', () {
      const targets = {PuzzleTier.entry: 45, PuzzleTier.easy: 70, PuzzleTier.normal: 110, PuzzleTier.hard: 165, PuzzleTier.expert: 245};
      var previous = 0;
      for (final tier in PuzzleTier.values) {
        final seconds = [for (var seed = 1; seed <= 12; seed++) _rules.expectedSeconds(_rules.generate(seed * 7919, tier).puzzle)]..sort();
        final median = seconds[seconds.length ~/ 2];
        expect(median, inInclusiveRange(targets[tier]! * .75, targets[tier]! * 1.25), reason: '$tier $seconds');
        expect(median, greaterThan(previous), reason: '$tier');
        previous = median;
      }
      final puzzle = _rules.generate(1, PuzzleTier.hard).puzzle;
      expect(_rules.difficulty(puzzle), puzzleDifficulty(_rules.expectedSeconds(puzzle)));
    });

    test('按规则判定：另一种走法也算；任何一次违规、没送完、超长、火把烧完都不算解开', () {
      final puzzle = _farmer();
      final solution = riverSolve(puzzle)!;
      expect(_rules.solved(puzzle, solution), isTrue);
      // 第三趟先带白菜也行（和参考解不一样）。
      expect(_rules.solved(puzzle, [[0, 2], [0], [0, 3], [0, 2], [0, 1], [0], [0, 2]]), isTrue);
      expect(_rules.solved(puzzle, [[0, 2], [0], [0, 1], [0, 2], [0, 3], [0], [0, 2]]), isTrue);
      expect(_rules.solved(puzzle, solution.sublist(0, 6)), isFalse);
      expect(_rules.solved(puzzle, [[0], ...solution]), isFalse);
      expect(_rules.solved(puzzle, [[0, 9]]), isFalse);
      expect(_rules.solved(puzzle, List.filled(riverMaxCrossings + 1, [0])), isFalse);
      // 桥与火把：最快的人一个个送要 19 分钟，火把 17 分钟不够；两个慢的一起走正好 17 分钟。火把 19 分钟时前一种也行。
      final escort = [[0, 1], [0], [0, 2], [0], [0, 3]], trick = [[0, 1], [0], [2, 3], [1], [0, 1]];
      expect(_rules.solved(_bridge([1, 2, 5, 10], limit: 17), escort), isFalse);
      expect(_rules.solved(_bridge([1, 2, 5, 10], limit: 17), trick), isTrue);
      expect(_rules.solved(_bridge([1, 2, 5, 10], limit: 19), escort), isTrue);
      // 家庭过河原题：参考解通过，第一趟换成妈妈带儿子就不算。
      final household = _household(), reference = riverSolve(household)!;
      expect(_rules.solved(household, reference), isTrue);
      expect(_rules.solved(household, [[1, 2], ...reference.skip(1)]), isFalse);
    });

    test('编解码往返，坏输入抛 FormatException', () {
      for (final tier in PuzzleTier.values) {
        for (var seed = 0; seed < 4; seed++) {
          final draw = _rules.generate(seed, tier);
          final puzzle = _rules.decodePuzzle(jsonDecode(jsonEncode(_rules.encodePuzzle(draw.puzzle))));
          expect(_rules.encodePuzzle(puzzle), _rules.encodePuzzle(draw.puzzle));
          expect(_rules.solved(puzzle, _rules.decodeAnswer(jsonDecode(jsonEncode(_rules.encodeAnswer(draw.solution))))), isTrue);
        }
      }
      expect(_rules.puzzleVersion, 2);
      for (final bad in <Object?>[
        null,
        {'variant': 'boat', 'capacity': 2, 'people': [0, 1, 2, 3], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 5, 'people': [0, 1, 2, 3], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 18], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 1, 3], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 0, 2, 3], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 3], 'rowers': [0, 2]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 3], 'rowers': [1]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 3], 'rowers': <int>[]},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 3, 9], 'rowers': [0]},
        {'variant': 'farmer', 'capacity': 2, 'people': '0123', 'rowers': [0]},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 4], 'rowers': [0, 1], 'boat': false},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 4, 5, 5], 'rowers': [0, 1, 2, 3]},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 5, 5], 'rowers': [0, 1, 2], 'boat': false},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 4, 5], 'rowers': [1, 0], 'boat': false},
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 4, 5], 'rowers': [0, 3], 'boat': false},
        {'variant': 'families', 'capacity': 2, 'people': [100, 101, 102], 'rowers': [0, 1, 2]},
        {'variant': 'families', 'capacity': 2, 'people': [100, 103], 'rowers': [0, 1]},
        {'variant': 'families', 'capacity': 2, 'people': [100, 101, 112, 113], 'rowers': [0, 1, 2, 3]},
        {'variant': 'household', 'capacity': 2, 'people': [11, 11, 13], 'rowers': [0, 1]},
        {'variant': 'household', 'capacity': 2, 'people': [11, 12, 13, 15], 'rowers': [0, 1]},
        {'variant': 'household', 'capacity': 2, 'people': [11, 12, 15, 16], 'rowers': [0, 1, 2]},
        {'variant': 'household', 'capacity': 2, 'people': [11, 12, 13, 13, 13], 'rowers': [0, 1]},
        {'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2], 'minutes': [1, 2, 5, 10], 'limit': 17},
        {'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2, 3], 'minutes': [1, 2, 5], 'limit': 17},
        {'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2, 3], 'minutes': [1, 2, 5, 5], 'limit': 17},
        {'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2, 3], 'minutes': [1, 2, 5, 10], 'limit': 16},
        {'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2, 3], 'minutes': [1, 2, 5, 61], 'limit': 100},
        // 开局就犯规（小孩比大人多）与解不开（四样东西船只坐 2 人）。
        {'variant': 'guardians', 'capacity': 2, 'people': [4, 5, 5], 'rowers': [0, 1, 2], 'boat': false},
        {'variant': 'farmer', 'capacity': 2, 'people': [0, 1, 2, 3, 9], 'rowers': [0]},
      ]) {
        expect(() => _rules.decodePuzzle(bad), throwsFormatException, reason: '$bad');
      }
      expect(_rules.decodePuzzle({'variant': 'bridge', 'capacity': 2, 'people': [17, 17, 17, 17], 'rowers': [0, 1, 2, 3], 'minutes': [1, 2, 5, 10], 'limit': 17}).limit, 17);
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

    Future<void> play(WidgetTester tester, RiverPuzzle puzzle, List<String> labels) async {
      for (final crossing in riverSolve(puzzle)!) {
        await _seat(tester, labels, crossing.toSet());
        await tester.tap(find.text(puzzle.timed ? '过桥' : '开船'));
        await _frames(tester, 600);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('农夫过河：违规不开船、说明原因并不计次；撤销按整次退回；按最少走法走完弹新纪录', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere(PuzzleTier.entry, (puzzle) => puzzle.variant == RiverVariant.farmer);
      final puzzle = await open(tester, PuzzleTier.entry, seed);
      final labels = _labels(puzzle);
      expect(find.textContaining('最少 7 次'), findsOneWidget);
      expect(find.text('农夫过河'), findsOneWidget);

      // 农夫单独走：左岸剩下的三样里有一对会出事，开不了船。
      final farmer = puzzle.people.indexWhere((person) => person.role == RiverRole.farmer);
      final alone = riverCheck(puzzle, puzzle.everyone, riverLeft, 1 << farmer)!;
      final eater = alone.people[0], eaten = alone.people[1];
      final warning = '左岸没人看着，${riverName(puzzle, eater)}${puzzle.people[eater].role == RiverRole.dog ? '会咬' : '会吃掉'}${riverName(puzzle, eaten)}';
      await _seat(tester, labels, {farmer});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.text(warning), findsOneWidget);
      expect(find.textContaining('渡河 0 次'), findsOneWidget);

      // 照参考解的第一趟过去再撤销：回到开局。接着让人上船是一步能做的操作，过时的犯规提示马上收起（不等 4 秒）。
      final first = riverSolve(puzzle)!.first;
      final middle = first.firstWhere((index) => index != farmer);
      await _seat(tester, labels, first.toSet());
      expect(find.text(warning), findsNothing);
      await tester.tap(find.text('开船'));
      await _frames(tester, 600);
      expect(find.textContaining('渡河 1 次'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '撤销'));
      await _frames(tester, 600);
      expect(find.textContaining('渡河 0 次'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^${labels[middle]}，(会划船，)?在(左岸|船上)')), findsOneWidget);

      await play(tester, puzzle, labels);
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('7 次'), findsWidgets);
      semantics.dispose();
    });

    testWidgets('父子题：孩子和别人家的爸爸同船开不了，按最少走法走完', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere(PuzzleTier.hard, (puzzle) => puzzle.variant == RiverVariant.families);
      final puzzle = await open(tester, PuzzleTier.hard, seed);
      final labels = _labels(puzzle);
      final people = puzzle.people;
      final son = people.indexWhere((person) => person.role == RiverRole.son);
      final other = people.indexWhere((person) => person.role == RiverRole.father && person.family != people[son].family);
      await _seat(tester, labels, {son, other});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.textContaining('不能和${riverName(puzzle, other)}待在一起'), findsOneWidget);
      await _frames(tester, 4500);
      await play(tester, puzzle, labels);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('家庭过河：带桨的才会划（读屏念「会划船」），没人会划与爸爸一走妈妈会骂儿子都开不了，按最少走法走完', (tester) async {
      final semantics = tester.ensureSemantics();
      bool rows(RiverPuzzle puzzle, RiverRole role) => puzzle.rows(puzzle.people.indexWhere((person) => person.role == role));
      final seed = _seedWhere(PuzzleTier.entry, (puzzle) {
        return puzzle.variant == RiverVariant.household && puzzle.people.any((person) => person.role == RiverRole.boy) && rows(puzzle, RiverRole.dad) && !rows(puzzle, RiverRole.mom);
      });
      final puzzle = await open(tester, PuzzleTier.entry, seed);
      final labels = _labels(puzzle);
      final dad = puzzle.people.indexWhere((person) => person.role == RiverRole.dad), mom = puzzle.people.indexWhere((person) => person.role == RiverRole.mom);
      final boy = puzzle.people.indexWhere((person) => person.role == RiverRole.boy);
      expect(find.text('家庭过河'), findsOneWidget);
      expect(find.bySemanticsLabel('爸爸，会划船，在左岸'), findsOneWidget);
      expect(find.bySemanticsLabel('妈妈，在左岸'), findsOneWidget);

      await _seat(tester, labels, {mom});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.text('船上没有会划船的人'), findsOneWidget);
      // 爸爸一个人走：左岸剩妈妈和儿子。
      await _seat(tester, labels, {dad});
      await tester.tap(find.text('开船'));
      await _frames(tester, 300);
      expect(find.text('左岸：爸爸不在，妈妈会骂${riverName(puzzle, boy)}'), findsOneWidget);
      expect(find.textContaining('渡河 0 次'), findsOneWidget);
      await _frames(tester, 4500);
      await play(tester, puzzle, labels);
      expect(find.text('新纪录'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('桥与火把：状态写用了几分钟，火把不够烧时过不了桥并说明，撤销退回分钟，按最快走法走完正好烧完', (tester) async {
      final semantics = tester.ensureSemantics();
      final seed = _seedWhere(PuzzleTier.normal, (puzzle) => puzzle.variant == RiverVariant.bridge);
      final puzzle = await open(tester, PuzzleTier.normal, seed);
      final labels = _labels(puzzle);
      final limit = puzzle.limit;
      expect(find.text('过桥'), findsOneWidget);
      expect(find.textContaining('0/$limit 分钟'), findsOneWidget);
      expect(find.bySemanticsLabel('火把还能烧 $limit 分钟'), findsOneWidget);

      // 最慢的人一个人来回走，直到火把不够他再走一趟。
      final slowest = [for (var index = 0; index < puzzle.count; index++) index].reduce((most, index) => puzzle.minutes[index] > puzzle.minutes[most] ? index : most);
      final minutes = puzzle.minutes[slowest], trips = limit ~/ minutes;
      await _seat(tester, labels, {slowest});
      for (var trip = 0; trip < trips; trip++) {
        await tester.tap(find.text('过桥'));
        await _frames(tester, 600);
      }
      expect(find.textContaining('过桥 $trips 次'), findsOneWidget);
      expect(find.bySemanticsLabel('火把还能烧 ${limit - trips * minutes} 分钟'), findsOneWidget);
      await tester.tap(find.text('过桥'));
      await _frames(tester, 300);
      expect(find.text('火把只剩 ${limit - trips * minutes} 分钟，这一趟要 $minutes 分钟'), findsOneWidget);
      expect(find.textContaining('过桥 $trips 次'), findsOneWidget);
      for (var trip = 0; trip < trips; trip++) {
        await tester.tap(find.widgetWithText(FilledButton, '撤销'));
        await _frames(tester, 600);
      }
      expect(find.textContaining('0/$limit 分钟'), findsOneWidget);

      await play(tester, puzzle, labels);
      expect(find.text('新纪录'), findsOneWidget);
      expect(find.textContaining('用了 $limit 分钟'), findsOneWidget);
      semantics.dispose();
    });
  });
}
