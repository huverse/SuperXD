import 'dart:math' as math;

import 'package:superxd/playground/puzzle_rules.dart';

// 过河问题：把所有人和物从左岸送到右岸。船（桥与火把里是火把）在哪岸，哪岸的人才能走；一次至少一人、不超过 capacity，里面要有会划船的人。
// 五种题型（RiverVariant，name 写进题面、发出后不改），都是经典过河谜题：
// - farmer 农夫过河：农夫带动物与东西，只有农夫会划船；没人看着时按食物链 riverPrey 会吃（狼吃羊、羊吃白菜、猫吃老鼠……）。
// - guardians 大人与小孩（传教士与野人）：哪一处有大人，小孩就不能比大人多；boat 为真时船上也单独算一处。
// - families 父子（嫉妒的丈夫）：孩子的爸爸不在场时，不能和别人家的爸爸待在一起，岸上和船上都算。
// - household 家庭过河：爸爸不在时妈妈会骂儿子，妈妈不在时爸爸会骂女儿，警察不在时小偷会欺负家里人，岸上和船上都算。
// - bridge 桥与火把：每人过桥的分钟数不同，一次最多 capacity 人、要带火把、按慢的那个算；火把只烧 limit 分钟。
// 谁会划船（rowers）写在题面上：农夫过河只有农夫，桥与火把人人能拿火把，其余三种按题随机，出题时确认这条限制确实让题变难。
// 判定在开船那一刻：船上（boat 为真的题型）、留在出发岸的、靠岸后的对岸（连船上的人）都合规才开得了；桥与火把再看火把还够不够烧。
// 船靠岸后，船上的人算在那一岸（对局页里他们可以留在船上，下一趟接着坐），所以状态就是「左岸有谁、船在哪岸」，桥与火把另记用了几分钟。
// 第 2 版题面写法（puzzleVersion 2）：加了家庭过河、桥与火把、农夫过河的多种动物、谁会划船、大人与小孩的船上也算；第 1 版的判定留在服务端给旧客户端。
enum RiverVariant { farmer, guardians, families, household, bridge }

// 身份与题面里的编码（code，发出后不改）：父子按家编码（爸爸 100 + 2 × 家、孩子 101 + 2 × 家），其余就是 code。
enum RiverRole {
  farmer(0),
  wolf(1),
  goat(2),
  cabbage(3),
  adult(4),
  kid(5),
  dog(6),
  cat(7),
  mouse(8),
  chicken(9),
  rice(10),
  dad(11),
  mom(12),
  boy(13),
  girl(14),
  police(15),
  thief(16),
  walker(17),
  father(100),
  son(101);

  const RiverRole(this.code);
  final int code;
}

// 一个人（或一样东西）：身份，父子还带是哪一家（名字池 riverFamilyNames 的下标，其余是 -1）。
typedef RiverPerson = ({RiverRole role, int family});

// 父子的合成称呼「大明 / 小明」：名字池的下标就是家的编号，页面按它配色。发出后只能在末尾追加（题面按下标存）。
const riverFamilyNames = ['明', '华', '刚', '伟', '亮', '军'];

// 农夫过河的食物链（谁吃谁）：只在末尾追加。没人看着时同一处有一对就出事。
const riverPrey = [
  (RiverRole.wolf, RiverRole.goat),
  (RiverRole.goat, RiverRole.cabbage),
  (RiverRole.wolf, RiverRole.chicken),
  (RiverRole.dog, RiverRole.cat),
  (RiverRole.cat, RiverRole.mouse),
  (RiverRole.mouse, RiverRole.rice),
  (RiverRole.chicken, RiverRole.rice),
];

// 农夫过河能带的动物与东西（出题时从这里挑）。
const riverItems = [RiverRole.wolf, RiverRole.goat, RiverRole.cabbage, RiverRole.dog, RiverRole.cat, RiverRole.mouse, RiverRole.chicken, RiverRole.rice];

const riverLeft = 0, riverRight = 1;
const riverMaxPeople = 10;
const riverMinCapacity = 2;
const riverMaxCapacity = 4;
// 桥与火把：最多几人、每人过桥最多几分钟、火把最多烧几分钟（外部输入的上限）。
const riverMaxWalkers = 7, riverMaxMinutes = 60, riverMaxLimit = 600;
// 一局最多记这么多次渡河（外部输入的上限；最难一档最少二十来次，留足走弯路的余地）。
const riverMaxCrossings = 1024;

class RiverPuzzle {
  const RiverPuzzle({required this.variant, required this.capacity, required this.people, required this.rowers, this.boat = false, this.minutes = const [], this.limit = 0});
  final RiverVariant variant;
  final int capacity;
  // 顺序就是答案里的下标；岸上的站位按身份排（见对局页）。
  final List<RiverPerson> people;
  // 会划船的人（下标的位集）。
  final int rowers;
  // 船上算不算单独一处：父子、家庭过河恒为真，大人与小孩按题，农夫过河与桥与火把恒为假。
  final bool boat;
  // 桥与火把：每人过桥的分钟数（同 people 一一对应）与火把能烧的分钟数；其余题型为空、0。
  final List<int> minutes;
  final int limit;

  int get count => people.length;
  int get everyone => (1 << people.length) - 1;
  bool get timed => variant == RiverVariant.bridge;
  bool rows(int index) => rowers & (1 << index) != 0;
}

// 一次渡河运的是哪些人：下标升序。
typedef RiverCrossing = List<int>;

// 名字：一样的人（大人、小孩）不编号（读屏标签由页面编号）；家里两个儿子叫哥哥、弟弟，两个女儿叫姐姐、妹妹；桥与火把按分钟叫。
String riverName(RiverPuzzle puzzle, int index) {
  final person = puzzle.people[index];
  String sibling(String one, String elder, String younger) {
    final same = [for (var other = 0; other < puzzle.count; other++) if (puzzle.people[other].role == person.role) other];
    return same.length == 1 ? one : (same.first == index ? elder : younger);
  }

  return switch (person.role) {
    RiverRole.farmer => '农夫',
    RiverRole.wolf => '狼',
    RiverRole.goat => '羊',
    RiverRole.cabbage => '白菜',
    RiverRole.adult => '大人',
    RiverRole.kid => '小孩',
    RiverRole.dog => '狗',
    RiverRole.cat => '猫',
    RiverRole.mouse => '老鼠',
    RiverRole.chicken => '鸡',
    RiverRole.rice => '米',
    RiverRole.dad => '爸爸',
    RiverRole.mom => '妈妈',
    RiverRole.boy => sibling('儿子', '哥哥', '弟弟'),
    RiverRole.girl => sibling('女儿', '姐姐', '妹妹'),
    RiverRole.police => '警察',
    RiverRole.thief => '小偷',
    RiverRole.walker => '${puzzle.minutes[index]} 分钟',
    RiverRole.father => '大${riverFamilyNames[person.family]}',
    RiverRole.son => '小${riverFamilyNames[person.family]}',
  };
}

// 开船查出的问题：哪一种、在哪里、牵涉谁（下标）。页面按它写提示、把牵涉的人标出来。
// eaten：[吃的, 被吃的]；outnumbered：那一处的小孩；unguarded：[孩子, 别人家的爸爸]；scolded：[爸爸或妈妈, 孩子]；robbed：[小偷, 家里人]；overtime：[这一趟最慢的人]。
enum RiverFault { empty, crowded, absent, noRower, eaten, outnumbered, unguarded, scolded, robbed, overtime }

enum RiverPlace { left, right, boat }

class RiverViolation {
  const RiverViolation(this.fault, {this.place, this.people = const []});
  final RiverFault fault;
  final RiverPlace? place;
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

// 「a 和 b 在一处、guards 里的人一个都不在」就出事（kind 是哪一类规矩，出题核对「每条规矩都有用」时按类拿掉）。
typedef RiverRule = ({RiverFault fault, int kind, int a, int b, int guards});

// 规矩的类：农夫过河按食物链的每一对（riverPrey 的下标）各算一类，其余题型每种规矩一类。
const riverKindScoldMom = 100, riverKindScoldDad = 101, riverKindThief = 102, riverKindFamilies = 103;

// 这道题的全部「两人不能单独在一起」的规矩（大人与小孩的人数规矩另算），按下标顺序排，查问题时报第一条。
List<RiverRule> riverRules(RiverPuzzle puzzle) {
  final people = puzzle.people;
  final all = [for (var index = 0; index < people.length; index++) index];
  List<int> having(RiverRole role) => [for (final index in all) if (people[index].role == role) index];
  final rules = <RiverRule>[];
  switch (puzzle.variant) {
    case RiverVariant.farmer:
      final guards = riverMask(having(RiverRole.farmer));
      for (final (kind, (eater, eaten)) in riverPrey.indexed) {
        for (final a in having(eater)) {
          for (final b in having(eaten)) {
            rules.add((fault: RiverFault.eaten, kind: kind, a: a, b: b, guards: guards));
          }
        }
      }
    case RiverVariant.families:
      for (final son in having(RiverRole.son)) {
        final own = riverMask([for (final index in having(RiverRole.father)) if (people[index].family == people[son].family) index]);
        for (final other in having(RiverRole.father)) {
          if (own & (1 << other) == 0) rules.add((fault: RiverFault.unguarded, kind: riverKindFamilies, a: son, b: other, guards: own));
        }
      }
    case RiverVariant.household:
      final dads = riverMask(having(RiverRole.dad)), moms = riverMask(having(RiverRole.mom)), police = riverMask(having(RiverRole.police));
      for (final mom in having(RiverRole.mom)) {
        for (final boy in having(RiverRole.boy)) {
          rules.add((fault: RiverFault.scolded, kind: riverKindScoldMom, a: mom, b: boy, guards: dads));
        }
      }
      for (final dad in having(RiverRole.dad)) {
        for (final girl in having(RiverRole.girl)) {
          rules.add((fault: RiverFault.scolded, kind: riverKindScoldDad, a: dad, b: girl, guards: moms));
        }
      }
      for (final thief in having(RiverRole.thief)) {
        for (final victim in all) {
          if (const {RiverRole.dad, RiverRole.mom, RiverRole.boy, RiverRole.girl}.contains(people[victim].role)) {
            rules.add((fault: RiverFault.robbed, kind: riverKindThief, a: thief, b: victim, guards: police));
          }
        }
      }
    case RiverVariant.guardians || RiverVariant.bridge:
      break;
  }
  return rules;
}

// 一群人待在一处（岸上或船上）有没有问题，没有返回 null。skip 是出题核对时拿掉的规矩类（-1 是大人与小孩的人数规矩）。
RiverViolation? riverTrouble(RiverPuzzle puzzle, int group, RiverPlace place, {List<RiverRule>? rules, Set<int> skip = const {}}) {
  if (puzzle.variant == RiverVariant.guardians && !skip.contains(-1)) {
    final kids = [for (final index in riverMembers(group)) if (puzzle.people[index].role == RiverRole.kid) index];
    final adults = riverBits(group) - kids.length;
    if (adults > 0 && kids.length > adults) return RiverViolation(RiverFault.outnumbered, place: place, people: kids);
  }
  for (final rule in rules ?? riverRules(puzzle)) {
    if (group & (1 << rule.a) == 0 || group & (1 << rule.b) == 0 || group & rule.guards != 0 || skip.contains(rule.kind)) continue;
    return RiverViolation(rule.fault, place: place, people: [rule.a, rule.b]);
  }
  return null;
}

// 一趟要几分钟：桥与火把按船上最慢的人，其余题型每趟算 1。
int riverCost(RiverPuzzle puzzle, int group) {
  if (!puzzle.timed) return 1;
  var most = 0;
  for (final index in riverMembers(group)) {
    most = math.max(most, puzzle.minutes[index]);
  }
  return most;
}

// 开船前的检查：left 是左岸（含停在左岸的船上）的人，side 是船在哪岸，group 是船上的人，spent 是桥与火把已经用了几分钟。
// 按「船上 → 留下的岸 → 对岸 → 火把」的顺序报第一处问题。
RiverViolation? riverCheck(RiverPuzzle puzzle, int left, int side, int group, {int spent = 0}) {
  final here = side == riverLeft ? left : puzzle.everyone & ~left;
  if (group == 0) return const RiverViolation(RiverFault.empty);
  if (riverBits(group) > puzzle.capacity) return const RiverViolation(RiverFault.crowded);
  if (group & ~here != 0) return const RiverViolation(RiverFault.absent);
  if (group & puzzle.rowers == 0) return const RiverViolation(RiverFault.noRower);
  final from = side == riverLeft ? RiverPlace.left : RiverPlace.right, to = side == riverLeft ? RiverPlace.right : RiverPlace.left;
  final rules = riverRules(puzzle);
  final trouble = (puzzle.boat ? riverTrouble(puzzle, group, RiverPlace.boat, rules: rules) : null) ??
      riverTrouble(puzzle, here & ~group, from, rules: rules) ??
      riverTrouble(puzzle, (puzzle.everyone & ~here) | group, to, rules: rules);
  if (trouble != null || !puzzle.timed || spent + riverCost(puzzle, group) <= puzzle.limit) return trouble;
  final slowest = riverMembers(group).reduce((most, index) => puzzle.minutes[index] > puzzle.minutes[most] ? index : most);
  return RiverViolation(RiverFault.overtime, people: [slowest]);
}

// 渡一次河之后左岸有谁。
int riverAfter(int left, int side, int group) => side == riverLeft ? left & ~group : left | group;

// 按次重放：每次都合规才往下走，返回最后左岸有谁、船在哪岸与用了几分钟（不计时的题型是渡河次数）；有一次不合规返回 null。
({int left, int side, int spent})? riverReplay(RiverPuzzle puzzle, Iterable<RiverCrossing> crossings) {
  var left = puzzle.everyone, side = riverLeft, spent = 0;
  for (final crossing in crossings) {
    if (crossing.any((index) => index < 0 || index >= puzzle.count)) return null;
    final group = riverMask(crossing);
    if (riverBits(group) != crossing.length || riverCheck(puzzle, left, side, group, spent: spent) != null) return null;
    left = riverAfter(left, side, group);
    side = 1 - side;
    spent += riverCost(puzzle, group);
  }
  return (left: left, side: side, spent: spent);
}

// 求解用的表：每群人能不能单独待一处、船上能坐的每一种组合（按掩码升序，结果只由题面决定）与每种坐法的用时。
// 状态编成「左岸掩码 × 2 + 船在哪岸」，10 个人一共 2048 个，每个状态最多试 C(10,1)+…+C(10,4) = 385 种坐法。
// relax 是出题核对用的放宽：拿掉几类规矩（skip）、人人会划船（rowers）、船上不算（boat 为假）。
class _RiverGraph {
  _RiverGraph(this.puzzle, {Set<int> skip = const {}, int? rowers, bool? boat})
    : rowers = rowers ?? puzzle.rowers,
      boat = boat ?? puzzle.boat,
      groups = [for (var mask = 1; mask <= puzzle.everyone; mask++) if (riverBits(mask) <= puzzle.capacity) mask] {
    final rules = riverRules(puzzle);
    calm = [for (var mask = 0; mask <= puzzle.everyone; mask++) riverTrouble(puzzle, mask, RiverPlace.left, rules: rules, skip: skip) == null];
    costs = [for (final group in groups) riverCost(puzzle, group)];
    // 一样的人（同身份、同一家、同分钟、会不会划船也一样）互换算同一个局面：按每类在左岸几个归一。
    final classes = <String, int>{};
    weights = [
      for (var index = 0; index < puzzle.count; index++)
        math.pow(11, classes.putIfAbsent('${puzzle.people[index].role.code}/${puzzle.people[index].family}/${puzzle.timed ? puzzle.minutes[index] : 0}/${puzzle.rows(index)}', () => classes.length)).toInt(),
    ];
  }

  final RiverPuzzle puzzle;
  final int rowers;
  final bool boat;
  final List<int> groups;
  late final List<bool> calm;
  late final List<int> costs;
  late final List<int> weights;

  static final _cache = Expando<_RiverGraph>();
  static _RiverGraph of(RiverPuzzle puzzle) => _cache[puzzle] ??= _RiverGraph(puzzle);

  int get start => puzzle.everyone * 2 + riverLeft;
  static const goal = riverRight;

  // 从 state 渡 group 过河之后的状态，不合规返回 null（同 riverCheck，用查表；不看火把，火把另由用时比）。
  int? cross(int state, int group) {
    final left = state >> 1, side = state & 1;
    final here = side == riverLeft ? left : puzzle.everyone & ~left;
    if (group & ~here != 0 || group & rowers == 0) return null;
    if (boat && !calm[group]) return null;
    final next = riverAfter(left, side, group);
    if (!calm[next] || !calm[puzzle.everyone & ~next]) return null;
    return next * 2 + 1 - side;
  }

  // 按用时最短（不计时的题型就是次数最少）从 origin 出发到每个状态的用时（到不了是 -1），顺带记从哪来、运了谁。
  // 用时是小整数，按用时分桶走（每趟至少 1，同一桶里先到先定），不计时的题型就是广度优先。allow 是出题核对用的走法限制。
  ({List<int> cost, List<int> previous, List<int> carried}) search(int origin, {bool Function(int state, int group)? allow}) {
    final size = (puzzle.everyone + 1) * 2;
    final cost = List.filled(size, -1), previous = List.filled(size, -1), carried = List.filled(size, 0);
    final done = List.filled(size, false);
    final buckets = <List<int>>[
      [origin],
    ];
    cost[origin] = 0;
    for (var spent = 0; spent < buckets.length; spent++) {
      for (final state in buckets[spent]) {
        if (done[state] || cost[state] != spent) continue;
        done[state] = true;
        for (final (index, group) in groups.indexed) {
          final next = cross(state, group);
          if (next == null || done[next] || (allow != null && !allow(state, group))) continue;
          final reach = spent + costs[index];
          if (cost[next] >= 0 && cost[next] <= reach) continue;
          cost[next] = reach;
          previous[next] = state;
          carried[next] = group;
          while (buckets.length <= reach) {
            buckets.add([]);
          }
          buckets[reach].add(next);
        }
      }
    }
    return (cost: cost, previous: previous, carried: carried);
  }

  // 局面归一：每类在左岸几个（按 11 进制拼成一个数，每类最多 10 个），加船在哪岸。
  int canonical(int state) {
    var key = 0;
    for (final index in riverMembers(state >> 1)) {
      key += weights[index];
    }
    return key * 2 + (state & 1);
  }
}

// 最短（不计时的是次数最少，桥与火把是用时最短）的一份走法；解不开返回 null。桥与火把不看火把能烧多久（出题时火把就定成这个用时）。
// 给了 left、side 就从那个局面（左岸有谁、船在哪岸）算起（判定向量从半路接着走完用）。
List<RiverCrossing>? riverSolve(RiverPuzzle puzzle, {int? left, int side = riverLeft}) {
  final graph = _RiverGraph.of(puzzle);
  final origin = left == null ? graph.start : left * 2 + side;
  final search = graph.search(origin);
  if (search.cost[_RiverGraph.goal] < 0) return null;
  final crossings = <RiverCrossing>[];
  for (var state = _RiverGraph.goal; state != origin; state = search.previous[state]) {
    crossings.add(riverMembers(search.carried[state]));
  }
  return crossings.reversed.toList();
}

// 最少要几次（不计时）或几分钟（桥与火把）；解不开是 -1。
int riverLeast(RiverPuzzle puzzle) {
  final graph = _RiverGraph.of(puzzle);
  return graph.search(graph.start).cost[_RiverGraph.goal];
}

// 出题核对「每条机制都有用」时的放宽：拿掉几类规矩、人人会划船、船上不算、桥与火把每次都由最快的人一个人送回火把。返回放宽后的最少次数或用时，解不开是 -1。
int riverRelaxed(RiverPuzzle puzzle, {Set<int> skip = const {}, bool allRow = false, bool noBoat = false, bool escort = false}) {
  final graph = _RiverGraph(puzzle, skip: skip, rowers: allRow ? puzzle.everyone : null, boat: noBoat ? false : null);
  var fastest = 0;
  for (var index = 1; index < puzzle.count && puzzle.timed; index++) {
    if (puzzle.minutes[index] < puzzle.minutes[fastest]) fastest = index;
  }
  bool alone(int state, int group) => state & 1 == riverLeft || group == 1 << fastest;
  return graph.search(graph.start, allow: escort ? alone : null).cost[_RiverGraph.goal];
}

// 推理深度的两项：
// - bits：沿最短走法，每一步在「合规的走法」里挑中「还在最短路上的走法」要的信息量 log2(合规数 / 最优数) 之和，
//   有几条最短路时按均匀挑最优走法取期望。步数越多、每步能走的越多而对的越少，越高；走法按局面归一（两个大人互换算一种）。
//   桥与火把按用时算最短路（火把够不够烧不进局面，走不通的方向一样算合规的走法）。
// - states：从开局走得到的局面有多少种（归一后），是要在脑子里排除的范围。
({double bits, int states}) riverDepth(RiverPuzzle puzzle) {
  final graph = _RiverGraph.of(puzzle);
  final toGoal = graph.search(_RiverGraph.goal).cost;
  final reached = graph.search(graph.start).cost;
  final states = {for (var state = 0; state < reached.length; state++) if (reached[state] >= 0) graph.canonical(state)}.length;
  final memo = <int, double>{};
  double expect(int state) {
    if (state == _RiverGraph.goal) return 0;
    if (memo[state] case final value?) return value;
    final seen = <int>{}, best = <int>[];
    for (final (index, group) in graph.groups.indexed) {
      final next = graph.cross(state, group);
      if (next == null || !seen.add(graph.canonical(next))) continue;
      if (toGoal[next] + graph.costs[index] == toGoal[state]) best.add(next);
    }
    final value = math.log(seen.length / best.length) / math.ln2 + best.map(expect).reduce((sum, value) => sum + value) / best.length;
    return memo[state] = value;
  }

  return (bits: expect(graph.start), states: states);
}

// 每条机制都有用（出题时核对，题面上写出来的规矩没有摆设）：拿掉任何一类「不能单独在一起」的规矩、大人与小孩的人数规矩、
// 「只有带桨的会划船」（农夫过河除外，动物本来就不会划）或「船上也算」，最少次数都会变少；桥与火把要用到「两个慢的一起走」，
// 也就是只让最快的人一个人送回火把，用时会变长。
bool riverNeeded(RiverPuzzle puzzle) {
  final least = riverLeast(puzzle);
  if (least < 0) return false;
  if (puzzle.timed) return riverRelaxed(puzzle, escort: true) > least;
  final kinds = {for (final rule in riverRules(puzzle)) rule.kind, if (puzzle.variant == RiverVariant.guardians) -1};
  if (kinds.any((kind) => riverRelaxed(puzzle, skip: {kind}) >= least)) return false;
  if (puzzle.variant != RiverVariant.farmer && puzzle.rowers != puzzle.everyone && riverRelaxed(puzzle, allRow: true) >= least) return false;
  return !(puzzle.variant == RiverVariant.guardians && puzzle.boat && riverRelaxed(puzzle, noBoat: true) >= least);
}

// 难易分 1–10（只在这个游戏里排难易）：
// - 坐船的四种：bits × 0.55 + log2(states) × 0.7 − 3.7（bits 已经按步数累加，步数多、每步岔路多都会抬高它）。
//   实测：农夫过河 7 次 → 2；三大人三小孩船 2 人 11 次 → 5；三对父子船 2 人 11 次 → 6；五大人五小孩船 3 人 11 次 → 7；
//   家庭过河原题（两儿两女加警察小偷、只有大人会划）17 次 → 10。
// - 桥与火把：1.6 + bits × 0.3。每步能走的组合多、对的只有一两种，比特很高，但人是按「最快的人送火把」与「两个慢的一起走」两种套路想的，
//   所以压低比特的分量：4 人要用到技巧 → 5；5 人 → 6；6 人桥上 3 人 → 6；6 人 → 8–9；7 人 → 10。
// riverScore 是没取整的分（预计用时按它算，同一级里步数多、岔路多的也多给一点时间），riverDifficulty 取整夹在 1–10。
double riverScore(RiverPuzzle puzzle) {
  final depth = riverDepth(puzzle);
  return puzzle.timed ? 1.6 + depth.bits * .3 : depth.bits * .55 + math.log(depth.states) / math.ln2 * .7 - 3.7;
}

int riverDifficulty(RiverPuzzle puzzle) => riverScore(puzzle).round().clamp(1, 10);

// 一种题的骨架（实测每条机制都有用、难易分落在这一档；同类的人里哪几个会划船、站位先后、哪几家与动物的名字由种子定）。
// crew 与 rowing 按题型读：
// - farmer：crew 是带的动物与东西的 code（RiverRole.code），船坐 capacity（农夫加 capacity − 1 样）。
// - guardians：crew = [大人, 小孩]，rowing = [会划船的大人, 会划船的小孩]，boat 船上也算。
// - families：crew = [几对父子]，rowing 每家一个数：1 爸爸会划、2 孩子会划、3 都会、0 都不会（哪一家拿哪个数由种子定）。
// - household：crew = [儿子, 女儿, 有没有警察与小偷]，rowing = [爸爸, 妈妈, 警察, 小偷会不会划, 几个儿子会划, 几个女儿会划]。
// - bridge：crew = [几个人, 分钟最多几]，分钟从 1 到它里不重复地挑，人人能拿火把；要用到技巧、难易分落在这一档才用。
typedef _RiverPlan = ({RiverVariant variant, int capacity, List<int> crew, List<int> rowing, bool boat});

// 挑战题库不出的题型（人工决策见 RiverRules.challengeDraw）：只在自由模式出。
const riverChallengeless = {RiverVariant.bridge};

class RiverRules extends PuzzleRules<RiverPuzzle, List<RiverCrossing>> {
  const RiverRules();

  @override
  int get puzzleVersion => 2;

  // 挑战里的特性（[人工决策-2026-11-16 17:26:21] 见 puzzle_rules.dart 的 PuzzleRules.fragment）：碎片是最少渡河几次，桥与火把是最短几分钟。
  @override
  int? fragment(RiverPuzzle puzzle, List<RiverCrossing> solution) => riverLeast(puzzle);

  // 每档的难易分区间（不重叠）与最少渡河次数的下限（桥与火把不看次数）。档内按题型均匀挑、再在这个题型的骨架里均匀挑，
  // 简单与困难两档各一半落在区间两头，预计用时的中位数落在两级之间。
  static const _bands = {PuzzleTier.entry: (1, 2), PuzzleTier.easy: (3, 4), PuzzleTier.normal: (5, 5), PuzzleTier.hard: (6, 7), PuzzleTier.expert: (8, 10)};
  static const _floors = {PuzzleTier.entry: 5, PuzzleTier.easy: 5, PuzzleTier.normal: 7, PuzzleTier.hard: 9, PuzzleTier.expert: 11};

  // 各档的骨架（build/superxd_verify 下的摸底脚本枚举全部人数、船位、谁会划船与船上算不算，按上面两条筛出来的；专家档只留少数 10 分的，
  // 如家庭过河原题，免得中位数顶到最高一级）。低档单一规矩、船位宽，高档几条规矩叠加（家庭过河三条加谁会划船、大人与小孩加船上也算）、船更挤、次数更长。
  static const Map<PuzzleTier, List<_RiverPlan>> _plans = {
    PuzzleTier.entry: [
      (variant: RiverVariant.farmer, capacity: 2, crew: [1, 2, 3], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 2, crew: [1, 2, 9], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 2, crew: [1, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 2, crew: [6, 7, 8], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 2, crew: [7, 8, 10], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 2, crew: [8, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 2], rowing: [0, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 2], rowing: [0, 2], boat: false),
      (variant: RiverVariant.household, capacity: 3, crew: [0, 1, 1], rowing: [0, 1, 0, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [0, 1, 1], rowing: [0, 1, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [0, 1, 1], rowing: [0, 1, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 0], rowing: [0, 1, 0, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 0], rowing: [1, 1, 0, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [1, 0, 1], rowing: [1, 0, 0, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [1, 0, 1], rowing: [1, 0, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [1, 0, 1], rowing: [1, 0, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 0], rowing: [1, 0, 0, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 0], rowing: [1, 1, 0, 0, 0, 0], boat: true),
    ],
    PuzzleTier.easy: [
      (variant: RiverVariant.farmer, capacity: 3, crew: [1, 2, 3, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 3, crew: [1, 2, 8, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 3, crew: [1, 7, 8, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.farmer, capacity: 3, crew: [6, 7, 8, 9, 10], rowing: [], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [0, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [0, 2], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [0, 3], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [1, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [2, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [3, 3], rowing: [3, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [4, 3], rowing: [0, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [4, 3], rowing: [0, 2], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [4, 3], rowing: [0, 3], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [4, 3], rowing: [1, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [4, 3], rowing: [2, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [4, 3], rowing: [3, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [4, 3], rowing: [4, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [4, 4], rowing: [4, 4], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 2], rowing: [0, 1], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 2], rowing: [0, 2], boat: true),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 4], rowing: [1, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 4], rowing: [5, 0], boat: false),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [0, 0, 2], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [0, 1, 1], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [0, 2, 2], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [1, 1, 1], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [1, 1, 2], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [2, 2, 2], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [0, 1, 1], rowing: [0, 1, 0, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 3, crew: [1, 0, 1], rowing: [1, 0, 0, 1, 0, 0], boat: true),
    ],
    PuzzleTier.normal: [
      (variant: RiverVariant.guardians, capacity: 2, crew: [3, 3], rowing: [3, 3], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 3], rowing: [0, 1], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 3], rowing: [0, 3], boat: true),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 4], rowing: [2, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 4], rowing: [3, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 4], rowing: [4, 0], boat: false),
      (variant: RiverVariant.guardians, capacity: 4, crew: [5, 5], rowing: [5, 5], boat: false),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [0, 0, 1], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [3], rowing: [0, 1, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [0, 0, 1, 0, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [0, 0, 1, 1, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [1, 0, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [1, 0, 1, 0, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [1, 0, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 0, 1, 0, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 0, 1, 1, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 1, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 1, 1, 0, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 1, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.bridge, capacity: 2, crew: [4, 15], rowing: [], boat: false),
    ],
    PuzzleTier.hard: [
      (variant: RiverVariant.guardians, capacity: 2, crew: [3, 3], rowing: [3, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 3], rowing: [0, 2], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 4], rowing: [0, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 4], rowing: [0, 2], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 4], rowing: [0, 3], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 4], rowing: [0, 4], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 5], rowing: [5, 5], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 3], rowing: [0, 1], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 3], rowing: [0, 2], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 3], rowing: [0, 3], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [7, 2], rowing: [0, 1], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [7, 2], rowing: [0, 2], boat: true),
      (variant: RiverVariant.families, capacity: 2, crew: [3], rowing: [3, 3, 3], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [4], rowing: [3, 3, 3, 3], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 1, 1], rowing: [1, 0, 1, 1, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [0, 0, 1, 0, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [0, 0, 1, 0, 0, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [0, 0, 1, 1, 0, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [1, 1, 0, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [1, 1, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [1, 1, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 0, 1], rowing: [0, 1, 1, 1, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 1, 1], rowing: [0, 0, 1, 0, 1, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 1, 1], rowing: [0, 0, 1, 1, 1, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 0, 1, 0, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 0, 1, 0, 2, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 0, 1, 1, 2, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [1, 1, 0, 1, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [1, 1, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [1, 1, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.bridge, capacity: 2, crew: [5, 20], rowing: [], boat: false),
      (variant: RiverVariant.bridge, capacity: 3, crew: [6, 25], rowing: [], boat: false),
      (variant: RiverVariant.bridge, capacity: 3, crew: [7, 30], rowing: [], boat: false),
    ],
    PuzzleTier.expert: [
      (variant: RiverVariant.guardians, capacity: 2, crew: [3, 3], rowing: [1, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 2, crew: [3, 3], rowing: [2, 1], boat: false),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 4], rowing: [0, 1], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 4], rowing: [0, 2], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 4], rowing: [0, 3], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [6, 4], rowing: [0, 4], boat: true),
      (variant: RiverVariant.guardians, capacity: 3, crew: [5, 5], rowing: [1, 1], boat: false),
      (variant: RiverVariant.families, capacity: 2, crew: [3], rowing: [1, 1, 2], boat: true),
      (variant: RiverVariant.families, capacity: 2, crew: [3], rowing: [1, 1, 3], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [5], rowing: [3, 3, 3, 3, 3], boat: true),
      (variant: RiverVariant.families, capacity: 3, crew: [5], rowing: [1, 1, 1, 1, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [0, 0, 1, 1, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [1, 0, 1, 0, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [0, 2, 1], rowing: [1, 0, 1, 1, 0, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 1, 1], rowing: [0, 0, 0, 1, 1, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 2, 1], rowing: [0, 0, 1, 0, 1, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [1, 2, 1], rowing: [0, 0, 1, 1, 1, 2], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 0, 1, 1, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 1, 1, 0, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 0, 1], rowing: [0, 1, 1, 1, 1, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 1, 1], rowing: [0, 0, 1, 0, 2, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 1, 1], rowing: [0, 0, 1, 1, 2, 1], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 2, 1], rowing: [1, 1, 1, 0, 0, 0], boat: true),
      (variant: RiverVariant.household, capacity: 2, crew: [2, 2, 1], rowing: [1, 1, 1, 1, 0, 0], boat: true),
      (variant: RiverVariant.bridge, capacity: 2, crew: [6, 20], rowing: [], boat: false),
      (variant: RiverVariant.bridge, capacity: 2, crew: [6, 30], rowing: [], boat: false),
      (variant: RiverVariant.bridge, capacity: 2, crew: [7, 30], rowing: [], boat: false),
    ],
  };

  // 出题：按档在题型里均匀挑一种、再在这个题型的骨架里均匀挑一个，按种子定谁会划船、站位先后、名字与动物（桥与火把是每人的分钟数）；
  // 出题前核对：解得开、最少次数不低于这一档的下限、每条机制都有用（riverNeeded）、难易分落在这一档，不合就在同一题型里再挑
  // （骨架都实测过，坐船的第一个就能用；桥与火把的分钟是随机的，平均两三次）。
  @override
  PuzzleDraw<RiverPuzzle, List<RiverCrossing>> generate(int seed, PuzzleTier tier) => _draw(seed, _plans[tier]!, tier);

  // [人工决策-2026-11-17 14:17:05] 挑战里不出桥与火把（用户选定）：它的碎片（最短分钟）就是题面上写的火把分钟、不解也看得到，
  // 违背「碎片从解里来」；改用渡河次数又恒为 2n − 3、没有信息。所以挑战题库出题时排除这一类的骨架（riverChallengeless），自由模式照常有；
  // 服务端判定、解码与判定向量照样认得桥与火把的题面（旧数据与向量不受影响）。排除后每档仍有三种以上题型、骨架数见测试。
  @override
  PuzzleDraw<RiverPuzzle, List<RiverCrossing>> challengeDraw(int seed, PuzzleTier tier) =>
      _draw(seed, [for (final plan in _plans[tier]!) if (!riverChallengeless.contains(plan.variant)) plan], tier);

  PuzzleDraw<RiverPuzzle, List<RiverCrossing>> _draw(int seed, List<_RiverPlan> plans, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final variants = [for (final variant in RiverVariant.values) if (plans.any((plan) => plan.variant == variant)) variant];
    final variant = random.pick(variants);
    final candidates = [for (final plan in plans) if (plan.variant == variant) plan];
    for (var attempt = 0; attempt < 64; attempt++) {
      final puzzle = _cast(random.pick(candidates), random);
      if (_fits(puzzle, tier)) return PuzzleDraw(puzzle, riverSolve(puzzle)!);
    }
    throw StateError('过河问题 ${tier.name} 档出不了题');
  }

  static bool _fits(RiverPuzzle puzzle, PuzzleTier tier) {
    final least = riverLeast(puzzle);
    if (least < 0 || (!puzzle.timed && least < _floors[tier]!) || !riverNeeded(puzzle)) return false;
    final (low, high) = _bands[tier]!;
    final score = riverDifficulty(puzzle);
    return score >= low && score <= high;
  }

  static RiverPuzzle _cast(_RiverPlan plan, PuzzleRandom random) {
    // 在 count 个同类的人里随机挑 rowing 个会划船的：返回每人会不会。
    List<bool> some(int count, int rowing) {
      final flags = [for (var index = 0; index < count; index++) index < rowing];
      random.shuffle(flags);
      return flags;
    }

    final cast = <(RiverPerson, bool, int)>[];
    void add(RiverRole role, bool rows, {int family = -1, int minutes = 0}) => cast.add(((role: role, family: family), rows, minutes));
    switch (plan.variant) {
      case RiverVariant.farmer:
        add(RiverRole.farmer, true);
        for (final code in plan.crew) {
          add(RiverRole.values.firstWhere((role) => role.code == code), false);
        }
      case RiverVariant.guardians:
        for (final rows in some(plan.crew[0], plan.rowing[0])) {
          add(RiverRole.adult, rows);
        }
        for (final rows in some(plan.crew[1], plan.rowing[1])) {
          add(RiverRole.kid, rows);
        }
      case RiverVariant.families:
        final names = [for (var index = 0; index < riverFamilyNames.length; index++) index];
        random.shuffle(names);
        final rowing = [...plan.rowing];
        random.shuffle(rowing);
        for (final (index, family) in names.take(plan.crew[0]).indexed) {
          add(RiverRole.father, rowing[index] & 1 != 0, family: family);
          add(RiverRole.son, rowing[index] & 2 != 0, family: family);
        }
      case RiverVariant.household:
        add(RiverRole.dad, plan.rowing[0] == 1);
        add(RiverRole.mom, plan.rowing[1] == 1);
        for (final rows in some(plan.crew[0], plan.rowing[4])) {
          add(RiverRole.boy, rows);
        }
        for (final rows in some(plan.crew[1], plan.rowing[5])) {
          add(RiverRole.girl, rows);
        }
        if (plan.crew[2] == 1) {
          add(RiverRole.police, plan.rowing[2] == 1);
          add(RiverRole.thief, plan.rowing[3] == 1);
        }
      case RiverVariant.bridge:
        final pool = [for (var minute = 1; minute <= plan.crew[1]; minute++) minute];
        random.shuffle(pool);
        for (final minutes in pool.take(plan.crew[0])) {
          add(RiverRole.walker, true, minutes: minutes);
        }
    }
    random.shuffle(cast);
    final people = [for (final (person, _, _) in cast) person];
    final rowers = riverMask([for (final (index, (_, rows, _)) in cast.indexed) if (rows) index]);
    if (plan.variant != RiverVariant.bridge) return RiverPuzzle(variant: plan.variant, capacity: plan.capacity, people: people, rowers: rowers, boat: plan.boat);
    // 火把正好够最快的走法：先不限时求出最短用时，再把火把定成它。
    final minutes = [for (final (_, _, minutes) in cast) minutes];
    final open = RiverPuzzle(variant: plan.variant, capacity: plan.capacity, people: people, rowers: rowers, minutes: minutes, limit: riverMaxLimit);
    return RiverPuzzle(variant: plan.variant, capacity: plan.capacity, people: people, rowers: rowers, minutes: minutes, limit: riverLeast(open));
  }

  @override
  bool solved(RiverPuzzle puzzle, List<RiverCrossing> answer) => answer.length <= riverMaxCrossings && riverReplay(puzzle, answer)?.left == 0;

  // 预计用时：按没取整的分（riverScore，夹在 1–10）每高一分乘 growth，同 puzzlePace 的口径；系数让五档的中位数约为 45、70、110、165、245 秒。
  static const _base = 35.0, _growth = 1.31;

  @override
  int expectedSeconds(RiverPuzzle puzzle) => (_base * math.pow(_growth, riverScore(puzzle).clamp(1, 10) - 1)).round();

  @override
  int complexity(RiverPuzzle puzzle) => riverDifficulty(puzzle);

  static int _code(RiverPerson person) => switch (person.role) {
    RiverRole.father || RiverRole.son => person.role.code + person.family * 2,
    _ => person.role.code,
  };

  static RiverPerson _person(int code) {
    if (code >= RiverRole.father.code) {
      final family = (code - RiverRole.father.code) ~/ 2;
      if (family >= riverFamilyNames.length) throw const FormatException('人物编码不合法');
      return (role: code.isEven ? RiverRole.father : RiverRole.son, family: family);
    }
    final role = RiverRole.values.where((role) => role.code == code && role != RiverRole.father && role != RiverRole.son).firstOrNull;
    if (role == null) throw const FormatException('人物编码不合法');
    return (role: role, family: -1);
  }

  // 题面：题型、船坐几人、每个人的编码、会划船的人（下标升序）；大人与小孩另写船上算不算，桥与火把另写每人的分钟与火把能烧几分钟。
  @override
  Object encodePuzzle(RiverPuzzle puzzle) => {
    'variant': puzzle.variant.name,
    'capacity': puzzle.capacity,
    'people': [for (final person in puzzle.people) _code(person)],
    'rowers': riverMembers(puzzle.rowers),
    if (puzzle.variant == RiverVariant.guardians) 'boat': puzzle.boat,
    if (puzzle.timed) ...{'minutes': [...puzzle.minutes], 'limit': puzzle.limit},
  };

  // 外部输入：逐项校验，人物要和题型对得上（农夫过河一个农夫加不重样的动物与东西、只有农夫会划；大人小孩都有；父子成对；
  // 家庭过河一爸一妈、儿女各至多两个且至少一个、警察与小偷同进同出；桥与火把每人带分钟、人人能拿火把），开局要合规、要解得开（桥与火把在火把烧完前）。
  @override
  RiverPuzzle decodePuzzle(Object? json) {
    final variant = RiverVariant.values.where((variant) => json is Map && json['variant'] == variant.name).firstOrNull;
    if (variant == null) throw const FormatException('题型不合法');
    final map = json as Map;
    final capacity = puzzleInt(json, 'capacity', min: riverMinCapacity, max: riverMaxCapacity);
    final codes = puzzleInts(map['people'], maxLength: riverMaxPeople, min: 0, max: RiverRole.son.code + (riverFamilyNames.length - 1) * 2);
    final people = [for (final code in codes) _person(code)];
    final members = puzzleInts(map['rowers'], maxLength: riverMaxPeople, min: 0, max: riverMaxPeople - 1);
    for (var index = 0; index < members.length; index++) {
      if (members[index] >= people.length || (index > 0 && members[index] <= members[index - 1])) throw const FormatException('会划船的人不合法');
    }
    final rowers = riverMask(members), everyone = (1 << people.length) - 1;
    final roles = [for (final person in people) person.role];
    int count(RiverRole role) => roles.where((item) => item == role).length;
    bool only(Set<RiverRole> allowed) => roles.every(allowed.contains);
    final fits = switch (variant) {
      RiverVariant.farmer =>
        count(RiverRole.farmer) == 1 && people.length >= 2 && only({RiverRole.farmer, ...riverItems}) && roles.toSet().length == roles.length && rowers == 1 << roles.indexOf(RiverRole.farmer),
      RiverVariant.guardians => count(RiverRole.adult) > 0 && count(RiverRole.kid) > 0 && only({RiverRole.adult, RiverRole.kid}),
      RiverVariant.families =>
        count(RiverRole.father) >= 2 &&
            only({RiverRole.father, RiverRole.son}) &&
            {for (final person in people) person.family}.every((family) {
              final members = [for (final person in people) if (person.family == family) person.role];
              return members.length == 2 && members.toSet().length == 2;
            }),
      RiverVariant.household =>
        count(RiverRole.dad) == 1 &&
            count(RiverRole.mom) == 1 &&
            count(RiverRole.boy) <= 2 &&
            count(RiverRole.girl) <= 2 &&
            count(RiverRole.boy) + count(RiverRole.girl) > 0 &&
            count(RiverRole.police) == count(RiverRole.thief) &&
            count(RiverRole.police) <= 1 &&
            only({RiverRole.dad, RiverRole.mom, RiverRole.boy, RiverRole.girl, RiverRole.police, RiverRole.thief}),
      RiverVariant.bridge => people.length >= 2 && people.length <= riverMaxWalkers && only({RiverRole.walker}) && rowers == everyone,
    };
    if (!fits || rowers == 0) throw const FormatException('人物与题型对不上');
    final boat = switch (variant) {
      RiverVariant.guardians => map['boat'] is bool ? map['boat'] as bool : throw const FormatException('船上算不算不合法'),
      RiverVariant.families || RiverVariant.household => true,
      RiverVariant.farmer || RiverVariant.bridge => false,
    };
    final timed = variant == RiverVariant.bridge;
    final minutes = timed ? puzzleInts(map['minutes'], maxLength: riverMaxWalkers, min: 1, max: riverMaxMinutes) : const <int>[];
    if (minutes.length != (timed ? people.length : 0) || minutes.toSet().length != minutes.length) throw const FormatException('分钟数对不上');
    final limit = timed ? puzzleInt(json, 'limit', min: 1, max: riverMaxLimit) : 0;
    final puzzle = RiverPuzzle(variant: variant, capacity: capacity, people: people, rowers: rowers, boat: boat, minutes: minutes, limit: limit);
    final least = riverLeast(puzzle);
    if (riverTrouble(puzzle, everyone, RiverPlace.left) != null || least < 0 || (timed && least > limit)) throw const FormatException('这道题解不开');
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
