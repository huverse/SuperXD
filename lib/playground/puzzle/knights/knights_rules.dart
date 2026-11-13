import 'package:superxd/playground/puzzle_rules.dart';

// 骑士与无赖：岛上的骑士永远说真话，无赖永远说假话。每个人各说一句话，推出谁是骑士、谁是无赖。
// 一组身份「成立」= 每句话的真假都和说话人的身份一致（骑士的话为真、无赖的话为假）；出的题恰好只有一组身份成立，
// 人数最多 6 个，全部 2^6 = 64 组直接枚举。题面只存每句话的结构（句式加参数），文字在对局页按结构生成。

// 句式：code 写进题面编码，发出后不改（加句式只往后加新 code）；arity 是参数个数。
enum KnightsClaimKind {
  // 「X 是骑士。」「X 是无赖。」X 不是说话人自己：「我是骑士」谁都能说、没有信息，「我是无赖」谁都说不出口。
  knight(0, 1),
  knave(1, 1),
  // 「我和 X 是同一类人。」「我和 X 不是同一类人。」
  same(2, 1),
  different(3, 1),
  // 「我们 N 个人里恰好 / 至少 / 最多有 k 个骑士。」计数包括说话人自己。
  exactly(4, 1),
  atLeast(5, 1),
  atMost(6, 1),
  // 「如果 X 是骑士，那么 Y 是无赖。」「X 和 Y 至少有一个是无赖。」X、Y 可以是说话人自己（页面说成「我」）。
  // 两种说法逻辑上等价（都是「X、Y 不全是骑士」），换个说法出现，看不看得出来是推理的一部分。
  implies(7, 2),
  eitherKnave(8, 2),
  // 转述：「X 会说 Y 是无赖。」X 不是说话人，Y 可以是说话人自己。
  wouldSay(9, 2);

  const KnightsClaimKind(this.code, this.arity);
  final int code;
  final int arity;

  static KnightsClaimKind? coded(int code) => values.where((kind) => kind.code == code).firstOrNull;
}

// 一句话：句式加参数。first 是第一个人的下标（0 起，页面依次叫甲乙丙丁戊己）或计数 k，second 是第二个人（只有两个参数的句式用）。
class KnightsClaim {
  const KnightsClaim(this.kind, this.first, [this.second = -1]);
  final KnightsClaimKind kind;
  final int first, second;
}

// 题面：claims[i] 是第 i 个人说的话，每人恰好一句，人数就是句数。
class KnightsPuzzle {
  const KnightsPuzzle(this.claims);
  final List<KnightsClaim> claims;
  int get people => claims.length;
}

// 人数上下限（外部输入的边界）：名字只有甲到己六个，枚举身份用 64 位整数的位集（2^6 = 64 组正好一个整数），
// 所以求解器只在 Dart 里跑（题库工具与本机）；服务器只核对答案，按句判真假即可，用不到它。
const knightsMinPeople = 2;
const knightsMaxPeople = 6;

int _bits(int value) {
  var count = 0;
  for (var rest = value; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

bool _isKnight(int knights, int person) => knights >> person & 1 == 1;

// 这句话放在第 speaker 个人嘴里、共 people 个人时是否合法：出题枚举与解码共用这一处。
bool knightsClaimLegal(KnightsClaim claim, int speaker, int people) {
  bool person(int index) => index >= 0 && index < people;
  final (first, second) = (claim.first, claim.second);
  return switch (claim.kind) {
    KnightsClaimKind.knight || KnightsClaimKind.knave || KnightsClaimKind.same || KnightsClaimKind.different => person(first) && first != speaker,
    KnightsClaimKind.exactly => first >= 0 && first <= people,
    // 「至少 0 个」「最多 N 个」永远为真；「至少 N 个」「最多 0 个」同「恰好」，都不收。
    KnightsClaimKind.atLeast || KnightsClaimKind.atMost => first >= 1 && first <= people - 1,
    KnightsClaimKind.implies => person(first) && person(second) && first != second,
    // 「X 和 Y」不分先后，只收小的在前的一种写法。
    KnightsClaimKind.eitherKnave => person(first) && person(second) && first < second,
    KnightsClaimKind.wouldSay => person(first) && person(second) && first != speaker && first != second,
  };
}

// 第 speaker 个人说的这句话，在身份组合 knights（第 i 位是 1 表示第 i 个人是骑士）下是不是真话。
bool knightsTruth(KnightsClaim claim, int speaker, int knights) {
  final (first, second) = (claim.first, claim.second);
  return switch (claim.kind) {
    KnightsClaimKind.knight => _isKnight(knights, first),
    KnightsClaimKind.knave => !_isKnight(knights, first),
    KnightsClaimKind.same => _isKnight(knights, speaker) == _isKnight(knights, first),
    KnightsClaimKind.different => _isKnight(knights, speaker) != _isKnight(knights, first),
    KnightsClaimKind.exactly => _bits(knights) == first,
    KnightsClaimKind.atLeast => _bits(knights) >= first,
    KnightsClaimKind.atMost => _bits(knights) <= first,
    KnightsClaimKind.implies || KnightsClaimKind.eitherKnave => !_isKnight(knights, first) || !_isKnight(knights, second),
    // X 会说「Y 是无赖」：X 是骑士时这话为真即 Y 是无赖，X 是无赖时这话为假即 Y 是骑士，合起来就是 X、Y 不同类。
    KnightsClaimKind.wouldSay => _isKnight(knights, first) != _isKnight(knights, second),
  };
}

// 和身份对不上的人：他那句话的真假与他的身份不一致（骑士说了假话、无赖说了真话）。对局页判错时只标这些人，不给答案。
List<int> knightsMismatches(KnightsPuzzle puzzle, int knights) => [
  for (final (speaker, claim) in puzzle.claims.indexed)
    if (knightsTruth(claim, speaker, knights) != _isKnight(knights, speaker)) speaker,
];

// 成立的身份组合（从小到大）：每句话的真假都和说话人的身份一致。
List<int> knightsSolutions(KnightsPuzzle puzzle) => [
  for (var knights = 0; knights < 1 << puzzle.people; knights++)
    if (knightsMismatches(puzzle, knights).isEmpty) knights,
];

// 推理过程：模拟人一步步推。
// - 单句：拿一句话，加上已经定下的人，看能不能定下谁（「丙说我和丁是同一类人」→ 丁是骑士；已知丁是骑士、丁说甲是无赖 → 甲是无赖），推到推不动为止。
// - 联合：单句推不动了，就同时看两句（还不行看三句……），哪组话合起来能定下谁就先定下，再回到单句接着推。
// direct：一开始什么都不知道时，单凭一句话就能定下的人数；single：只靠单句一路推能定下的人数（剩下的要联合）；
// depth：整个过程里最多要同时看几句（全靠单句推完是 1）；joined：每个靠联合定下的人记「联合的句数 − 1」，加起来。
typedef KnightsReasoning = ({int direct, int single, int depth, int joined});

KnightsReasoning knightsReasoning(KnightsPuzzle puzzle) {
  final people = puzzle.people, size = 1 << people, everyone = (1 << people) - 1;
  // 身份组合的集合用一个整数的位集表示：第 a 位是 1 表示组合 a 在集合里（最多 64 组）。
  final all = -1 >>> (64 - size);
  int setOf(bool Function(int knights) test) {
    var set = 0;
    for (var knights = 0; knights < size; knights++) {
      if (test(knights)) set |= 1 << knights;
    }
    return set;
  }

  final knightSets = [for (var person = 0; person < people; person++) setOf((knights) => _isKnight(knights, person))];
  // 每句话单独成立的组合，与每组话（按位选哪几句）同时成立的组合。
  final claimSets = [for (final (speaker, claim) in puzzle.claims.indexed) setOf((knights) => knightsTruth(claim, speaker, knights) == _isKnight(knights, speaker))];
  final groups = List.filled(size, all);
  for (var group = 1; group < size; group++) {
    final lowest = group & -group;
    groups[group] = groups[group ^ lowest] & claimSets[lowest.bitLength - 1];
  }
  // candidates 里还没定下的人，在所有组合里身份都一样的，就是能定下的人。
  int forced(int candidates, int settled) {
    var found = 0;
    for (var person = 0; person < people; person++) {
      if (candidates == 0 || settled >> person & 1 == 1) continue;
      final asKnight = candidates & knightSets[person];
      if (asKnight == candidates || asKnight == 0) found |= 1 << person;
    }
    return found;
  }

  final direct = _bits(claimSets.fold(0, (found, set) => found | forced(set, 0)));
  var known = all, settled = 0, depth = 1, joined = 0, single = -1;
  // 把 candidates 定下的人并入已知：已知的组合只留下这些人身份与 candidates 一致的。
  int settle(int candidates) {
    final found = forced(candidates, settled);
    for (var person = 0; person < people; person++) {
      if (found >> person & 1 == 1) known &= candidates & knightSets[person] == 0 ? all & ~knightSets[person] : knightSets[person];
    }
    settled |= found;
    return found;
  }

  search:
  while (settled != everyone) {
    for (var width = 1; width <= people; width++) {
      var found = 0;
      for (var group = 1; group < size; group++) {
        if (_bits(group) != width) continue;
        // 定下的人当即并入已知：同一轮单句里后面的句子接着用；联合的定下一批就回到单句。
        found |= settle(known & groups[group]);
        if (found != 0 && width > 1) break;
      }
      if (found == 0) continue;
      if (width > 1) {
        if (single < 0) single = _bits(settled & ~found);
        joined += (width - 1) * _bits(found);
        if (width > depth) depth = width;
      }
      continue search;
    }
    // 全部话合起来也定不下：不是唯一解的题（出题与解码都会拦下，这里只是兜底）。
    break;
  }
  return (direct: direct, single: single < 0 ? _bits(settled) : single, depth: depth, joined: joined);
}

// 每档的出题方案：人数、各句式的抽取权重（整数，换语言能逐位复现）与对推理过程的要求（量法见 knightsReasoning）。
class _Plan {
  const _Plan({
    required this.people,
    required this.weights,
    this.fresh = const {},
    this.minFresh = 0,
    required this.maxDirect,
    this.depth = (1, 1),
    this.joined = (0, 0),
  });
  final int people;
  final Map<KnightsClaimKind, int> weights;
  // 这一档新加的句式至少出现 minFresh 句（档与档读起来不一样）。
  final Set<KnightsClaimKind> fresh;
  final int minFresh;
  // 一开始单凭一句话就能定下的人最多几个：档越高越少，专家档一个都没有，得从几句话的关系里找突破口。
  final int maxDirect;
  // 最多同时看几句与联合推理量的区间：下限保证高档非联合推不出来，上限免得同档里冒出要把全部话放在一起试的题。
  final (int, int) depth, joined;
}

class KnightsRules extends PuzzleRules<KnightsPuzzle, List<bool>> {
  const KnightsRules();

  // 「X 是骑士 / 无赖」多一些：「我和 X 同类 / 不同类」单句就能定下 X，多了就没有推的过程。
  static const _basic = {KnightsClaimKind.knight: 3, KnightsClaimKind.knave: 3, KnightsClaimKind.same: 2, KnightsClaimKind.different: 2};
  static const _counted = {..._basic, KnightsClaimKind.exactly: 2, KnightsClaimKind.atLeast: 2, KnightsClaimKind.atMost: 2};
  static const _all = {..._counted, KnightsClaimKind.implies: 3, KnightsClaimKind.eitherKnave: 3, KnightsClaimKind.wouldSay: 3};
  static const _counts = {KnightsClaimKind.exactly, KnightsClaimKind.atLeast, KnightsClaimKind.atMost};
  static const _logic = {KnightsClaimKind.implies, KnightsClaimKind.eitherKnave, KnightsClaimKind.wouldSay};

  // 入门、简单只有「是骑士 / 无赖」「同类 / 不同类」，这两种句子靠单句一路推就能全部定下（实测每道都是），只要求开头只有一个人能直接定；
  // 普通加计数句，最多联合两句、最多两个人要联合；困难加条件与转述，必须有人要联合两句才定得下；专家没有一句话能直接定下谁，最多联合三句。
  static const _plans = {
    PuzzleTier.entry: _Plan(people: 2, weights: _basic, maxDirect: 1),
    PuzzleTier.easy: _Plan(people: 3, weights: _basic, maxDirect: 1),
    PuzzleTier.normal: _Plan(people: 4, weights: _counted, fresh: _counts, minFresh: 1, maxDirect: 1, depth: (1, 2), joined: (0, 2)),
    PuzzleTier.hard: _Plan(people: 5, weights: _all, fresh: _logic, minFresh: 1, maxDirect: 1, depth: (2, 2), joined: (1, 4)),
    PuzzleTier.expert: _Plan(people: 6, weights: _all, fresh: _logic, minFresh: 2, maxDirect: 0, depth: (2, 3), joined: (2, 6)),
  };

  // 出题：先随机定下每个人的身份，再给每人挑一句和身份一致的话（骑士说真话、无赖说假话：先按权重挑句式，再在这一句式里挑一句）；
  // 枚举全部身份组合，恰好只有这一组成立、并且推理过程满足这一档的要求才用，否则整组重来。
  @override
  PuzzleDraw<KnightsPuzzle, List<bool>> generate(int seed, PuzzleTier tier) {
    final plan = _plans[tier]!;
    final people = plan.people, size = 1 << people;
    final random = PuzzleRandom(seed);
    // 每个人能说的全部合法句子，连同「这句话和说话人身份一致」的身份组合集合（与身份无关，先算好）。
    // 单凭这一句就能定下的人已经超过这一档允许的（如「如果我是骑士，那么戊是无赖」一句定下两个人），不放进候选，免得整组白出。
    final options = [
      for (var speaker = 0; speaker < people; speaker++)
        [
          for (final kind in plan.weights.keys)
            for (var first = 0; first <= people; first++)
              for (var second = kind.arity == 2 ? 0 : -1; second < (kind.arity == 2 ? people : 0); second++)
                if (KnightsClaim(kind, first, second) case final claim when knightsClaimLegal(claim, speaker, people))
                  if (_consistentSet(claim, speaker, size) case final set when _settledBy(set, people) <= plan.maxDirect) (claim, set),
        ],
    ];
    while (true) {
      final knights = random.nextInt(size);
      final claims = <KnightsClaim>[];
      var survivors = -1;
      for (var speaker = 0; speaker < people; speaker++) {
        final fitting = [for (final (claim, set) in options[speaker]) if (set >> knights & 1 == 1) (claim, set)];
        final kinds = [for (final kind in plan.weights.keys) if (fitting.any((option) => option.$1.kind == kind)) kind];
        var roll = random.nextInt(kinds.fold(0, (total, kind) => total + plan.weights[kind]!));
        final kind = kinds.firstWhere((kind) => (roll -= plan.weights[kind]!) < 0);
        final (claim, set) = random.pick([for (final option in fitting) if (option.$1.kind == kind) option]);
        claims.add(claim);
        survivors &= set;
      }
      if (_bits(survivors) != 1) continue;
      if (claims.where((claim) => plan.fresh.contains(claim.kind)).length < plan.minFresh) continue;
      final puzzle = KnightsPuzzle(List.unmodifiable(claims));
      final reasoning = knightsReasoning(puzzle);
      final ((minDepth, maxDepth), (minJoined, maxJoined)) = (plan.depth, plan.joined);
      if (reasoning.direct > plan.maxDirect || reasoning.depth < minDepth || reasoning.depth > maxDepth || reasoning.joined < minJoined || reasoning.joined > maxJoined) continue;
      return PuzzleDraw(puzzle, List.unmodifiable([for (var person = 0; person < people; person++) _isKnight(knights, person)]));
    }
  }

  static int _consistentSet(KnightsClaim claim, int speaker, int size) {
    var set = 0;
    for (var knights = 0; knights < size; knights++) {
      if (knightsTruth(claim, speaker, knights) == _isKnight(knights, speaker)) set |= 1 << knights;
    }
    return set;
  }

  // 在身份组合集合 set 里身份都一样（即单凭这一句就定下）的人数。
  static int _settledBy(int set, int people) {
    var count = 0;
    for (var person = 0; person < people; person++) {
      var asKnight = 0;
      for (var knights = 0; knights < 1 << people; knights++) {
        if (set >> knights & 1 == 1 && _isKnight(knights, person)) asKnight++;
      }
      if (asKnight == 0 || asKnight == _bits(set)) count++;
    }
    return count;
  }

  // 按规则判：每句话的真假都和答案里说话人的身份一致。题目保证唯一，所以等价于答对，但不和参考解比。
  @override
  bool solved(KnightsPuzzle puzzle, List<bool> answer) {
    if (answer.length != puzzle.people) return false;
    final knights = answer.indexed.fold(0, (mask, entry) => entry.$2 ? mask | 1 << entry.$1 : mask);
    return knightsMismatches(puzzle, knights).isEmpty;
  }

  // 难度分口径：以人数为主，基础分 2 × 人数 − 3（2 人 1 分、3 人 3、4 人 5、5 人 7、6 人 9）；再看推理深度（knightsReasoning）：
  // 只靠单句一路推就能全部定下的不加分，剩下要联合几句才定得下的人，每人记「联合的句数 − 1」作推理量，推理量达到人数的一半再加 1 分。
  // 所以同档的题最多差 1 分、下一档最低分高过上一档最高分：入门 1、简单 3（这两档的句式单句就能推完）、普通 5–6、困难 7–8、专家 9–10。
  // 不是唯一解的题面不会出、也解码不进来，按 10 分算。
  @override
  int difficulty(KnightsPuzzle puzzle) {
    if (knightsSolutions(puzzle).length != 1) return 10;
    final reasoning = knightsReasoning(puzzle);
    return (2 * puzzle.people - 3 + (2 * reasoning.joined >= puzzle.people ? 1 : 0)).clamp(1, 10);
  }

  // 题面编成 {'claims': [[句式 code, 参数…], …]}，第 i 项是第 i 个人说的话。
  @override
  Object encodePuzzle(KnightsPuzzle puzzle) => {
    'claims': [
      for (final claim in puzzle.claims) [claim.kind.code, claim.first, if (claim.kind.arity == 2) claim.second],
    ],
  };

  @override
  KnightsPuzzle decodePuzzle(Object? json) {
    final claims = json is Map ? json['claims'] : null;
    if (claims is! List || claims.length < knightsMinPeople || claims.length > knightsMaxPeople) throw const FormatException('人数不合法');
    final people = claims.length;
    final puzzle = KnightsPuzzle(List.unmodifiable([
      for (final (speaker, raw) in claims.indexed) _decodeClaim(raw, speaker, people),
    ]));
    // 没有一组身份成立、或不止一组成立的不是题（题库里不该有）。
    if (knightsSolutions(puzzle).length != 1) throw const FormatException('题目不是唯一解');
    return puzzle;
  }

  static KnightsClaim _decodeClaim(Object? raw, int speaker, int people) {
    // 句式 code 与参数共用一个宽松上限：code 有大于人数上限的（条件、转述是 7–9），code 由 coded 认，参数范围由 knightsClaimLegal 核。
    final parts = puzzleInts(raw, maxLength: 3, min: 0, max: 15);
    final kind = parts.isEmpty ? null : KnightsClaimKind.coded(parts.first);
    if (kind == null || parts.length != 1 + kind.arity) throw const FormatException('句式不合法');
    final claim = KnightsClaim(kind, parts[1], kind.arity == 2 ? parts[2] : -1);
    if (!knightsClaimLegal(claim, speaker, people)) throw const FormatException('句子的参数不合法');
    return claim;
  }

  // 答案是每人一位的 0、1 串（1 是骑士）。
  @override
  Object encodeAnswer(List<bool> answer) => answer.map((knight) => knight ? '1' : '0').join();

  @override
  List<bool> decodeAnswer(Object? json) {
    if (json is! String || json.length < knightsMinPeople || json.length > knightsMaxPeople || !RegExp(r'^[01]+$').hasMatch(json)) throw const FormatException('答案不合法');
    return List.unmodifiable([for (final char in json.split('')) char == '1']);
  }
}
