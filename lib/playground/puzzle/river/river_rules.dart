import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 过河问题：一条河、两岸、一条船，把所有人和物从左岸送到右岸。船上至少一人、不超过船的容量，船上要有会划船的人才能开。
// 三种题型，规矩不同：
// - 农夫过河：农夫、狼、羊、白菜。只有农夫会划船，船上除农夫外最多带一样；没人看着时狼会吃羊、羊会吃白菜（原典的童话说法）。
// - 大人与小孩：人人会划船。哪边岸上有大人，小孩就不能比大人多（管不过来）；船上不单独判，靠岸后连船上的人一起算。
// - 父子：人人会划船。孩子的爸爸不在场时，不能和别人家的爸爸待在一起，岸上和船上都算。
// 判定在开船那一刻：留在出发岸的人、船上的人（只有父子题判）、靠岸后的对岸（连船上的人）都合规才开得了。
// 船靠岸后，船上的人算在那一岸（对局页里他们可以留在船上，下一趟接着坐），所以状态就是「左岸有谁、船在哪岸」。
enum RiverVariant { farmer, guardians, families }

enum RiverRole { farmer, wolf, goat, cabbage, adult, kid, father, son }

// 一个人（或一样东西）：身份，父子还带是哪一家（名字池 riverFamilyNames 的下标，其余是 -1）。
typedef RiverPerson = ({RiverRole role, int family});

// 父子的合成称呼「大明 / 小明」：名字池的下标就是家的编号，页面按它配色。发出后只能在末尾追加（题面按下标存）。
const riverFamilyNames = ['明', '华', '刚', '伟', '亮', '军'];

const riverLeft = 0, riverRight = 1;
const riverMaxPeople = 10;
const riverMinCapacity = 2;
const riverMaxCapacity = 4;
// 一局最多记这么多次渡河（外部输入的上限；最难一档最少 11 次，留足走弯路的余地）。
const riverMaxCrossings = 1024;

class RiverPuzzle {
  const RiverPuzzle({required this.variant, required this.capacity, required this.people});
  final RiverVariant variant;
  final int capacity;
  // 顺序就是答案里的下标；岸上的站位按身份排（见对局页）。
  final List<RiverPerson> people;

  int get count => people.length;
  int get everyone => (1 << people.length) - 1;
}

// 一次渡河运的是哪些人：下标升序。
typedef RiverCrossing = List<int>;

String riverName(RiverPerson person) => switch (person.role) {
  RiverRole.farmer => '农夫',
  RiverRole.wolf => '狼',
  RiverRole.goat => '羊',
  RiverRole.cabbage => '白菜',
  RiverRole.adult => '大人',
  RiverRole.kid => '小孩',
  RiverRole.father => '大${riverFamilyNames[person.family]}',
  RiverRole.son => '小${riverFamilyNames[person.family]}',
};

// 只有农夫过河里有不会划船的（狼、羊、白菜）。
bool riverRows(RiverPerson person) => switch (person.role) {
  RiverRole.wolf || RiverRole.goat || RiverRole.cabbage => false,
  _ => true,
};

// 开船查出的问题：哪一种、在哪里、牵涉谁（下标）。页面按它写提示、把牵涉的人标出来。
enum RiverFault { empty, crowded, absent, noRower, eaten, outnumbered, unguarded }

enum RiverPlace { left, right, boat }

class RiverViolation {
  const RiverViolation(this.fault, {this.place, this.people = const []});
  final RiverFault fault;
  final RiverPlace? place;
  // eaten：[吃的, 被吃的]；outnumbered：那一处的小孩；unguarded：[孩子, 别人家的爸爸]。
  final List<int> people;
}

int riverBits(int mask) {
  var count = 0;
  for (var rest = mask; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

List<int> riverMembers(int mask) => [for (var index = 0; mask >> index != 0; index++) if (mask & (1 << index) != 0) index];

int riverMask(Iterable<int> members) => members.fold(0, (mask, index) => mask | (1 << index));

// 一群人待在一处（岸上或船上）有没有问题，没有返回 null。
RiverViolation? riverTrouble(RiverPuzzle puzzle, int group, RiverPlace place) {
  final people = puzzle.people;
  int? first(RiverRole role) {
    for (var index = 0; index < people.length; index++) {
      if (group & (1 << index) != 0 && people[index].role == role) return index;
    }
    return null;
  }

  switch (puzzle.variant) {
    case RiverVariant.farmer:
      if (first(RiverRole.farmer) != null) return null;
      final wolf = first(RiverRole.wolf), goat = first(RiverRole.goat), cabbage = first(RiverRole.cabbage);
      if (wolf != null && goat != null) return RiverViolation(RiverFault.eaten, place: place, people: [wolf, goat]);
      if (goat != null && cabbage != null) return RiverViolation(RiverFault.eaten, place: place, people: [goat, cabbage]);
      return null;
    case RiverVariant.guardians:
      final members = riverMembers(group);
      final kids = [for (final index in members) if (people[index].role == RiverRole.kid) index];
      final adults = members.length - kids.length;
      return adults > 0 && kids.length > adults ? RiverViolation(RiverFault.outnumbered, place: place, people: kids) : null;
    case RiverVariant.families:
      final members = riverMembers(group);
      final fathers = {for (final index in members) if (people[index].role == RiverRole.father) people[index].family: index};
      for (final index in members) {
        final person = people[index];
        if (person.role != RiverRole.son || fathers.containsKey(person.family)) continue;
        if (fathers.values.firstOrNull case final other?) return RiverViolation(RiverFault.unguarded, place: place, people: [index, other]);
      }
      return null;
  }
}

// 开船前的检查：left 是左岸（含停在左岸的船上）的人，side 是船在哪岸，group 是船上的人。按「船上 → 留下的岸 → 对岸」的顺序报第一处问题。
RiverViolation? riverCheck(RiverPuzzle puzzle, int left, int side, int group) {
  final here = side == riverLeft ? left : puzzle.everyone & ~left;
  if (group == 0) return const RiverViolation(RiverFault.empty);
  if (riverBits(group) > puzzle.capacity) return const RiverViolation(RiverFault.crowded);
  if (group & ~here != 0) return const RiverViolation(RiverFault.absent);
  if (!riverMembers(group).any((index) => riverRows(puzzle.people[index]))) return const RiverViolation(RiverFault.noRower);
  final from = side == riverLeft ? RiverPlace.left : RiverPlace.right, to = side == riverLeft ? RiverPlace.right : RiverPlace.left;
  return (puzzle.variant == RiverVariant.families ? riverTrouble(puzzle, group, RiverPlace.boat) : null) ??
      riverTrouble(puzzle, here & ~group, from) ??
      riverTrouble(puzzle, (puzzle.everyone & ~here) | group, to);
}

// 渡一次河之后左岸有谁。
int riverAfter(int left, int side, int group) => side == riverLeft ? left & ~group : left | group;

// 按次重放：每次都合规才往下走，返回最后左岸有谁与船在哪岸；有一次不合规返回 null。
({int left, int side})? riverReplay(RiverPuzzle puzzle, Iterable<RiverCrossing> crossings) {
  var left = puzzle.everyone, side = riverLeft;
  for (final crossing in crossings) {
    if (crossing.any((index) => index < 0 || index >= puzzle.count)) return null;
    final group = riverMask(crossing);
    if (riverBits(group) != crossing.length || riverCheck(puzzle, left, side, group) != null) return null;
    left = riverAfter(left, side, group);
    side = 1 - side;
  }
  return (left: left, side: side);
}

// 求解用的表：每群人能不能单独待一处、哪些人会划船、船上能坐的每一种组合（按掩码升序，结果只由题面决定）。
// 状态编成「左岸掩码 × 2 + 船在哪岸」，10 个人一共 2048 个，每个状态最多试 C(10,1)+C(10,2)+C(10,3) = 175 种坐法。
class _RiverGraph {
  _RiverGraph(this.puzzle)
    : calm = [for (var mask = 0; mask <= puzzle.everyone; mask++) riverTrouble(puzzle, mask, RiverPlace.left) == null],
      rowers = riverMask([for (var index = 0; index < puzzle.count; index++) if (riverRows(puzzle.people[index])) index]),
      kids = riverMask([for (var index = 0; index < puzzle.count; index++) if (puzzle.people[index].role == RiverRole.kid) index]),
      groups = [for (var mask = 1; mask <= puzzle.everyone; mask++) if (riverBits(mask) <= puzzle.capacity) mask];

  final RiverPuzzle puzzle;
  final List<bool> calm;
  final int rowers, kids;
  final List<int> groups;

  static final _cache = Expando<_RiverGraph>();
  static _RiverGraph of(RiverPuzzle puzzle) => _cache[puzzle] ??= _RiverGraph(puzzle);

  int get start => puzzle.everyone * 2 + riverLeft;
  static const goal = riverRight;

  // 从 state 渡 group 过河之后的状态，不合规返回 null（同 riverCheck，用查表）。
  int? cross(int state, int group) {
    final left = state >> 1, side = state & 1;
    final here = side == riverLeft ? left : puzzle.everyone & ~left;
    if (group & ~here != 0 || group & rowers == 0) return null;
    if (puzzle.variant == RiverVariant.families && !calm[group]) return null;
    final next = riverAfter(left, side, group);
    if (!calm[next] || !calm[puzzle.everyone & ~next]) return null;
    return next * 2 + 1 - side;
  }

  // 广度优先：从 origin 出发每个状态最少几次（到不了是 -1），顺带记从哪来、运了谁。
  ({List<int> steps, List<int> previous, List<int> carried}) search(int origin) {
    final size = (puzzle.everyone + 1) * 2;
    final steps = List.filled(size, -1), previous = List.filled(size, -1), carried = List.filled(size, 0);
    final queue = [origin];
    steps[origin] = 0;
    for (var head = 0; head < queue.length; head++) {
      final state = queue[head];
      for (final group in groups) {
        final next = cross(state, group);
        if (next == null || steps[next] >= 0) continue;
        steps[next] = steps[state] + 1;
        previous[next] = state;
        carried[next] = group;
        queue.add(next);
      }
    }
    return (steps: steps, previous: previous, carried: carried);
  }

  // 一样的人（大人与小孩题里的大人、小孩）互换算同一个局面：按「左岸几个大人、几个小孩」归一，其余题每个人都不一样。
  int canonical(int state) {
    if (puzzle.variant != RiverVariant.guardians) return state;
    final left = state >> 1, onLeft = riverBits(left & kids);
    return ((riverBits(left) - onLeft) * 16 + onLeft) * 2 + (state & 1);
  }
}

// 最少渡河次数的一份走法；解不开返回 null。
List<RiverCrossing>? riverSolve(RiverPuzzle puzzle) {
  final graph = _RiverGraph.of(puzzle);
  final search = graph.search(graph.start);
  if (search.steps[_RiverGraph.goal] < 0) return null;
  final crossings = <RiverCrossing>[];
  for (var state = _RiverGraph.goal; state != graph.start; state = search.previous[state]) {
    crossings.add(riverMembers(search.carried[state]));
  }
  return crossings.reversed.toList();
}

// 推理深度的两项：
// - bits：沿最短走法，每一步在「合规的走法」里挑中「还在最短路上的走法」要的信息量 log2(合规数 / 最优数) 之和，
//   有几条最短路时按均匀挑最优走法取期望。步数越多、每步能走的越多而对的越少，越高；走法按局面归一（两个大人互换算一种）。
// - states：从开局走得到的局面有多少种（归一后），是要在脑子里排除的范围。
({double bits, int states}) riverDepth(RiverPuzzle puzzle) {
  final graph = _RiverGraph.of(puzzle);
  final toGoal = graph.search(_RiverGraph.goal).steps;
  final reached = graph.search(graph.start).steps;
  final states = {for (var state = 0; state < reached.length; state++) if (reached[state] >= 0) graph.canonical(state)}.length;
  final memo = <int, double>{};
  double expect(int state) {
    if (state == _RiverGraph.goal) return 0;
    if (memo[state] case final value?) return value;
    final seen = <int>{}, best = <int>[];
    for (final group in graph.groups) {
      final next = graph.cross(state, group);
      if (next == null || !seen.add(graph.canonical(next))) continue;
      if (toGoal[next] == toGoal[state] - 1) best.add(next);
    }
    final value = math.log(seen.length / best.length) / math.ln2 + best.map(expect).reduce((sum, value) => sum + value) / best.length;
    return memo[state] = value;
  }

  return (bits: expect(graph.start), states: states);
}

// 难度分 1–10：bits × 0.55 + log2(states) × 0.7 − 3.7，取整夹在 1–10（bits 已经按步数累加，步数多、每步岔路多都会抬高它）。
// 实测（每档的题型只差名字与站位，所以同档的分几乎一样）：
// 农夫过河 7 次、6.2 比特、10 种局面 → 2；三大人两小孩船 2 人 7 次、8.1 比特 → 4；三大人三小孩 11 次、10.8 比特 → 5；
// 三对父子船 2 人 11 次、11.4 比特、40 种局面 → 6；五大人五小孩船 3 人 11 次、13.4 比特 → 7；五对父子船 3 人 11 次、14.1 比特、184 种局面 → 9。
int riverDifficulty(RiverPuzzle puzzle) {
  final depth = riverDepth(puzzle);
  return (depth.bits * .55 + math.log(depth.states) / math.ln2 * .7 - 3.7).round().clamp(1, 10);
}

class RiverRules extends PuzzleRules<RiverPuzzle, List<RiverCrossing>> {
  const RiverRules();

  // 每档最少渡河次数的区间（含两端，实测）：入门 7；简单 7–11；普通、困难、专家都是 11。档与档单调不降，难度分逐档上升（见 riverDifficulty）。
  // 困难与专家原定四大人四小孩、四对父子（船都是 3 人），实测最少只要 9 次、推理量也比简单、普通小（9.2、10.2 比特），
  // 档位会倒挂，所以各加一对：五大人五小孩、五对父子，最少 11 次、推理量明显更大。
  static const _least = {PuzzleTier.entry: (7, 7), PuzzleTier.easy: (7, 11), PuzzleTier.normal: (11, 11), PuzzleTier.hard: (11, 11), PuzzleTier.expert: (11, 11)};

  // 出题：按档定题型，种子只在参数上做小变化——农夫过河换狼、羊、白菜的站位，简单档的小孩两个或三个，父子换哪几家（名字与配色）和先后；
  // 出题前用求解器确认可解、最少次数落在这一档的区间里，不在就换一组（每档的几种变化都实测过，第一组就能用）。
  @override
  PuzzleDraw<RiverPuzzle, List<RiverCrossing>> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final (least, most) = _least[tier]!;
    for (var attempt = 0; attempt < 16; attempt++) {
      final puzzle = _cast(random, tier);
      final solution = riverSolve(puzzle);
      if (solution != null && solution.length >= least && solution.length <= most) return PuzzleDraw(puzzle, solution);
    }
    throw StateError('过河问题 ${tier.name} 档出不了题');
  }

  static RiverPuzzle _cast(PuzzleRandom random, PuzzleTier tier) {
    List<RiverPerson> crowd(int adults, int kids) => [
      for (var index = 0; index < adults; index++) (role: RiverRole.adult, family: -1),
      for (var index = 0; index < kids; index++) (role: RiverRole.kid, family: -1),
    ];
    List<RiverPerson> families(int count) {
      final names = [for (var index = 0; index < riverFamilyNames.length; index++) index];
      random.shuffle(names);
      return [
        for (final family in names.take(count)) ...[(role: RiverRole.father, family: family), (role: RiverRole.son, family: family)],
      ];
    }

    switch (tier) {
      case PuzzleTier.entry:
        final items = <RiverPerson>[(role: RiverRole.wolf, family: -1), (role: RiverRole.goat, family: -1), (role: RiverRole.cabbage, family: -1)];
        random.shuffle(items);
        return RiverPuzzle(variant: RiverVariant.farmer, capacity: 2, people: [(role: RiverRole.farmer, family: -1), ...items]);
      case PuzzleTier.easy:
        return RiverPuzzle(variant: RiverVariant.guardians, capacity: 2, people: crowd(3, 2 + random.nextInt(2)));
      case PuzzleTier.normal:
        return RiverPuzzle(variant: RiverVariant.families, capacity: 2, people: families(3));
      case PuzzleTier.hard:
        return RiverPuzzle(variant: RiverVariant.guardians, capacity: 3, people: crowd(5, 5));
      case PuzzleTier.expert:
        return RiverPuzzle(variant: RiverVariant.families, capacity: 3, people: families(5));
    }
  }

  @override
  bool solved(RiverPuzzle puzzle, List<RiverCrossing> answer) => answer.length <= riverMaxCrossings && riverReplay(puzzle, answer)?.left == 0;

  @override
  int difficulty(RiverPuzzle puzzle) => riverDifficulty(puzzle);

  // 每个人编成一个数：0 农夫、1 狼、2 羊、3 白菜、4 大人、5 小孩，第 f 家的爸爸 10 + 2f、孩子 11 + 2f（发出后不改）。
  static int _code(RiverPerson person) => switch (person.role) {
    RiverRole.father => 10 + person.family * 2,
    RiverRole.son => 11 + person.family * 2,
    _ => person.role.index,
  };

  static RiverPerson _person(int code) {
    if (code >= 10) return (role: code.isEven ? RiverRole.father : RiverRole.son, family: (code - 10) ~/ 2);
    if (code > RiverRole.kid.index) throw const FormatException('人物编码不合法');
    return (role: RiverRole.values[code], family: -1);
  }

  @override
  Object encodePuzzle(RiverPuzzle puzzle) => {'variant': puzzle.variant.name, 'capacity': puzzle.capacity, 'people': [for (final person in puzzle.people) _code(person)]};

  // 外部输入：题型、容量、人物逐项校验，人物要和题型对得上（农夫过河正好四样、大人小孩都有、父子成对），开局要合规、要解得开。
  @override
  RiverPuzzle decodePuzzle(Object? json) {
    final variant = RiverVariant.values.where((variant) => json is Map && json['variant'] == variant.name).firstOrNull;
    if (variant == null) throw const FormatException('题型不合法');
    final capacity = puzzleInt(json, 'capacity', min: riverMinCapacity, max: riverMaxCapacity);
    final codes = puzzleInts((json as Map)['people'], maxLength: riverMaxPeople, min: 0, max: 11 + (riverFamilyNames.length - 1) * 2);
    final people = [for (final code in codes) _person(code)];
    final roles = [for (final person in people) person.role];
    int count(RiverRole role) => roles.where((item) => item == role).length;
    final fits = switch (variant) {
      RiverVariant.farmer => capacity == 2 && people.length == 4 && [RiverRole.farmer, RiverRole.wolf, RiverRole.goat, RiverRole.cabbage].every((role) => count(role) == 1),
      RiverVariant.guardians => count(RiverRole.adult) > 0 && count(RiverRole.kid) > 0 && count(RiverRole.adult) + count(RiverRole.kid) == people.length,
      RiverVariant.families =>
        count(RiverRole.father) >= 2 &&
            count(RiverRole.father) * 2 == people.length &&
            {for (final person in people) person.family}.every((family) {
              final members = [for (final person in people) if (person.family == family) person.role];
              return family >= 0 && members.length == 2 && members.toSet().length == 2;
            }),
    };
    if (!fits) throw const FormatException('人物与题型对不上');
    final puzzle = RiverPuzzle(variant: variant, capacity: capacity, people: people);
    if (riverTrouble(puzzle, puzzle.everyone, RiverPlace.left) != null || riverSolve(puzzle) == null) throw const FormatException('这道题解不开');
    return puzzle;
  }

  // 每次渡河是一组下标，最多 riverMaxCrossings 次；一组里不能重复、不能是空的、不超过 riverMaxCapacity 个。
  @override
  Object encodeAnswer(List<RiverCrossing> answer) => [for (final crossing in answer) [...crossing]];

  @override
  List<RiverCrossing> decodeAnswer(Object? json) {
    if (json is! List || json.length > riverMaxCrossings) throw const FormatException('答案不合法');
    return [
      for (final item in json)
        () {
          final crossing = puzzleInts(item, maxLength: riverMaxCapacity, min: 0, max: riverMaxPeople - 1);
          if (crossing.isEmpty || crossing.toSet().length != crossing.length) throw const FormatException('答案不合法');
          return crossing;
        }(),
    ];
  }
}
