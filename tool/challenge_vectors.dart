import 'dart:convert';
import 'dart:io';

import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/puzzle/balance/balance_rules.dart';
import 'package:superxd/playground/puzzle/flash/flash_rules.dart';
import 'package:superxd/playground/puzzle/hanoi/hanoi_rules.dart';
import 'package:superxd/playground/puzzle/ice/ice_rules.dart';
import 'package:superxd/playground/puzzle/river/river_rules.dart';
import 'package:superxd/playground/puzzle_rules.dart';

// 挑战判定的双端测试向量（人工决策见 lib/playground/challenge/challenge_rules.dart）：每个能进挑战的游戏、每档出几道题，
// 参考解与按固定种子改坏的答案各判一次，结果写进 server/test/vectors/challenge_judge_v1.json；服务端 TS 判定（test/challenge_judge.test.ts）
// 与客户端（test/challenge_vectors_test.dart）读同一份文件，结果必须一条不差。规则改了口径就重跑本工具，两端测试都要过。
// 运行：dart run tool/challenge_vectors.dart [--out <文件>]；本机对拍可加 --seeds <每档几道> --seed <种子>（只写到 --out，不进仓库）。
// 给某个游戏换题面写法（puzzleVersion 加一）的顺序：先 dart run tool/challenge_vectors.dart --freeze <游戏>，再改规则与版本号、服务端判定加上新版本，最后重跑本工具。
const challengeVectorsPath = 'server/test/vectors/challenge_judge_v1.json';
// 换了写法的旧版本的向量（服务端判定留给旧客户端，客户端规则里没有了）：加版本前 --freeze <游戏> 把那时的向量搬来，键是「游戏@版本」。
const challengeFrozenPath = 'server/test/vectors/challenge_judge_frozen.json';

// 一条判定结果：solved（附答案里自带的失误数）、unsolved 或 invalid（答案解码不了）。
Map<String, Object> challengeVerdict(String game, Object? puzzleJson, Object? answerJson) {
  final rules = challengeRules[game]!;
  final puzzle = rules.decodePuzzle(puzzleJson);
  final Object? answer;
  try {
    answer = rules.decodeAnswer(answerJson);
  } on FormatException {
    return {'kind': 'invalid'};
  }
  if (!rules.solved(puzzle, answer)) return {'kind': 'unsolved'};
  return {'kind': 'solved', 'penalties': rules.penalties(puzzle, answer)};
}

// JSON 里的一个叶子（整数、布尔、字符串）与它的路径。
List<List<Object>> _leaves(Object? json, [List<Object> path = const []]) => switch (json) {
  final Map<String, Object?> map => [for (final entry in map.entries) ..._leaves(entry.value, [...path, entry.key])],
  final List<Object?> list => [for (final (index, item) in list.indexed) ..._leaves(item, [...path, index])],
  _ => [path],
};

Object? _replace(Object? json, List<Object> path, Object? Function(Object? old) change) {
  if (path.isEmpty) return change(json);
  final head = path.first, rest = path.sublist(1);
  if (json is Map<String, Object?>) return {...json, head as String: _replace(json[head], rest, change)};
  final list = [...json as List<Object?>];
  list[head as int] = _replace(list[head], rest, change);
  return list;
}

Object? _bump(Object? leaf) => switch (leaf) {
  final int value => value + 1,
  final bool value => !value,
  final String value when value.isNotEmpty => (value.substring(0, value.length - 1)) + (value.endsWith('1') ? '0' : '1'),
  _ => 'x',
};

// 按固定种子把参考解改坏几种：改一个叶子、去掉最后一项、复制第一项接在末尾、整体倒过来、换成类型不对的值、空的。
// 改坏的答案有的仍然解得开（如换了等价的走法），结果一律以 Dart 规则判的为准。
List<Object?> _mutations(Object? answer, PuzzleRandom random) {
  final mutated = <Object?>[];
  final leaves = _leaves(answer);
  for (var round = 0; round < 3 && leaves.isNotEmpty; round++) {
    mutated.add(_replace(answer, leaves[random.nextInt(leaves.length)], _bump));
  }
  switch (answer) {
    case final List<Object?> list when list.isNotEmpty:
      mutated.addAll([list.sublist(0, list.length - 1), [...list, list.first], list.reversed.toList(), []]);
    case final String text when text.isNotEmpty:
      mutated.addAll([text.substring(0, text.length - 1), '${text}1', text.split('').reversed.join(), '']);
    case final Map<String, Object?> map:
      mutated.addAll([{...map}..remove(map.keys.last), {...map, 'extra': 1}]);
  }
  mutated.addAll(['oops', 7, null, {'answer': answer}]);
  return mutated;
}

// 记忆闪光：第一轮先点错一次，换下一组照规则点齐，再照参考解点完，解得开、失误 1 次。点错有两种：点一格不在这组里的
// （每种题型都算错，数字顺序里就是点了块外的格），按先后点的另给一份先点第二格的（格对先后错）。
List<Object?> _flashWithMistake(Object? puzzleJson, Object? reference) {
  final puzzle = const FlashRules().decodePuzzle(puzzleJson);
  final first = flashPattern(puzzle, 0, 0);
  final outside = [for (var cell = 0; cell < puzzle.side * puzzle.side; cell++) cell].firstWhere((cell) => !first.contains(cell));
  return [
    for (final wrong in [outside, if (puzzle.variant.ordered) first[1]]) [[wrong], flashPattern(puzzle, 0, 1), ...(reference as List).skip(1)],
  ];
}

Map<String, Object?> buildChallengeVectors({int seedsPerTier = 2, int seed = 0x5EED2026}) {
  final random = PuzzleRandom(seed);
  final games = <String, Object?>{};
  for (final MapEntry(key: game, value: rules) in challengeRules.entries) {
    final cases = <Map<String, Object?>>[];
    for (final tier in PuzzleTier.values) {
      for (var index = 0; index < seedsPerTier; index++) {
        final draw = rules.generate(random.nextUint32(), tier);
        final puzzle = rules.encodePuzzle(draw.puzzle);
        final reference = rules.encodeAnswer(draw.solution);
        final answers = [reference, ..._mutations(reference, random), if (game == 'flash') ..._flashWithMistake(puzzle, reference)];
        cases.add({
          'tier': tier.name,
          'puzzle': puzzle,
          'answers': [for (final answer in answers) {'answer': answer, 'expect': challengeVerdict(game, puzzle, answer)}],
        });
      }
    }
    cases.addAll(_goalCases(game, rules));
    cases.addAll(_trapCases(game, rules));
    if (rules is RiverRules) cases.addAll(_riverCases(game, rules));
    cases.addAll(_balanceCases(game));
    games[game] = cases;
  }
  // 每个游戏的题面写法版本：服务端按它核对自己的判定认得哪一版（test/challenge_judge.test.ts）。
  return {'version': 1, 'puzzleVersions': {for (final MapEntry(key: game, value: rules) in challengeRules.entries) game: rules.puzzleVersion}, 'games': games};
}

// 收碎片改目标的题面（人工决策见 challenge_rules.dart 的 11-14 23:11 那条）：记忆闪光镜像（照亮的点不算、点镜像的才算，每档一道、各题型都有；
// 另给一份第一下点了原来亮的那格、换下一组再点镜像的，算失误 1 次）、冰面滑行标了几个出口（判定仍只看终点）、汉诺塔见 _hanoiCases。用自己的固定种子出，不动上面已有的向量。
List<Map<String, Object?>> _goalCases(String game, PuzzleRules<Object?, Object?> rules) {
  Map<String, Object?> item(PuzzleTier tier, Object? puzzle, List<Object?> answers) => {
    'tier': tier.name,
    'puzzle': puzzle,
    'answers': [for (final answer in answers) {'answer': answer, 'expect': challengeVerdict(game, puzzle, answer)}],
  };
  final draw = rules.generate(0x60A1, PuzzleTier.normal);
  switch (draw.puzzle) {
    case FlashPuzzle():
      return [
        for (final tier in PuzzleTier.values)
          if (rules.generate(0x60A1, tier) case PuzzleDraw(puzzle: final FlashPuzzle flash, :final solution))
            item(tier, rules.encodePuzzle(flash.mirrored), [
              [for (var round = 0; round < flash.rounds.length; round++) flashPattern(flash.mirrored, round, 0)],
              rules.encodeAnswer(solution),
              if (flashShown(flash, 0, 0).where((cell) => !flashPattern(flash.mirrored, 0, 0).contains(cell)).firstOrNull case final decoy?)
                [[decoy], flashPattern(flash.mirrored, 0, 1), for (var round = 1; round < flash.rounds.length; round++) flashPattern(flash.mirrored, round, 0)],
            ]),
      ];
    case IcePuzzle():
      // 第 2 版的出口要和终点最少步数相同，不是每道题都挑得出：从同一个种子往后找第一道挑得出的。
      var seed = 0x60A1;
      while (iceExits(rules.generate(seed, PuzzleTier.normal).puzzle as IcePuzzle, PuzzleRandom(0x60A1)).length < 2) {
        seed++;
      }
      final ice = rules.generate(seed, PuzzleTier.normal);
      final labeled = (ice.puzzle as IcePuzzle).copyWith(exits: iceExits(ice.puzzle as IcePuzzle, PuzzleRandom(0x60A1)));
      return [item(PuzzleTier.normal, rules.encodePuzzle(labeled), [rules.encodeAnswer(ice.solution), <int>[]])];
    case HanoiPuzzle():
      return [..._hanoiCases(rules), ..._hanoiLimitCases(rules)];
    default:
      return const [];
  }
}

// 冰面滑行第 2 版的几种机关（专家档一道，自己的固定种子）：照参考解（解开）、多走一步滑不动的（超了步数上限）、
// 照参考解走到半路拐进冰洞（掉下去）、不管宝石的最短走法（宝石没收齐，同时可能碰上薄冰），两端都得判成一样；另加两道手搭的小图。
List<Map<String, Object?>> _trapCases(String game, PuzzleRules<Object?, Object?> rules) {
  final draw = rules.generate(0x7CE5, PuzzleTier.expert);
  if (draw.puzzle is! IcePuzzle) return const [];
  final ice = draw.puzzle as IcePuzzle, solution = draw.solution as List<int>;
  final answers = <Object?>[rules.encodeAnswer(solution)];
  var state = IceState(ice.start);
  final stuck = [for (var direction = 0; direction < iceDirections; direction++) direction].where((direction) => identical(iceMove(ice, state, direction), state)).firstOrNull;
  if (stuck != null) answers.add([stuck, ...solution]);
  // 沿参考解找第一个能拐进冰洞的局面。
  for (final (index, step) in solution.indexed) {
    final fall = [for (var direction = 0; direction < iceDirections; direction++) direction].where((direction) => iceMove(ice, state, direction).fallen).firstOrNull;
    if (fall != null) {
      answers.add([...solution.sublist(0, index), fall]);
      break;
    }
    state = iceMove(ice, state, step);
  }
  if (iceSolution(ice.copyWith(gems: const [])) case final greedy?) answers.add(greedy);
  Map<String, Object?> verdicts(String tier, Object? puzzle, List<Object?> answers) => {
    'tier': tier,
    'puzzle': puzzle,
    'answers': [for (final answer in answers) {'answer': answer, 'expect': challengeVerdict(game, puzzle, answer)}],
  };
  return [
    verdicts(PuzzleTier.expert.name, rules.encodePuzzle(ice), answers),
    // 手搭的两道 3×3（0 上、1 右、2 下、3 左），钉住移植时容易漏的口径（漏了哪条，下面就有一个答案两端判得不一样）：
    // 起点右边是冰洞：掉下去就结束，不能接着从洞里滑到终点（右、右）；上限 4 步，多走一步不算。
    verdicts('entry', rules.encodePuzzle(rules.decodePuzzle({'width': 3, 'height': 3, 'tiles': '030000000', 'gems': <int>[], 'start': 0, 'goal': 2, 'limit': 4})), [
      [1, 1],
      [2, 1, 0],
      [2, 1, 0, 0, 0],
    ]),
    // 第 0 行「终点 薄冰 冰」、第 1 行「岩石 岩石 雪地」、第 2 行「起点 宝石 冰」：右滑过宝石也收、上滑进雪地就停、
    // 向左滑过薄冰到终点，再往右就掉进它碎成的洞；朝岩石滑不动的那步也算一步；上限 6 步。
    verdicts('entry', rules.encodePuzzle(rules.decodePuzzle({'width': 3, 'height': 3, 'tiles': '040112000', 'gems': [7], 'start': 6, 'goal': 0, 'limit': 6})), [
      [1, 0, 0, 3],
      [1, 0, 3],
      [1, 0, 0, 3, 1, 3],
      [0, 1, 0, 0, 3],
      [0, 0, 0, 1, 0, 0, 3],
    ]),
  ];
}

// 过河问题：每种题型一道（固定种子从入门往上找），把参考解的某一步换成别的坐法，后面接着按最短走法走完（犯规的那一步也假装开得了再走完）：
// 判定漏查哪一条，这里就会判成解开、两端对不上。换法按 Dart 查出的问题（超载、不在这一岸、没人会划、各条规矩在哪一处、火把不够、合规）分类，
// 每类在整条参考解上按固定种子挑两个，免得只有一步可挑时漏掉「船上也算」这种少见的问题。
List<Map<String, Object?>> _riverCases(String game, RiverRules rules) {
  final random = PuzzleRandom(0x81BE);
  final cases = <Map<String, Object?>>[];
  // 大人与小孩另要一道船上也算的（只有它会出现「只在船上出事」）。
  for (final (variant, boat) in [for (final variant in RiverVariant.values) (variant, false), (RiverVariant.guardians, true)]) {
    final (tier, draw) = [
      for (final tier in PuzzleTier.values)
        for (var seed = 0; seed < 32; seed++) (tier, seed),
    ].map((item) => (item.$1, rules.generate(item.$2, item.$1))).firstWhere((item) => item.$2.puzzle.variant == variant && (variant != RiverVariant.guardians || item.$2.puzzle.boat == boat));
    final puzzle = draw.puzzle, reference = draw.solution;
    final buckets = <String, List<List<RiverCrossing>>>{};
    var left = puzzle.everyone, side = riverLeft, spent = 0;
    for (final (step, crossing) in reference.indexed) {
      for (var group = 1; group <= puzzle.everyone; group++) {
        if (riverBits(group) > puzzle.capacity + 1 || group == riverMask(crossing)) continue;
        // 分类看第一处问题，再看船上、留下的岸、到的岸各自有没有出事（只在船上出事的要单独有一类）。
        final violation = riverCheck(puzzle, left, side, group, spent: spent);
        final here = side == riverLeft ? left : puzzle.everyone & ~left;
        final places = [
          if (puzzle.boat && riverTrouble(puzzle, group, RiverPlace.boat) != null) 'boat',
          if (riverTrouble(puzzle, here & ~group, RiverPlace.left) != null) 'from',
          if (riverTrouble(puzzle, (puzzle.everyone & ~here) | group, RiverPlace.right) != null) 'to',
        ];
        final rest = riverSolve(puzzle, left: riverAfter(left, side, group), side: 1 - side);
        buckets.putIfAbsent('${violation?.fault}/${places.join('+')}', () => []).add([...reference.take(step), riverMembers(group), ...?rest]);
      }
      spent += riverCost(puzzle, riverMask(crossing));
      left = riverAfter(left, side, riverMask(crossing));
      side = 1 - side;
    }
    final answers = [
      rules.encodeAnswer(reference),
      for (final key in buckets.keys.toList()..sort())
        for (var pick = 0; pick < 2 && buckets[key]!.isNotEmpty; pick++) rules.encodeAnswer(buckets[key]!.removeAt(random.nextInt(buckets[key]!.length))),
    ];
    final encoded = rules.encodePuzzle(puzzle);
    cases.add({
      'tier': tier.name,
      'puzzle': encoded,
      'answers': [for (final answer in answers) {'answer': answer, 'expect': challengeVerdict(game, encoded, answer)}],
    });
  }
  return cases;
}

// 汉诺塔改目标的题（目标是全部叠到一根柱上，服务器按门上的数轮换柱子）：每种挪法各一道，参考解、按经典挪法的最短走法（相邻、循环下有不许的方向）、
// 少走最后一步各判一次，两端的方向规矩逐条对上。
List<Map<String, Object?>> _hanoiCases(PuzzleRules<Object?, Object?> rules) => [
  for (final puzzle in const [
    HanoiPuzzle(pegs: 3, variant: HanoiVariant.cyclic, start: [1, 0, 2, 0], goal: [1, 1, 1, 1]),
    HanoiPuzzle(pegs: 4, variant: HanoiVariant.adjacent, start: [3, 0, 2, 0], goal: [1, 1, 1, 1]),
    HanoiPuzzle(pegs: 4, variant: HanoiVariant.cyclic, start: [3, 0, 2, 1], goal: [2, 2, 2, 2]),
    HanoiPuzzle(pegs: 4, variant: HanoiVariant.classic, start: [0, 3, 0, 3], goal: [2, 2, 2, 2]),
  ])
    {
      'tier': PuzzleTier.normal.name,
      'puzzle': rules.encodePuzzle(puzzle),
      'answers': [
        for (final answer in [
          hanoiSolution(puzzle),
          hanoiSolution(HanoiPuzzle(pegs: puzzle.pegs, variant: HanoiVariant.classic, start: puzzle.start, goal: puzzle.goal)),
          hanoiSolution(puzzle).sublist(1),
        ])
          {'answer': rules.encodeAnswer(answer), 'expect': challengeVerdict('hanoi', rules.encodePuzzle(puzzle), rules.encodeAnswer(answer))},
      ],
    },
];

// [人工决策-2026-11-17 14:17:05] 汉诺塔高档放宽到最少步数的 1.2 倍以内（向下取整）：最少 60 步（上限正好 72）与最少 63 步（75.6 取 75）各一道，
// 参考解后面补挪最小盘的空步，走到上限的算过、多一步的不算。这几道带 minimum、答案带 passed，服务端按 judges.ts 的 withinStepLimit 核。
List<Map<String, Object?>> _hanoiLimitCases(PuzzleRules<Object?, Object?> rules) => [
  for (final puzzle in const [
    HanoiPuzzle(pegs: 3, variant: HanoiVariant.classic, start: [2, 2, 0, 0, 0, 0], goal: [2, 2, 2, 2, 2, 2]),
    HanoiPuzzle(pegs: 3, variant: HanoiVariant.classic, start: [0, 0, 0, 0, 0, 0], goal: [2, 2, 2, 2, 2, 2]),
  ])
    {
      'tier': PuzzleTier.hard.name,
      'puzzle': rules.encodePuzzle(puzzle),
      'minimum': hanoiMinMoves(puzzle),
      'answers': [
        for (final extra in [0, 1])
          for (final answer in [rules.encodeAnswer([...hanoiSolution(puzzle), ..._hanoiIdle(rules.stepLimit(hanoiMinMoves(puzzle)) - hanoiMinMoves(puzzle) + extra)])])
            {
              'answer': answer,
              'expect': challengeVerdict('hanoi', rules.encodePuzzle(puzzle), answer),
              'passed': challengePassed('hanoi', rules.encodePuzzle(puzzle), answer, hanoiMinMoves(puzzle)),
            },
      ],
    },
];

// 摆好之后来回挪最小的盘子（停在第 3 根柱上）凑够 extra 步，最后仍是目标局面：两步一来回，单数时最后绕一圈三步。
List<HanoiMove> _hanoiIdle(int extra) => [
  for (var pair = 0; pair < (extra.isOdd ? extra - 3 : extra) ~/ 2; pair++) ...[(from: 2, to: 0), (from: 0, to: 2)],
  if (extra.isOdd) ...[(from: 2, to: 0), (from: 0, to: 1), (from: 1, to: 2)],
];

// 要最少步数的关这份答案算不算过：解开且步数不超过这个游戏的上限（challengeStepLimit；服务端 judges.ts 的 withinStepLimit 同口径）。
// 步数按答案的项数算（汉诺塔一项一步），只给带 minimum 的向量用。
bool challengePassed(String game, Object? puzzleJson, Object? answerJson, int minimum) =>
    challengeVerdict(game, puzzleJson, answerJson)['kind'] == 'solved' && (answerJson! as List).length <= challengeStepLimit(game, minimum);

// 天平称球的题型在档内随机，上面每档两道不一定碰得到每种题型：每档每种题型（已知轻重的偏重、偏轻各一）再出一道，向量覆盖题库会有的全部题型。
// 另加「可能都是真的」的显式用例：按参考称法走到只剩都是真的时答都是真的算对、答成某个球或带了轻重算错；走到有假球时答都是真的算错；
// 题面不可能都是真的时答都是真的也算错。用自己的固定种子，不动上面已有的向量。
List<Map<String, Object?>> _balanceCases(String game) {
  if (game != 'balance') return const [];
  final rules = challengeRules[game]!;
  final random = PuzzleRandom(0xBA1A);
  Map<String, Object?> item(PuzzleTier tier, BalancePuzzle puzzle, List<Object?> extra) {
    final encoded = rules.encodePuzzle(puzzle), reference = rules.encodeAnswer(balanceSolve(puzzle)!);
    return {
      'tier': tier.name,
      'puzzle': encoded,
      'answers': [for (final answer in [reference, ..._mutations(reference, random), ...extra]) {'answer': answer, 'expect': challengeVerdict(game, encoded, answer)}],
    };
  }

  BalancePuzzle of(BalancePlan plan, BalanceWeight weight, int seed) =>
      BalancePuzzle(balls: plan.balls, weighings: plan.weighings, weight: weight, direction: plan.direction, standards: plan.standards, fakes: plan.fakes, maybeNone: plan.maybeNone, seed: seed);
  final cases = [
    for (final MapEntry(key: tier, value: plans) in BalanceRules.pools.entries)
      for (final plan in plans)
        for (final weight in plan.known ? [BalanceWeight.heavy, BalanceWeight.light] : [BalanceWeight.unknown]) item(tier, of(plan, weight, random.nextUint32()), const []),
  ];
  Object? weighingsOf(BalanceAnswer answer) => (rules.encodeAnswer(answer) as Map)['weighings'];
  for (final (tier, plan) in [
    for (final MapEntry(key: tier, value: plans) in BalanceRules.pools.entries)
      for (final plan in plans)
        if (plan.maybeNone) (tier, plan),
  ]) {
    // 各找一个参考解走到都是真的、走到有假球的种子（平局按种子答，走到哪一支跟着变；约每 40 道有一道走到都是真的，2000 道还没有就是规则坏了）。
    BalancePuzzle? none, fake;
    for (var seed = 0; none == null || fake == null; seed++) {
      if (seed == 2000) throw StateError('天平称球 $plan 的参考解走不到${none == null ? '都是真的' : '有假球'}');
      final puzzle = of(plan, BalanceWeight.unknown, PuzzleRandom(0xBA1B + seed).nextUint32());
      if (balanceSolve(puzzle)!.balls.isEmpty) {
        none ??= puzzle;
      } else {
        fake ??= puzzle;
      }
    }
    final allGenuine = balanceSolve(none)!, oneFake = balanceSolve(fake)!;
    cases
      ..add(item(tier, none, [
        {'weighings': weighingsOf(allGenuine), 'balls': [0], if (plan.direction) 'heavy': true},
        {'weighings': weighingsOf(allGenuine), 'balls': <int>[], 'heavy': true},
      ]))
      ..add(item(tier, fake, [
        {'weighings': weighingsOf(oneFake), 'balls': <int>[]},
      ]));
  }
  // 不可能都是真的题（普通档第一种题型）按参考称法称完答都是真的。
  final plain = of(BalanceRules.pools[PuzzleTier.normal]!.first, BalanceWeight.unknown, random.nextUint32());
  cases.add(item(PuzzleTier.normal, plain, [
    {'weighings': weighingsOf(balanceSolve(plain)!), 'balls': <int>[]},
  ]));
  return cases;
}

Future<void> main(List<String> arguments) async {
  String? option(String name) {
    final index = arguments.indexOf(name);
    return index >= 0 && index + 1 < arguments.length ? arguments[index + 1] : null;
  }

  if (option('--freeze') case final game?) {
    final current = jsonDecode(await File(challengeVectorsPath).readAsString()) as Map<String, Object?>;
    final version = (current['puzzleVersions'] as Map)[game], cases = (current['games'] as Map)[game];
    if (version == null || cases == null) throw ArgumentError('向量里没有 $game');
    final frozenFile = File(challengeFrozenPath);
    final games = Map<String, Object?>.from((jsonDecode(await frozenFile.readAsString()) as Map)['games'] as Map);
    final token = '$game@$version';
    if (games.containsKey(token)) throw StateError('$token 已经冻结过');
    games[token] = cases;
    await frozenFile.writeAsString('${jsonEncode({'version': 1, 'games': games})}\n');
    stdout.writeln('已把 $token 的向量冻结到 $challengeFrozenPath');
    return;
  }
  final out = option('--out') ?? challengeVectorsPath;
  final vectors = buildChallengeVectors(seedsPerTier: int.parse(option('--seeds') ?? '2'), seed: int.parse(option('--seed') ?? '${0x5EED2026}'));
  await File(out).writeAsString('${jsonEncode(vectors)}\n');
  stdout.writeln('已写入 $out');
}
