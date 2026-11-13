import 'package:superxd/playground/puzzle_rules.dart';

// 逻辑网格推理（爱因斯坦谜题一类）：几个人各有几类属性（衣服、宠物、饮料、座位……），每类里每个值恰好属于一个人；
// 按线索推出完整的对应表。题面只存结构：人数、用了哪几类属性与哪几个值（都是属性池的下标）、每条线索的句式与参数，文字在对局页按结构生成。
// 人按座次叫甲乙丙丁戊（不用真实人名）；求解与出题都把「人」当作第 0 类，属性类依次是第 1 到第 K 类。

// 人名：按下标依次叫，发出后不改。
const logicGridPeople = ['甲', '乙', '丙', '丁', '戊'];

// 一类属性：列头的名字、说成句子时的动词（「养」猫、「喝」茶）与全部的值；ordered 的值有先后（座位从左到右），
// 只有题里有这样一类时才出「左边一位、挨着、左边」这几种线索。
class LogicGridKind {
  const LogicGridKind(this.name, this.verb, this.values, {this.ordered = false});
  final String name, verb;
  final List<String> values;
  final bool ordered;
}

// 属性池：题面按下标引用类与值，发出后只能在末尾追加（类追加在列表末尾，值追加在各自的列表末尾），不改、不删、不换顺序。
// 每类至少 logicGridMaxPeople 个值；有序的一类按先后排，题里只用前 N 个。
const logicGridKinds = [
  LogicGridKind('衣服', '穿', ['红衣', '黄衣', '蓝衣', '绿衣', '白衣', '黑衣']),
  LogicGridKind('宠物', '养', ['猫', '狗', '鱼', '鸟', '兔', '龟']),
  LogicGridKind('饮料', '喝', ['茶', '咖啡', '牛奶', '果汁', '汽水', '豆浆']),
  LogicGridKind('水果', '爱吃', ['苹果', '香蕉', '葡萄', '橙子', '桃子', '西瓜']),
  LogicGridKind('乐器', '学', ['钢琴', '吉他', '小提琴', '笛子', '架子鼓', '二胡']),
  LogicGridKind('运动', '爱', ['跑步', '游泳', '打篮球', '踢足球', '打羽毛球', '打乒乓球']),
  LogicGridKind('座位', '坐', ['1号位', '2号位', '3号位', '4号位', '5号位'], ordered: true),
];

// 外部输入的边界：人数（名字只有甲到戊）、属性类数与线索条数。
const logicGridMinPeople = 3;
const logicGridMaxPeople = 5;
const logicGridMinCategories = 2;
const logicGridMaxCategories = 4;
const logicGridMaxClues = 40;

// 句式：code 写进题面编码，发出后不改（加句式只往后加新 code）；arity 是引用的个数，seated 的要求题里有有序的一类（座位）。
enum LogicGridClueKind {
  // 「A 是 B」：两个引用是同一个人，如「甲养猫」「养猫的穿红衣」。两个引用不同类，类小的在前（人在最前）。
  same(0, 2),
  // 「A 不是 B」：两个引用不是同一个人，如「乙不喝茶」「养狗的不穿白衣」。写法同上。
  differ(1, 2),
  // 「A 要么是 B、要么是 C」：两样里恰好成立一样，如「养鱼的要么是丙、要么喝咖啡」。B、C 都和 A 不同类，B 在 C 前（先比类再比值）。
  either(2, 3),
  // 「A 坐在 B 左边一位」：A 的座位号正好比 B 小 1。A、B 都不是座位这一类，也不是同一个引用。
  leftOf(3, 2, seated: true),
  // 「A 挨着 B 坐」：座位号差 1。写法同上，A 在 B 前（先比类再比值）。
  nextTo(4, 2, seated: true),
  // 「A 坐在 B 左边（不一定挨着）」：A 的座位号比 B 小。写法同 leftOf。
  before(5, 2, seated: true);

  const LogicGridClueKind(this.code, this.arity, {this.seated = false});
  final int code, arity;
  final bool seated;

  static LogicGridClueKind? coded(int code) => values.where((kind) => kind.code == code).firstOrNull;
}

// 引用一个「人」或一个属性值：category 0 是人（value 是人的下标），category c（≥1）是题里第 c 类属性（value 是这一类里第几个值，0 起）。
class LogicGridRef {
  const LogicGridRef(this.category, this.value);
  final int category, value;

  @override
  bool operator ==(Object other) => other is LogicGridRef && other.category == category && other.value == value;

  @override
  int get hashCode => Object.hash(category, value);

  // 规范写法的先后：先比类再比值。
  bool before(LogicGridRef other) => category < other.category || category == other.category && value < other.value;
}

class LogicGridClue {
  const LogicGridClue(this.kind, this.refs);
  final LogicGridClueKind kind;
  final List<LogicGridRef> refs;
}

// 题里的一类属性：属性池里的哪一类，用了这一类的哪几个值（属性池下标，从小到大；有序的一类是 0 到 N−1）。
class LogicGridCategory {
  const LogicGridCategory(this.kind, this.values);
  final int kind;
  final List<int> values;

  LogicGridKind get pool => logicGridKinds[kind];
  String label(int value) => pool.values[values[value]];
}

class LogicGridPuzzle {
  const LogicGridPuzzle({required this.people, required this.categories, required this.clues});
  final int people;
  final List<LogicGridCategory> categories;
  final List<LogicGridClue> clues;

  // 有序的一类（座位）是第几类属性（0 起，不算人）；没有是 null。
  int? get seat {
    final index = categories.indexWhere((category) => category.pool.ordered);
    return index < 0 ? null : index;
  }
}

// 答案：answer[c][p] 是第 p 个人在第 c 类属性（0 起，不算人）里的值（这一类里第几个值）。

int _bits(int mask) {
  var count = 0;
  for (var rest = mask; rest != 0; rest &= rest - 1) {
    count++;
  }
  return count;
}

// 这条线索在 people 个人、categories 类属性、座位是第 seat 类（没有是 null）的题里是否合法：出题与解码共用这一处。
bool logicGridClueLegal(LogicGridClue clue, int people, int categories, int? seat) {
  final refs = clue.refs;
  if (refs.length != clue.kind.arity) return false;
  for (final ref in refs) {
    if (ref.category < 0 || ref.category > categories || ref.value < 0 || ref.value >= people) return false;
  }
  final first = refs[0], second = refs[1];
  bool seated(LogicGridRef ref) => seat != null && ref.category == seat + 1;
  return switch (clue.kind) {
    LogicGridClueKind.same || LogicGridClueKind.differ => first.category < second.category,
    LogicGridClueKind.either => first.category != second.category && first.category != refs[2].category && second.before(refs[2]),
    LogicGridClueKind.leftOf || LogicGridClueKind.before => seat != null && !seated(first) && !seated(second) && first != second,
    LogicGridClueKind.nextTo => seat != null && !seated(first) && !seated(second) && first.before(second),
  };
}

// 这条线索在一张完整的对应表下是否成立（answer 的形状与「每类是一一对应」由调用方保证）。
bool logicGridTruth(LogicGridPuzzle puzzle, LogicGridClue clue, List<List<int>> answer) {
  int who(LogicGridRef ref) => ref.category == 0 ? ref.value : answer[ref.category - 1].indexOf(ref.value);
  int seatOf(LogicGridRef ref) => answer[puzzle.seat!][who(ref)];
  final refs = clue.refs;
  return switch (clue.kind) {
    LogicGridClueKind.same => who(refs[0]) == who(refs[1]),
    LogicGridClueKind.differ => who(refs[0]) != who(refs[1]),
    LogicGridClueKind.either => (who(refs[0]) == who(refs[1])) != (who(refs[0]) == who(refs[2])),
    LogicGridClueKind.leftOf => seatOf(refs[0]) + 1 == seatOf(refs[1]),
    LogicGridClueKind.nextTo => (seatOf(refs[0]) - seatOf(refs[1])).abs() == 1,
    LogicGridClueKind.before => seatOf(refs[0]) < seatOf(refs[1]),
  };
}

// 一张填满的对应表里不成立的线索（下标从小到大）。对局页判错时只标这些线索，不给答案。
List<int> logicGridViolations(LogicGridPuzzle puzzle, List<List<int>> answer) => [
  for (final (index, clue) in puzzle.clues.indexed)
    if (!logicGridTruth(puzzle, clue, answer)) index,
];

// 推理过程（量法见 _Solver.reason）：rounds 是约束传播一共走了几轮（一轮 = 每行每列唯一、传递与每条线索各过一遍，有变化才算），
// trials 是推不动时靠「假设某人是某个值，推出矛盾就排除它」排除了几次，guess 是连这样也推不动、只能猜（出题不收）。
typedef LogicGridReasoning = ({int rounds, int trials, bool guess});

// 求解器：经典的排除表。把人当第 0 类、属性依次是第 1 到第 K 类，任意两类之间一张 N×N 的表：
// cand[at(i, j, a)] 是第 i 类第 a 个值还可能和第 j 类的哪些值是同一个人（按位），两个方向同步改。
// 约束传播为主：每张表每行每列唯一（一行只剩一个就从别的行划掉它）；传递（a 可能的 b 都和 c 不是同一个人，a 就不是 c）；
// 每条线索直接定下或排除（座位类线索在「某值 × 座位」那一行上移位求交）；推到不动为止，推不动再试探。
class _Solver {
  _Solver(this.puzzle)
    : people = puzzle.people,
      size = puzzle.categories.length + 1,
      seat = puzzle.seat == null ? null : puzzle.seat! + 1,
      full = (1 << puzzle.people) - 1;
  final LogicGridPuzzle puzzle;
  // size 含人这一类；seat 是座位这一类的下标（含人这一类，所以从 1 起），没有是 null。
  final int people, size, full;
  final int? seat;
  var _changed = false;
  // 数解最多搜几个节点（出题用，超了就不要这一道；节点数与搜索顺序都是确定的，换语言也逐位复现），null 是不限。
  int? budget;
  var _nodes = 0;
  bool get exhausted => budget != null && _nodes > budget!;

  int at(int from, int to, int value) => (from * size + to) * people + value;

  // 一开始什么都可能；同一类对自己的那张表只有对角线（自己就是自己），数解挑格子时不会挑到它。
  List<int> start() => [
    for (var from = 0; from < size; from++)
      for (var to = 0; to < size; to++)
        for (var value = 0; value < people; value++) from == to ? 1 << value : full,
  ];

  // 第 from 类第 value 个值只留下 mask 里的第 to 类的值，对面那张表同步划掉；有一行没了候选就是矛盾，返回假。
  bool keep(List<int> cand, int from, int value, int to, int mask) {
    final index = at(from, to, value), row = cand[index];
    final removed = row & ~mask;
    if (removed == 0) return true;
    cand[index] = row & mask;
    _changed = true;
    if (cand[index] == 0) return false;
    for (var rest = removed; rest != 0; rest &= rest - 1) {
      final mirror = at(to, from, (rest & -rest).bitLength - 1);
      cand[mirror] &= ~(1 << value);
      if (cand[mirror] == 0) return false;
    }
    return true;
  }

  int row(List<int> cand, LogicGridRef ref, int to) => cand[at(ref.category, to, ref.value)];
  bool possible(List<int> cand, LogicGridRef first, LogicGridRef second) => row(cand, first, second.category) >> second.value & 1 == 1;
  bool certain(List<int> cand, LogicGridRef first, LogicGridRef second) => row(cand, first, second.category) == 1 << second.value;
  bool join(List<int> cand, LogicGridRef first, LogicGridRef second) => keep(cand, first.category, first.value, second.category, 1 << second.value);
  bool part(List<int> cand, LogicGridRef first, LogicGridRef second) => keep(cand, first.category, first.value, second.category, full & ~(1 << second.value));

  static int _shift(int mask, int by) => by >= 0 ? mask << by : mask >> -by;

  // 用一条线索定下或排除。
  bool apply(List<int> cand, LogicGridClue clue) {
    final refs = clue.refs;
    final first = refs[0], second = refs[1];
    switch (clue.kind) {
      case LogicGridClueKind.same:
        return join(cand, first, second);
      case LogicGridClueKind.differ:
        return part(cand, first, second);
      case LogicGridClueKind.either:
        final third = refs[2];
        // 同一类的两个值：A 只能是其中之一（不会两个都是）。
        if (second.category == third.category) return keep(cand, first.category, first.value, second.category, 1 << second.value | 1 << third.value);
        // 不同类：B、C 若是同一个人，A 要么两样都是、要么都不是，所以 B 不是 C；一样不可能就是另一样，一样确定就排除另一样。
        if (!part(cand, second, third)) return false;
        if (!possible(cand, first, second)) return join(cand, first, third);
        if (!possible(cand, first, third)) return join(cand, first, second);
        if (certain(cand, first, second)) return part(cand, first, third);
        return !certain(cand, first, third) || part(cand, first, second);
      case LogicGridClueKind.leftOf || LogicGridClueKind.nextTo || LogicGridClueKind.before:
        final seats = seat!;
        // 座位不同所以不是同一个人；再按两人座位的关系互相收窄「这个值坐哪」。
        if (first.category != second.category && !part(cand, first, second)) return false;
        final (from, to) = (row(cand, first, seats), row(cand, second, seats));
        final (fromMask, toMask) = switch (clue.kind) {
          LogicGridClueKind.leftOf => (_shift(to, -1), _shift(from, 1)),
          LogicGridClueKind.nextTo => (_shift(to, -1) | _shift(to, 1), _shift(from, -1) | _shift(from, 1)),
          // 左边（不一定挨着）：A 比 B 最右的可能还靠左，B 比 A 最左的可能还靠右。
          _ => ((1 << (to.bitLength - 1)) - 1, full & ~((1 << ((from & -from).bitLength)) - 1)),
        };
        return keep(cand, first.category, first.value, seats, fromMask) && keep(cand, second.category, second.value, seats, toMask);
    }
  }

  // 每张表每行每列唯一：一行只剩一个就从同一张表的别的行划掉它（对面那张表上就是「一列只剩一个」）。
  bool unique(List<int> cand) {
    for (var from = 0; from < size; from++) {
      for (var to = 0; to < size; to++) {
        if (from == to) continue;
        for (var value = 0; value < people; value++) {
          final known = cand[at(from, to, value)];
          if (known & (known - 1) != 0) continue;
          for (var other = 0; other < people; other++) {
            if (other != value && !keep(cand, from, other, to, ~known)) return false;
          }
        }
      }
    }
    return true;
  }

  // 传递：第 from 类第 value 个值和第 to 类的值能是同一个人，必须经过第三类某个它可能是的值也能连上。
  bool transitive(List<int> cand) {
    for (var from = 0; from < size; from++) {
      for (var to = 0; to < size; to++) {
        if (from == to) continue;
        for (var via = 0; via < size; via++) {
          if (via == from || via == to) continue;
          for (var value = 0; value < people; value++) {
            var reach = 0;
            for (var rest = cand[at(from, via, value)]; rest != 0; rest &= rest - 1) {
              reach |= cand[at(via, to, (rest & -rest).bitLength - 1)];
            }
            if (!keep(cand, from, value, to, reach)) return false;
          }
        }
      }
    }
    return true;
  }

  // 推到不动为止，返回有变化的轮数；矛盾返回 −1。
  int propagate(List<int> cand) {
    var rounds = 0;
    while (true) {
      _changed = false;
      if (!unique(cand) || !transitive(cand)) return -1;
      for (final clue in puzzle.clues) {
        if (!apply(cand, clue)) return -1;
      }
      if (!_changed) return rounds;
      rounds++;
    }
  }

  // 人与各类属性的那几张表（第 p 个人在第 c 类里还可能的值），对局页的表格只有这一部分。
  bool done(List<int> cand) {
    for (var category = 1; category < size; category++) {
      for (var person = 0; person < people; person++) {
        final known = cand[at(0, category, person)];
        if (known & (known - 1) != 0) return false;
      }
    }
    return true;
  }

  List<List<int>> options(List<int> cand) => [
    for (var category = 1; category < size; category++) [for (var person = 0; person < people; person++) cand[at(0, category, person)]],
  ];

  // 数解：传播后在所有表里挑候选最少的一格逐个试（座位类线索多时，先定「某值坐哪」比先定「某人是谁」剪得快），数到 limit 个就停；
  // 人与属性的表填满后按线索逐条核对。
  int count(List<int> cand, int limit) {
    // 超了上限就当已经数够，尽快退出；调用方看 exhausted。
    if (budget != null && ++_nodes > budget!) return limit;
    if (propagate(cand) < 0) return 0;
    if (done(cand)) return logicGridViolations(puzzle, [for (final row in options(cand)) [for (final value in row) value.bitLength - 1]]).isEmpty ? 1 : 0;
    var (best, fewest) = (-1, people + 1);
    for (var index = 0; index < cand.length; index++) {
      final options = _bits(cand[index]);
      if (options > 1 && options < fewest) (best, fewest) = (index, options);
    }
    final (from, to, value) = (best ~/ people ~/ size, best ~/ people % size, best % people);
    var total = 0;
    for (var rest = cand[best]; rest != 0 && total < limit; rest &= rest - 1) {
      final branch = List.of(cand);
      if (!keep(branch, from, value, to, rest & -rest)) continue;
      total += count(branch, limit - total);
    }
    return total;
  }

  // 模拟人推：先约束传播到推不动；还没填满就在人与属性的表里按顺序找一个「假设他就是这个值、一推就矛盾」的候选排除掉
  // （一次试探，对局页的表格上就能这样标），再接着传播；找不到这样的候选就只能猜（guess 为真，出题不收）。
  // 试探超过 maxTrials 次就不再往下推（出题时这一道已经不要了），返回时 trials 比 maxTrials 大。
  LogicGridReasoning reason({int maxTrials = 1 << 30}) {
    final cand = start();
    var rounds = propagate(cand), trials = 0;
    if (rounds < 0) return (rounds: 0, trials: 0, guess: true);
    search:
    while (!done(cand)) {
      for (var category = 1; category < size; category++) {
        for (var person = 0; person < people; person++) {
          final known = cand[at(0, category, person)];
          if (known & (known - 1) == 0) continue;
          for (var rest = known; rest != 0; rest &= rest - 1) {
            final bit = rest & -rest;
            final branch = List.of(cand);
            if (keep(branch, 0, person, category, bit) && propagate(branch) >= 0) continue;
            if (++trials > maxTrials) return (rounds: rounds, trials: trials, guess: false);
            if (!keep(cand, 0, person, category, full & ~bit)) break search;
            final more = propagate(cand);
            if (more < 0) break search;
            rounds += more;
            continue search;
          }
        }
      }
      return (rounds: rounds, trials: trials, guess: true);
    }
    return (rounds: rounds, trials: trials, guess: !done(cand));
  }
}

// 约束传播一遍（不试探）：返回推完时每个人在每类属性里还可能的值（options[c][p]，按位），矛盾返回 null。
List<List<int>>? logicGridPropagate(LogicGridPuzzle puzzle) {
  final solver = _Solver(puzzle);
  final cand = solver.start();
  return solver.propagate(cand) < 0 ? null : solver.options(cand);
}

// 解的个数，数到 limit 个就停（出题与解码只关心是不是恰好 1 个）。
int logicGridCount(LogicGridPuzzle puzzle, {int limit = 2}) {
  final solver = _Solver(puzzle);
  return solver.count(solver.start(), limit);
}

LogicGridReasoning logicGridReasoning(LogicGridPuzzle puzzle) => _Solver(puzzle).reason();

// 每档的出题方案：人数、属性类数、有没有座位、各句式的抽取权重（整数，换语言能逐位复现）、这一档新加的句式至少几条、
// 试探次数的区间与出几道候选（留推理最深的）。
class _Plan {
  const _Plan({required this.people, required this.categories, required this.weights, this.seat = false, this.fresh = const {}, this.minFresh = 0, this.trials = (0, 0), this.candidates = 1});
  final int people, categories;
  final bool seat;
  final Map<LogicGridClueKind, int> weights;
  final Set<LogicGridClueKind> fresh;
  final int minFresh;
  final (int, int) trials;
  final int candidates;
}

class LogicGridRules extends PuzzleRules<LogicGridPuzzle, List<List<int>>> {
  const LogicGridRules();

  static const _basic = {LogicGridClueKind.same: 2, LogicGridClueKind.differ: 3};
  static const _seated = {LogicGridClueKind.leftOf, LogicGridClueKind.nextTo, LogicGridClueKind.before};

  // 入门 3 人 2 类、简单 3 人 3 类只有「是 / 不是」，不用试探；普通 4 人 3 类加「要么…要么…」，最多试探一次；
  // 困难 4 人 4 类、专家 5 人 4 类带座位，加「左边一位、挨着」，专家再加「左边（不一定挨着）」，试探次数有上限、出几道留最深的。
  static const _plans = {
    PuzzleTier.entry: _Plan(people: 3, categories: 2, weights: _basic),
    PuzzleTier.easy: _Plan(people: 3, categories: 3, weights: _basic),
    PuzzleTier.normal: _Plan(people: 4, categories: 3, weights: {..._basic, LogicGridClueKind.either: 3}, fresh: {LogicGridClueKind.either}, minFresh: 1, trials: (0, 1), candidates: 2),
    PuzzleTier.hard: _Plan(
      people: 4,
      categories: 4,
      seat: true,
      weights: {..._basic, LogicGridClueKind.either: 2, LogicGridClueKind.leftOf: 3, LogicGridClueKind.nextTo: 3},
      fresh: _seated,
      minFresh: 1,
      trials: (0, 3),
      candidates: 2,
    ),
    PuzzleTier.expert: _Plan(
      people: 5,
      categories: 4,
      seat: true,
      weights: {..._basic, LogicGridClueKind.either: 2, LogicGridClueKind.leftOf: 3, LogicGridClueKind.nextTo: 3, LogicGridClueKind.before: 2},
      fresh: _seated,
      minFresh: 2,
      trials: (0, 4),
      candidates: 2,
    ),
  };

  // 出题：随机挑属性类与值、随机定一张对应表作答案；按权重抽和答案相符的线索，一条条加到约束传播就能填满（所以唯一）；
  // 再按随机顺序逐条试着拿掉，拿掉后仍然唯一就删（留下的每条都少不了）；最后看这一档的句式与推理要求，不合就整道重来。
  // 高档出几道候选，留推理最深的（试探多的优先，再比传播轮数）。
  @override
  PuzzleDraw<LogicGridPuzzle, List<List<int>>> generate(int seed, PuzzleTier tier) {
    final plan = _plans[tier]!;
    final random = PuzzleRandom(seed);
    PuzzleDraw<LogicGridPuzzle, List<List<int>>>? best;
    var bestScore = -1;
    for (var made = 0; made < plan.candidates; made++) {
      final (draw, reasoning) = _draw(plan, random);
      final score = reasoning.trials * 1000 + reasoning.rounds;
      if (score > bestScore) (best, bestScore) = (draw, score);
    }
    return best!;
  }

  static (PuzzleDraw<LogicGridPuzzle, List<List<int>>>, LogicGridReasoning) _draw(_Plan plan, PuzzleRandom random) {
    final people = plan.people;
    while (true) {
      final kinds = [for (final (index, kind) in logicGridKinds.indexed) if (!kind.ordered) index];
      random.shuffle(kinds);
      final picked = kinds.take(plan.seat ? plan.categories - 1 : plan.categories).toList()..sort();
      final categories = [
        for (final kind in picked) LogicGridCategory(kind, List.unmodifiable(_choose(random, logicGridKinds[kind].values.length, people))),
        if (plan.seat) LogicGridCategory(logicGridKinds.indexWhere((kind) => kind.ordered), List.unmodifiable([for (var value = 0; value < people; value++) value])),
      ];
      final answer = <List<int>>[];
      for (var category = 0; category < categories.length; category++) {
        final row = [for (var value = 0; value < people; value++) value];
        random.shuffle(row);
        answer.add(row);
      }
      final clues = <LogicGridClue>[];
      LogicGridPuzzle puzzleOf(List<LogicGridClue> clues) => LogicGridPuzzle(people: people, categories: categories, clues: clues);
      // 加线索时只做约束传播（接着上一次的排除表推，线索只增不减，结果同从头推）：传播就能填满的题一定唯一；
      // 不在这里数解，线索少时数解要搜很大一片。
      final solver = _Solver(puzzleOf(clues));
      final cand = solver.start();
      while (clues.length < logicGridMaxClues && !solver.done(cand)) {
        clues.add(_clue(plan, random, categories, answer));
        solver.propagate(cand);
      }
      if (!solver.done(cand)) continue;
      // 按随机顺序逐条试着拿掉。
      final order = [for (var index = 0; index < clues.length; index++) index];
      random.shuffle(order);
      final kept = List<LogicGridClue?>.of(clues);
      var exhausted = false;
      for (final index in order) {
        final clue = kept[index];
        kept[index] = null;
        final unique = _unique(puzzleOf(kept.nonNulls.toList()));
        if (unique == null) {
          exhausted = true;
          break;
        }
        if (!unique) kept[index] = clue;
      }
      if (exhausted) continue;
      final finalClues = kept.nonNulls.toList();
      if (finalClues.where((clue) => plan.fresh.contains(clue.kind)).length < plan.minFresh) continue;
      random.shuffle(finalClues);
      final puzzle = puzzleOf(List.unmodifiable(finalClues));
      final (minTrials, maxTrials) = plan.trials;
      final reasoning = _Solver(puzzle).reason(maxTrials: maxTrials);
      if (reasoning.guess || reasoning.trials < minTrials || reasoning.trials > maxTrials) continue;
      return (PuzzleDraw(puzzle, List<List<int>>.unmodifiable([for (final row in answer) List<int>.unmodifiable(row)])), reasoning);
    }
  }

  // 唯一：约束传播就能填满的一定唯一（快），推不满再数解；数解超过节点上限返回 null（这一道不要了）。
  static bool? _unique(LogicGridPuzzle puzzle) {
    final solver = _Solver(puzzle);
    final cand = solver.start();
    if (solver.propagate(cand) >= 0 && solver.done(cand)) return true;
    solver.budget = _budget;
    final unique = solver.count(solver.start(), 2) == 1;
    return solver.exhausted ? null : unique;
  }

  // 出题时数解的节点上限：线索太弱、要搜很大一片才能确认唯一的题，人推起来也只能硬猜，不要。
  static const _budget = 600;

  // 从 0 到 total − 1 里随机挑 count 个，从小到大。
  static List<int> _choose(PuzzleRandom random, int total, int count) {
    final all = [for (var index = 0; index < total; index++) index];
    random.shuffle(all);
    return all.take(count).toList()..sort();
  }

  // 按权重抽一种句式，再随机抽一条和答案相符的、合法的这种线索。
  static LogicGridClue _clue(_Plan plan, PuzzleRandom random, List<LogicGridCategory> categories, List<List<int>> answer) {
    final people = plan.people, size = categories.length;
    final seat = plan.seat ? size - 1 : null;
    var roll = random.nextInt(plan.weights.values.fold(0, (total, weight) => total + weight));
    final kind = plan.weights.keys.firstWhere((kind) => (roll -= plan.weights[kind]!) < 0);
    LogicGridRef ref(int category, int person) => LogicGridRef(category, category == 0 ? person : answer[category - 1][person]);
    // 两个不同的类（0 是人）。
    (int, int) twoCategories(List<int> pool) {
      final first = random.pick(pool);
      final second = random.pick([for (final category in pool) if (category != first) category]);
      return (first, second);
    }

    final everyone = [for (var category = 0; category <= size; category++) category];
    final unseated = [for (final category in everyone) if (category != (seat ?? -2) + 1) category];
    final person = random.nextInt(people);
    final other = random.pick([for (var index = 0; index < people; index++) if (index != person) index]);
    switch (kind) {
      case LogicGridClueKind.same:
        final (first, second) = twoCategories(everyone);
        return LogicGridClue(kind, first < second ? [ref(first, person), ref(second, person)] : [ref(second, person), ref(first, person)]);
      case LogicGridClueKind.differ:
        final (first, second) = twoCategories(everyone);
        return LogicGridClue(kind, first < second ? [ref(first, person), ref(second, other)] : [ref(second, other), ref(first, person)]);
      case LogicGridClueKind.either:
        // A 和 B 是同一个人（成立的那样），C 是别人的（不成立的那样）。
        final subject = random.pick(everyone);
        final rest = [for (final category in everyone) if (category != subject) category];
        final (yes, no) = (ref(random.pick(rest), person), ref(random.pick(rest), other));
        return LogicGridClue(kind, [ref(subject, person), if (yes.before(no)) ...[yes, no] else ...[no, yes]]);
      case LogicGridClueKind.leftOf || LogicGridClueKind.nextTo || LogicGridClueKind.before:
        final seats = answer[seat!];
        // 先挑座位（左边那个人的座位与右边那个人的座位），再看是谁。
        final from = random.nextInt(people - 1);
        final to = kind == LogicGridClueKind.before ? from + 1 + random.nextInt(people - 1 - from) : from + 1;
        final (left, right) = (seats.indexOf(from), seats.indexOf(to));
        final (first, second) = (ref(random.pick(unseated), left), ref(random.pick(unseated), right));
        if (kind == LogicGridClueKind.nextTo && second.before(first)) return LogicGridClue(kind, [second, first]);
        return LogicGridClue(kind, [first, second]);
    }
  }

  // 按规则判：每类都是一一对应，且每条线索都成立。题目保证唯一，所以等价于答对，但不和参考解比。
  @override
  bool solved(LogicGridPuzzle puzzle, List<List<int>> answer) {
    if (answer.length != puzzle.categories.length) return false;
    for (final row in answer) {
      if (row.length != puzzle.people || row.toSet().length != puzzle.people || row.any((value) => value < 0 || value >= puzzle.people)) return false;
    }
    return logicGridViolations(puzzle, answer).isEmpty;
  }

  // 难度分口径：以规模为主，基础分 2 ×（人数 − 3）+ 2 ×（属性类数 − 2）+ 1（3 人 2 类 1 分、3 人 3 类 3、4 人 3 类 5、4 人 4 类 7、5 人 4 类 9）；
  // 再看推理过程（logicGridReasoning）：要试探才推得下去，或约束传播的轮数达到「人数 + 属性类数 − 2」，再加 1 分。
  // 所以同档的题最多差 1 分、下一档最低分高过上一档最高分：入门 1–2、简单 3–4、普通 5–6、困难 7–8、专家 9–10。
  // 不是唯一解的题面不会出、也解码不进来，按 10 分算。
  @override
  int difficulty(LogicGridPuzzle puzzle) {
    if (logicGridCount(puzzle) != 1) return 10;
    final reasoning = logicGridReasoning(puzzle);
    final size = puzzle.categories.length;
    final deep = reasoning.trials > 0 || reasoning.rounds >= puzzle.people + size - 2;
    return (2 * (puzzle.people - 3) + 2 * (size - 2) + 1 + (deep ? 1 : 0)).clamp(1, 10);
  }

  // 题面编成 {'people': N, 'categories': [[属性池的类, [值…]], …], 'clues': [[句式 code, 类, 值, 类, 值, …], …]}。
  @override
  Object encodePuzzle(LogicGridPuzzle puzzle) => {
    'people': puzzle.people,
    'categories': [
      for (final category in puzzle.categories) [category.kind, category.values],
    ],
    'clues': [
      for (final clue in puzzle.clues) [clue.kind.code, for (final ref in clue.refs) ...[ref.category, ref.value]],
    ],
  };

  @override
  LogicGridPuzzle decodePuzzle(Object? json) {
    final people = puzzleInt(json, 'people', min: logicGridMinPeople, max: logicGridMaxPeople);
    final rawCategories = (json as Map)['categories'];
    if (rawCategories is! List || rawCategories.length < logicGridMinCategories || rawCategories.length > logicGridMaxCategories) throw const FormatException('属性类数不合法');
    final categories = [for (final raw in rawCategories) _decodeCategory(raw, people)];
    if (categories.map((category) => category.kind).toSet().length != categories.length) throw const FormatException('属性类重复');
    if (categories.where((category) => category.pool.ordered).length > 1) throw const FormatException('有序的属性类不止一个');
    final rawClues = json['clues'];
    if (rawClues is! List || rawClues.isEmpty || rawClues.length > logicGridMaxClues) throw const FormatException('线索条数不合法');
    final seat = categories.indexWhere((category) => category.pool.ordered);
    final clues = [for (final raw in rawClues) _decodeClue(raw, people, categories.length, seat < 0 ? null : seat)];
    final puzzle = LogicGridPuzzle(people: people, categories: List.unmodifiable(categories), clues: List.unmodifiable(clues));
    // 没有解、或不止一个解的不是题（题库里不该有）。
    if (logicGridCount(puzzle) != 1) throw const FormatException('题目不是唯一解');
    return puzzle;
  }

  static LogicGridCategory _decodeCategory(Object? raw, int people) {
    if (raw is! List || raw.length != 2) throw const FormatException('属性类不合法');
    final kind = raw[0];
    if (kind is! int || kind < 0 || kind >= logicGridKinds.length) throw const FormatException('属性类不合法');
    final pool = logicGridKinds[kind];
    final values = puzzleInts(raw[1], maxLength: people, min: 0, max: pool.values.length - 1);
    // 值要从小到大、不重复、正好 N 个；有序的一类只用前 N 个。
    if (values.length != people) throw const FormatException('属性值不合法');
    for (var index = 0; index < people; index++) {
      if (pool.ordered ? values[index] != index : index > 0 && values[index] <= values[index - 1]) throw const FormatException('属性值不合法');
    }
    return LogicGridCategory(kind, List.unmodifiable(values));
  }

  static LogicGridClue _decodeClue(Object? raw, int people, int categories, int? seat) {
    // 句式 code、类与值共用一个宽松上限，code 由 coded 认，参数范围由 logicGridClueLegal 核。
    final parts = puzzleInts(raw, maxLength: 7, min: 0, max: 15);
    final kind = parts.isEmpty ? null : LogicGridClueKind.coded(parts.first);
    if (kind == null || parts.length != 1 + 2 * kind.arity) throw const FormatException('句式不合法');
    final clue = LogicGridClue(kind, List.unmodifiable([for (var index = 0; index < kind.arity; index++) LogicGridRef(parts[1 + 2 * index], parts[2 + 2 * index])]));
    if (!logicGridClueLegal(clue, people, categories, seat)) throw const FormatException('线索的参数不合法');
    return clue;
  }

  // 答案编成每类一个列表：第 p 项是第 p 个人在这一类里的值。
  @override
  Object encodeAnswer(List<List<int>> answer) => [for (final row in answer) List.of(row)];

  @override
  List<List<int>> decodeAnswer(Object? json) {
    if (json is! List || json.isEmpty || json.length > logicGridMaxCategories) throw const FormatException('答案不合法');
    final rows = [for (final row in json) puzzleInts(row, maxLength: logicGridMaxPeople, min: 0, max: logicGridMaxPeople - 1)];
    if (rows.any((row) => row.length < logicGridMinPeople || row.length != rows.first.length)) throw const FormatException('答案不合法');
    return List.unmodifiable([for (final row in rows) List<int>.unmodifiable(row)]);
  }
}
