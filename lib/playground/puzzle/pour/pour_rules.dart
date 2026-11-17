import 'dart:math' as math;

import 'package:forge2d/forge2d.dart';

import 'package:superxd/playground/puzzle_rules.dart';

// 画线入杯：上方几个小球、下方一只杯子、中间几块固定的障碍（有的题还有一根转动的风车杆）。玩家用有限的墨水画线（松手后成为固定不动的刚体），
// 点「放球」后小球在重力下落，全部滚进杯子并停稳才算过关；用墨越省星越多（pourStars）。
// 物理模拟用 forge2d（Box2D v3 的 Dart 绑定，原生库经 FFI 调用，不依赖 Flutter），规则与页面跑的是同一份 PourSimulation。
// 坐标是整数单位，1 单位当 1 厘米：棋盘 pourWidth × pourHeight，y 朝下（重力也朝下）；送进物理世界时除以 100 换成米（Box2D 按米调参）。
// 判定的稳定性：模拟是固定步长、固定子步数、按同一顺序建物体的确定性计算（风车是匀速转动的运动体，转角只看过了几步），同一台设备上同一道题同一种画法每次结果一样；
// 换平台（arm64 与 x64、不同编译器）浮点细节可能有微小差异、边缘情况会走向不同结果，所以这个游戏只进自由模式（challengeable 为假），
// 不承诺跨设备逐位复现。出题时只有坐标取整等整数运算用 PuzzleRandom，验证可解靠同一份模拟。
// 题型（PourKind）有十类，每档从自己的几类里按种子挑一类（_tiers），换种子换的是结构，不只是位置。

const pourWidth = 600, pourHeight = 800;
const pourBallRadius = 18;
// 线的半宽（画出来的线宽是它的两倍）。
const pourLineRadius = 5;
const pourCupWall = 12;
// 线离球的起点至少这么远（球半径加线半径再留一点），否则放球那一刻球就压在线上。
const pourBallClearance = pourBallRadius + pourLineRadius + 6;
const pourMaxBalls = 3, pourMaxBlocks = 8, pourMaxSpinners = 2, pourMaxInk = 3000;
// 风车杆的半厚（杆是两头圆的长条）与中间轴的半径（轴跟着杆转，是圆的，所以挡在那儿不动）。
const pourSpinnerHalf = 7, pourSpinnerHub = 14;
// 答案的上限：笔数与总点数（页面每走 pourMinSegment 记一个点，满墨水也远用不到）。
const pourMaxStrokes = 20, pourMaxPoints = 800;
const pourMinSegment = 8;
// 模拟的固定步长与最长时长（12 秒）；页面每帧按真实流逝的时间推进若干步。
const pourStep = 1 / 60;
const pourMaxSteps = 60 * 12;
// 星级：用墨不超过参考线长的 1.25 倍 3 星、不超过 1.75 倍 2 星，其余 1 星（同类游戏按用墨给星的常见做法）。
const pourThreeStars = 1.25, pourTwoStars = 1.75;
// 墨水比参考线长的这个倍数还少算「墨水紧」（难易分加 1；这时至少 2 星）。
const pourTight = 1.6;

// 题型（code 发出后不改）：base 是这一类在难易分里的起点，structure 是这一类自带几块固定障碍（多出来的算随机障碍），balls 是这一类至少几个球。
enum PourKind {
  // 直坡：一段斜坡把球引到杯口近侧。
  ramp(0, base: 1, structure: 0),
  // 两笔折返：球在杯子正上方、挡板拦着，先往外引过挡板外沿，再用第二笔接住、从挡板下面引回杯口。
  switchback(1, base: 8, structure: 1),
  // 漏斗：杯口上方一对张开的斜板，把球送进漏斗口就会滑进杯里。
  funnel(2, base: 1, structure: 2),
  // 缓冲接住：球顺着陡滑板冲出去会飞过杯子，要在杯子远侧挡一下让它落进去。
  catcher(3, base: 2, structure: 1),
  // 搭桥：两段固定斜板中间断开，球会掉进缺口，要补上一段桥。
  bridge(4, base: 3, structure: 2),
  // 借板回头：球下方的斜板把球往外送（板也挡住了杯口），要在板的末端接住、从板底下引回杯口。
  uturn(5, base: 5, structure: 1),
  // 绕障：直坡的路上有一块障碍，线要折一下从它上面或下面绕过去。
  detour(6, base: 5, structure: 1),
  // 两边来球：杯子两边都有球，每边各画一笔。
  pair(7, base: 5, structure: 0, balls: 2),
  // 窄口：杯口盖着两块板、只留一道窄缝，球滚得太快会越过缝，要在缝的远边挡一下。
  slot(8, base: 7, structure: 2),
  // 风车：直坡的路上有一根匀速转动的杆，线要折一下绕开它扫过的范围。
  windmill(9, base: 7, structure: 0);

  const PourKind(this.code, {required this.base, required this.structure, this.balls = 1});
  final int code, base, structure, balls;

  static PourKind? coded(int code) => values.where((kind) => kind.code == code).firstOrNull;
}

// 一块固定的障碍：中心、半宽、半高与转角（度，y 朝下所以正角是顺时针）。
class PourBlock {
  const PourBlock({required this.x, required this.y, required this.halfWidth, required this.halfHeight, required this.angle});
  final int x, y, halfWidth, halfHeight, angle;

  // 四个角，按 x、y 交替排（顺序绕一圈；前两个是上沿：转角在 ±90 度以内时它朝上）。
  List<double> get corners {
    final radians = angle * math.pi / 180, cos = math.cos(radians), sin = math.sin(radians);
    return [
      for (final (dx, dy) in [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]) ...[x + dx * cos - dy * sin, y + dx * sin + dy * cos],
    ];
  }
}

// 一根转动的杆（风车）：中心、半长（扫过的圆的半径）、转速（度每秒，正的是顺时针）与开始的转角（度）。
// 放球那一刻从开始的转角匀速转，没放球时停在开始的转角。
class PourSpinner {
  const PourSpinner({required this.x, required this.y, required this.halfLength, required this.speed, required this.angle});
  final int x, y, halfLength, speed, angle;
}

// 杯子：杯口中线 x、杯底内面的 y、杯内宽与杯内深；杯壁厚 pourCupWall，杯底也是这么厚。
class PourCup {
  const PourCup({required this.x, required this.bottom, required this.width, required this.depth});
  final int x, bottom, width, depth;

  int get top => bottom - depth;
  double get left => x - width / 2;
  double get right => x + width / 2;

  // 三块杯壁（左、右、底），每块是 left、top、right、bottom。
  List<(double, double, double, double)> get walls => [
    (left - pourCupWall, top.toDouble(), left, bottom + pourCupWall.toDouble()),
    (right, top.toDouble(), right + pourCupWall, bottom + pourCupWall.toDouble()),
    (left, bottom.toDouble(), right, bottom + pourCupWall.toDouble()),
  ];

  // 球心在杯里：在两壁之间、低于杯口。
  bool holds(double x, double y) => x > left && x < right && y > top && y < bottom;
}

class PourPuzzle {
  const PourPuzzle({required this.kind, required this.balls, required this.cup, required this.blocks, this.spinners = const [], required this.ink, required this.par});
  final PourKind kind;
  // 球的起点，按 x、y 交替排。
  final List<int> balls;
  final PourCup cup;
  final List<PourBlock> blocks;
  final List<PourSpinner> spinners;
  // 墨水：所有线的总长上限（单位）。
  final int ink;
  // 参考线的总长（向上取整），星级按它算。
  final int par;

  int get ballCount => balls.length ~/ 2;
}

// 一笔线是一串点，按 x、y 交替排；答案是若干笔。
double pourStrokeLength(List<int> stroke) {
  var length = 0.0;
  for (var index = 2; index + 1 < stroke.length; index += 2) {
    length += _distance(stroke[index - 2], stroke[index - 1], stroke[index], stroke[index + 1]);
  }
  return length;
}

double pourInkUsed(List<List<int>> strokes) => strokes.fold(0.0, (sum, stroke) => sum + pourStrokeLength(stroke));

// 用掉这么多墨水能得几颗星（1–3）：只看用墨，进没进杯由判定管。
int pourStarsFor(PourPuzzle puzzle, double used) => used <= puzzle.par * pourThreeStars ? 3 : (used <= puzzle.par * pourTwoStars ? 2 : 1);

int pourStars(PourPuzzle puzzle, List<List<int>> strokes) => pourStarsFor(puzzle, pourInkUsed(strokes));

// 一段线离每个球的起点都够远（页面画线时逐段查，判定时整份答案再查一遍）。
bool pourSegmentClear(PourPuzzle puzzle, int x1, int y1, int x2, int y2) {
  for (var index = 0; index < puzzle.balls.length; index += 2) {
    if (_pointSegment(puzzle.balls[index].toDouble(), puzzle.balls[index + 1].toDouble(), x1.toDouble(), y1.toDouble(), x2.toDouble(), y2.toDouble()) < pourBallClearance) return false;
  }
  return true;
}

// 答案合规：笔数、点数、坐标在棋盘内，每笔至少两个点，总长不超过墨水，每段都不压球的起点。
bool pourAnswerValid(PourPuzzle puzzle, List<List<int>> strokes) {
  if (strokes.length > pourMaxStrokes || strokes.fold(0, (sum, stroke) => sum + stroke.length ~/ 2) > pourMaxPoints) return false;
  for (final stroke in strokes) {
    if (stroke.length < 4 || stroke.length.isOdd) return false;
    for (var index = 0; index < stroke.length; index += 2) {
      if (stroke[index] < 0 || stroke[index] > pourWidth || stroke[index + 1] < 0 || stroke[index + 1] > pourHeight) return false;
      if (index >= 2 && !pourSegmentClear(puzzle, stroke[index - 2], stroke[index - 1], stroke[index], stroke[index + 1])) return false;
    }
  }
  return pourInkUsed(strokes) <= puzzle.ink;
}

enum PourOutcome { running, won, lost }

// 一次放球的模拟：建好世界后由调用方一步步推（页面按帧推、判定一口气推完），用完必须 dispose（原生世界最多同时 128 个）。
// 胜负：所有球心都在杯里、并且都几乎不动，连续 _settleSteps 步就算进杯停稳；有球掉出棋盘、所有球都停住却没全进杯、或到 pourMaxSteps 都算没进。
class PourSimulation {
  PourSimulation(this.puzzle, List<List<int>> strokes) : _world = World(definition: WorldDef(gravity: Vector2(0, _gravity))) {
    for (var index = 0; index < puzzle.balls.length; index += 2) {
      _balls.add(_world.createBody(BodyDef(type: BodyType.dynamic, position: _meters(puzzle.balls[index], puzzle.balls[index + 1]), linearDamping: .05, angularDamping: .1))
        ..createShape(Circle(radius: pourBallRadius / 100), ShapeDef(material: SurfaceMaterial(friction: .5, restitution: .15, rollingResistance: .04))));
    }
    final cup = _world.createBody(BodyDef());
    for (final (left, top, right, bottom) in puzzle.cup.walls) {
      cup.createShape(Polygon.offsetBox((right - left) / 200, (bottom - top) / 200, center: Vector2((left + right) / 200, (top + bottom) / 200)), ShapeDef(material: SurfaceMaterial(friction: .8)));
    }
    for (final block in puzzle.blocks) {
      // 障碍的角磨圆一点（外沿尺寸不变），球滚过棱角时不会被卡住或弹飞。
      const round = 3;
      _world.createBody(BodyDef(position: _meters(block.x, block.y), rotation: Rot.fromAngle(block.angle * math.pi / 180)))
          .createShape(Polygon.box((block.halfWidth - round) / 100, (block.halfHeight - round) / 100, radius: round / 100), ShapeDef(material: SurfaceMaterial(friction: .6, restitution: .1)));
    }
    // 风车：匀速转动的运动体（不受力、转角只看过了几步），不睡眠，碰到球照常把球拨开；中间的轴是一个圆。
    for (final spinner in puzzle.spinners) {
      final reach = (spinner.halfLength - pourSpinnerHalf) / 100;
      final body = _world.createBody(BodyDef(
        type: BodyType.kinematic,
        position: _meters(spinner.x, spinner.y),
        rotation: Rot.fromAngle(spinner.angle * math.pi / 180),
        angularVelocity: spinner.speed * math.pi / 180,
        enableSleep: false,
      ));
      final material = SurfaceMaterial(friction: .5, restitution: .2);
      body
        ..createShape(Capsule(center1: Vector2(-reach, 0), center2: Vector2(reach, 0), radius: pourSpinnerHalf / 100), ShapeDef(material: material))
        ..createShape(Circle(radius: pourSpinnerHub / 100), ShapeDef(material: material));
      _spinners.add(body);
    }
    // 每笔线一个静态物体，每段是一根胶囊（两端是圆头，相邻两段接得上、球滚过拐点不磕）。
    for (final stroke in strokes) {
      final line = _world.createBody(BodyDef());
      for (var index = 2; index + 1 < stroke.length; index += 2) {
        line.createShape(Capsule(center1: _meters(stroke[index - 2], stroke[index - 1]), center2: _meters(stroke[index], stroke[index + 1]), radius: pourLineRadius / 100), ShapeDef(material: SurfaceMaterial(friction: .6, restitution: .1)));
      }
    }
  }

  // 重力 12 m/s²：比 10 稍快，球在一屏高的棋盘上落得不拖沓。
  static const _gravity = 12.0;
  // 停稳：每个球都慢于 _slow（单位每秒）；进杯停稳要连续 0.5 秒，停住没进杯连续 0.75 秒就判没进。
  static const _slow = 6.0;
  static const _settleSteps = 30, _stallSteps = 45;

  final PourPuzzle puzzle;
  final World _world;
  final _balls = <Body>[], _spinners = <Body>[];
  int steps = 0;
  PourOutcome outcome = PourOutcome.running;
  int _settled = 0, _resting = 0;

  static Vector2 _meters(num x, num y) => Vector2(x / 100, y / 100);

  // 第 index 个球此刻的球心（单位）与转角（弧度）。
  ({double x, double y, double angle}) ball(int index) {
    final body = _balls[index], position = body.position;
    return (x: position.x * 100, y: position.y * 100, angle: body.angle);
  }

  // 第 index 根风车杆此刻的转角（弧度）。
  double spinner(int index) => _spinners[index].angle;

  void step() {
    if (outcome != PourOutcome.running) return;
    _world.step(pourStep, subStepCount: 4);
    steps++;
    var allIn = true, allSlow = true;
    for (final body in _balls) {
      final position = body.position;
      final x = position.x * 100, y = position.y * 100;
      if (y > pourHeight + 60 || x < -60 || x > pourWidth + 60) {
        outcome = PourOutcome.lost;
        return;
      }
      allSlow = allSlow && body.linearVelocity.length * 100 < _slow;
      allIn = allIn && puzzle.cup.holds(x, y);
    }
    _settled = allIn && allSlow ? _settled + 1 : 0;
    _resting = allSlow ? _resting + 1 : 0;
    if (_settled >= _settleSteps) {
      outcome = PourOutcome.won;
    } else if ((!allIn && _resting >= _stallSteps) || steps >= pourMaxSteps) {
      outcome = PourOutcome.lost;
    }
  }

  void dispose() => _world.destroy();
}

// 一口气模拟到出结果。
PourOutcome pourSimulate(PourPuzzle puzzle, List<List<int>> strokes) {
  final simulation = PourSimulation(puzzle, strokes);
  try {
    while (simulation.outcome == PourOutcome.running) {
      simulation.step();
    }
    return simulation.outcome;
  } finally {
    simulation.dispose();
  }
}

// 每档的几类题（出题时按种子挑一类）：题型、球数、随机障碍数、墨水是参考线长的几倍（百分比）。
// 难易分 = 题型的起点 + 多出来的球 + 随机障碍 + 墨水紧（墨水不到参考线的 pourTight 倍）加 1，每类的组合按档凑进这一档的分段：
// 入门 1–2（直坡、漏斗、缓冲接住，一个球、墨水宽）；简单 3–4（直坡与漏斗两个球加一块障碍、接住加一块障碍、搭桥）；
// 普通 5–6（搭桥两个球加一块障碍、绕障、借板回头、两边来球且墨水紧）；困难 7–8（绕障与借板回头两个球加一块障碍、两边三个球、窄口、风车）；
// 专家 9–10（两笔折返、窄口两个球、风车两个球，两边来球与借板回头再加障碍且墨水紧）。
typedef _Recipe = ({PourKind kind, int balls, int blocks, (int, int) ink});

const Map<PuzzleTier, List<_Recipe>> _tiers = {
  PuzzleTier.entry: [
    (kind: PourKind.ramp, balls: 1, blocks: 0, ink: (200, 250)),
    (kind: PourKind.funnel, balls: 1, blocks: 0, ink: (200, 250)),
    (kind: PourKind.catcher, balls: 1, blocks: 0, ink: (200, 250)),
  ],
  PuzzleTier.easy: [
    (kind: PourKind.ramp, balls: 2, blocks: 1, ink: (165, 200)),
    (kind: PourKind.funnel, balls: 2, blocks: 1, ink: (165, 200)),
    (kind: PourKind.catcher, balls: 1, blocks: 1, ink: (165, 200)),
    (kind: PourKind.bridge, balls: 1, blocks: 0, ink: (165, 200)),
  ],
  PuzzleTier.normal: [
    (kind: PourKind.bridge, balls: 2, blocks: 1, ink: (165, 190)),
    (kind: PourKind.detour, balls: 1, blocks: 0, ink: (165, 190)),
    (kind: PourKind.uturn, balls: 1, blocks: 0, ink: (165, 190)),
    (kind: PourKind.pair, balls: 2, blocks: 0, ink: (135, 155)),
  ],
  PuzzleTier.hard: [
    (kind: PourKind.detour, balls: 2, blocks: 1, ink: (165, 185)),
    (kind: PourKind.uturn, balls: 2, blocks: 1, ink: (165, 185)),
    (kind: PourKind.pair, balls: 3, blocks: 1, ink: (165, 185)),
    (kind: PourKind.slot, balls: 1, blocks: 0, ink: (135, 155)),
    (kind: PourKind.windmill, balls: 1, blocks: 0, ink: (165, 185)),
  ],
  PuzzleTier.expert: [
    (kind: PourKind.switchback, balls: 2, blocks: 0, ink: (135, 150)),
    (kind: PourKind.slot, balls: 2, blocks: 1, ink: (165, 180)),
    (kind: PourKind.windmill, balls: 2, blocks: 1, ink: (135, 150)),
    (kind: PourKind.pair, balls: 3, blocks: 2, ink: (135, 150)),
    (kind: PourKind.uturn, balls: 2, blocks: 2, ink: (135, 150)),
  ],
};

class PourRules extends PuzzleRules<PourPuzzle, List<List<int>>> {
  const PourRules();

  // 题面加了题型、风车与参考线长（第 1 版只有球、杯、障碍与墨水）；这个游戏不进挑战，版本号只为守住「改了写法就加一」。
  @override
  int get puzzleVersion => 2;

  // 出题：先按种子挑这一档的一类题，搭出结构与参考线，再在不挡参考线的地方摆随机障碍；用同一份模拟确认
  // 「画了参考线放球能进杯」、参考线整体上下挪 6 单位也照样进（不是卡在刀刃上的题）、「什么都不画放球进不了杯」，
  // 再过这一类自己的检查（多笔的题少画哪一笔都不进、绕障与风车照直画一条坡不进），才用。
  @override
  PuzzleDraw<PourPuzzle, List<List<int>>> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final recipe = random.pick(_tiers[tier]!);
    final floor = tier.index * 2 + 1;
    while (true) {
      final layout = _sketch(random, recipe);
      if (layout == null || !_placeBlocks(random, layout, recipe.blocks)) continue;
      final par = pourInkUsed(layout.strokes).ceil();
      final ink = math.min((par * _between(random, recipe.ink) / 100 / 5).ceil() * 5, pourMaxInk);
      final puzzle = PourPuzzle(kind: recipe.kind, balls: layout.balls, cup: layout.cup, blocks: layout.blocks, spinners: layout.spinners, ink: ink, par: par);
      final score = complexity(puzzle);
      if (score < floor || score > floor + 1 || !pourAnswerValid(puzzle, layout.strokes)) continue;
      // 先查「不该进的进不了」（常常不过、而且很快出结果），再查参考线与它的几种变体。
      if (pourSimulate(puzzle, const []) == PourOutcome.won || layout.misses.any((miss) => pourSimulate(puzzle, miss) == PourOutcome.won)) continue;
      if (pourSimulate(puzzle, layout.strokes) != PourOutcome.won) continue;
      if (pourSimulate(puzzle, _shift(layout.strokes, -6)) != PourOutcome.won || pourSimulate(puzzle, _shift(layout.strokes, 6)) != PourOutcome.won) continue;
      if ([pourMinSegment, pourMinSegment ~/ 2].any((first) => pourSimulate(puzzle, [for (final stroke in layout.strokes) _traced(stroke, first)]) != PourOutcome.won)) continue;
      return PuzzleDraw(puzzle, layout.strokes);
    }
  }

  @override
  bool solved(PourPuzzle puzzle, List<List<int>> answer) => pourAnswerValid(puzzle, answer) && pourSimulate(puzzle, answer) == PourOutcome.won;

  // 预计用时：入门约 20–25 秒，难易每高一级乘 1.28，专家（9–10）约 2.5–3 分钟（要想结构、反复放球试，按常见的人工解题速度估）。
  @override
  int expectedSeconds(PourPuzzle puzzle) => puzzlePace(complexity(puzzle), base: 20, growth: 1.28);

  // 难易分：题型的起点（直坡与漏斗 1、缓冲接住 2、搭桥 3、绕障与借板回头与两边来球 5、窄口与风车 7、两笔折返 8），
  // 加多出来的球、多出来的随机障碍、墨水紧再加 1；各档的分段见 _tiers 上面的注释。
  @override
  int complexity(PourPuzzle puzzle) {
    final kind = puzzle.kind;
    final extraBalls = math.max(0, puzzle.ballCount - kind.balls), extraBlocks = math.max(0, puzzle.blocks.length - kind.structure);
    final tight = puzzle.ink < puzzle.par * pourTight;
    return (kind.base + extraBalls + extraBlocks + (tight ? 1 : 0)).clamp(1, 10);
  }

  @override
  Object encodePuzzle(PourPuzzle puzzle) => {
    'kind': puzzle.kind.code,
    'balls': puzzle.balls,
    'cup': [puzzle.cup.x, puzzle.cup.bottom, puzzle.cup.width, puzzle.cup.depth],
    'blocks': [for (final block in puzzle.blocks) ...[block.x, block.y, block.halfWidth, block.halfHeight, block.angle]],
    'spinners': [for (final spinner in puzzle.spinners) ...[spinner.x, spinner.y, spinner.halfLength, spinner.speed, spinner.angle]],
    'ink': puzzle.ink,
    'par': puzzle.par,
  };

  // 解码校验：题型认得，球、杯、障碍、风车都在棋盘里、尺寸在范围内，球与球、球与障碍和杯壁不重叠、不在风车扫过的范围里（重叠的话放球那一刻会被弹飞）。
  @override
  PourPuzzle decodePuzzle(Object? json) {
    if (json is! Map) throw const FormatException('题目不合法');
    final kind = PourKind.coded(puzzleInt(json, 'kind', min: 0, max: 99));
    if (kind == null) throw const FormatException('题目字段 kind 不合法');
    final balls = puzzleInts(json['balls'], maxLength: pourMaxBalls * 2, min: 0, max: pourHeight);
    if (balls.isEmpty || balls.length.isOdd) throw const FormatException('题目字段 balls 不合法');
    for (var index = 0; index < balls.length; index += 2) {
      if (balls[index] < pourBallRadius || balls[index] > pourWidth - pourBallRadius || balls[index + 1] < pourBallRadius || balls[index + 1] > pourHeight - pourBallRadius) throw const FormatException('题目字段 balls 不合法');
    }
    final cupValues = puzzleInts(json['cup'], maxLength: 4, min: 0, max: pourHeight);
    if (cupValues.length != 4) throw const FormatException('题目字段 cup 不合法');
    final cup = PourCup(x: cupValues[0], bottom: cupValues[1], width: cupValues[2], depth: cupValues[3]);
    if (cup.width < pourBallRadius * 2 + 8 || cup.width > 240 || cup.depth < pourBallRadius * 2 || cup.depth > 200 || cup.left - pourCupWall < 0 || cup.right + pourCupWall > pourWidth || cup.bottom + pourCupWall > pourHeight || cup.top < 100) {
      throw const FormatException('题目字段 cup 不合法');
    }
    final blockValues = puzzleInts(json['blocks'], maxLength: pourMaxBlocks * 5, min: -90, max: pourHeight);
    if (blockValues.length % 5 != 0) throw const FormatException('题目字段 blocks 不合法');
    final blocks = [
      for (var index = 0; index < blockValues.length; index += 5)
        PourBlock(x: blockValues[index], y: blockValues[index + 1], halfWidth: blockValues[index + 2], halfHeight: blockValues[index + 3], angle: blockValues[index + 4]),
    ];
    for (final block in blocks) {
      if (block.x < 0 || block.x > pourWidth || block.y < 0 || block.y > pourHeight || block.halfWidth < 6 || block.halfWidth > 200 || block.halfHeight < 6 || block.halfHeight > 200) throw const FormatException('题目字段 blocks 不合法');
    }
    final spinnerValues = puzzleInts(json['spinners'], maxLength: pourMaxSpinners * 5, min: -360, max: pourHeight);
    if (spinnerValues.length % 5 != 0) throw const FormatException('题目字段 spinners 不合法');
    final spinners = [
      for (var index = 0; index < spinnerValues.length; index += 5)
        PourSpinner(x: spinnerValues[index], y: spinnerValues[index + 1], halfLength: spinnerValues[index + 2], speed: spinnerValues[index + 3], angle: spinnerValues[index + 4]),
    ];
    for (final spinner in spinners) {
      if (spinner.x < 0 || spinner.x > pourWidth || spinner.y < 0 || spinner.y > pourHeight || spinner.halfLength < pourSpinnerHub + 10 || spinner.halfLength > 120 || spinner.speed == 0 || spinner.angle < -180 || spinner.angle > 180) {
        throw const FormatException('题目字段 spinners 不合法');
      }
    }
    final ink = puzzleInt(json, 'ink', min: 50, max: pourMaxInk);
    final par = puzzleInt(json, 'par', min: 20, max: ink);
    final walls = [for (final (left, top, right, bottom) in cup.walls) [left, top, right, top, right, bottom, left, bottom]];
    for (var index = 0; index < balls.length; index += 2) {
      final x = balls[index].toDouble(), y = balls[index + 1].toDouble();
      for (var other = index + 2; other < balls.length; other += 2) {
        if (_distance(x, y, balls[other], balls[other + 1]) < pourBallRadius * 2) throw const FormatException('题目里的球重叠');
      }
      for (final polygon in [for (final block in blocks) block.corners, ...walls]) {
        if (_polygonPoint(polygon, x, y) < pourBallRadius) throw const FormatException('题目里的球压在障碍上');
      }
      for (final spinner in spinners) {
        if (_distance(x, y, spinner.x, spinner.y) < spinner.halfLength + pourBallRadius) throw const FormatException('题目里的球在风车扫过的范围里');
      }
    }
    return PourPuzzle(kind: kind, balls: balls, cup: cup, blocks: blocks, spinners: spinners, ink: ink, par: par);
  }

  @override
  Object encodeAnswer(List<List<int>> answer) => answer;

  @override
  List<List<int>> decodeAnswer(Object? json) {
    if (json is! List || json.length > pourMaxStrokes) throw const FormatException('答案不合法');
    final strokes = [for (final stroke in json) puzzleInts(stroke, maxLength: pourMaxPoints * 2, min: 0, max: pourHeight)];
    var points = 0;
    for (final stroke in strokes) {
      if (stroke.length < 4 || stroke.length.isOdd) throw const FormatException('答案不合法');
      for (var index = 0; index < stroke.length; index += 2) {
        if (stroke[index] > pourWidth) throw const FormatException('答案不合法');
      }
      points += stroke.length ~/ 2;
    }
    if (points > pourMaxPoints) throw const FormatException('答案不合法');
    return strokes;
  }
}

// ---------- 出题 ----------

// 一张草图：球、杯、结构（固定障碍与风车）、参考线、摆障碍时要让开的通道（球会经过的路线，每段带要让开的距离），
// 与这一类自己的检查：misses 里的每一种画法放球都必须进不了。
class _Layout {
  _Layout({required this.balls, required this.cup, required this.strokes, required this.lanes, List<PourBlock>? blocks, this.spinners = const [], this.misses = const []}) : blocks = blocks ?? [];
  final List<int> balls;
  final PourCup cup;
  final List<List<int>> strokes;
  final List<_Lane> lanes;
  final List<PourBlock> blocks;
  final List<PourSpinner> spinners;
  final List<List<List<int>>> misses;
  // 摆随机障碍时优先放在参考线附近（不挡路，但挡住别的画法），这里记下参考线的各段。
  List<_Lane> get ramps => [for (final lane in lanes) if (lane.ramp) lane];
}

class _Lane {
  const _Lane(this.x1, this.y1, this.x2, this.y2, this.clearance, {this.ramp = false});
  final double x1, y1, x2, y2, clearance;
  final bool ramp;
}

int _between(PuzzleRandom random, (int, int) range) => range.$1 + random.nextInt(range.$2 - range.$1 + 1);

_Layout? _sketch(PuzzleRandom random, _Recipe recipe) => switch (recipe.kind) {
  PourKind.ramp => _ramp(random, recipe),
  PourKind.switchback => _switchback(random, recipe),
  PourKind.funnel => _funnel(random, recipe),
  PourKind.catcher => _catcher(random, recipe),
  PourKind.bridge => _bridge(random, recipe),
  PourKind.uturn => _uturn(random, recipe),
  PourKind.detour || PourKind.windmill => _detour(random, recipe),
  PourKind.pair => _pair(random, recipe),
  PourKind.slot => _slot(random, recipe),
};

// 球心沿坡道滚过的路线：坡道朝上（y 变小的一侧）平移球半径加线半径。
_Lane _rolling(double x1, double y1, double x2, double y2) {
  final length = _distance(x1, y1, x2, y2), lift = (pourBallRadius + pourLineRadius).toDouble();
  var nx = (y2 - y1) / length, ny = -(x2 - x1) / length;
  if (ny > 0) {
    nx = -nx;
    ny = -ny;
  }
  return _Lane(x1 + nx * lift, y1 + ny * lift, x2 + nx * lift, y2 + ny * lift, pourBallRadius + 12);
}

// 坡道本身（线宽外再让一点）、球心沿坡道的路线。
List<_Lane> _rampLanes(num x1, num y1, num x2, num y2) => [_Lane(x1.toDouble(), y1.toDouble(), x2.toDouble(), y2.toDouble(), pourLineRadius + 10, ramp: true), _rolling(x1.toDouble(), y1.toDouble(), x2.toDouble(), y2.toDouble())];

double _lift(num x1, num y1, num x2, num y2) => (pourBallRadius + pourLineRadius) * _distance(x1, y1, x2, y2) / (x2 - x1).abs();

// 从坡道末端落进杯底的那一段通道。
_Lane _into(num x, num y, PourCup cup) => _Lane(x.toDouble(), y - pourBallRadius - pourLineRadius.toDouble(), cup.x.toDouble(), (cup.bottom - pourBallRadius).toDouble(), pourBallRadius + 12);

// 在一段朝 toward 斜下的坡（线或板的上表面，从 (x1, y1) 到 (x2, y2)）的上半段正上方摆 count 个球：第一个离上端 30–90，往后每个隔 44–56，
// 各自落下 fall 再加线宽碰到坡。球进 balls、每个球落到坡上的那一段进 lanes；放不下（太靠上、离坡的下端不到 80）返回假。
bool _dropBalls(PuzzleRandom random, {required int toward, required int x1, required int y1, required int x2, required int y2, required int count, required List<int> balls, required List<_Lane> lanes, (int, int) fall = (50, 140), int surface = pourLineRadius, (int, int) spacing = (44, 56)}) {
  final span = (x2 - x1).abs();
  if (span == 0) return false;
  int slopeY(int x) => y1 + (x - x1) * toward * (y2 - y1) ~/ span;
  var ballX = x1 + toward * _between(random, (30, math.max(30, math.min(90, span * 35 ~/ 100))));
  final drop = _between(random, fall);
  final ballY = slopeY(ballX) - drop - pourBallRadius - surface;
  final lift = (pourBallRadius + surface) * _distance(x1, y1, x2, y2) / span;
  for (var index = 0; index < count; index++) {
    final y = ballY + (index == 0 ? 0 : _between(random, (-20, 20)));
    if (y < 40 || (x2 - ballX) * toward < 80) return false;
    balls.addAll([ballX, y]);
    lanes.add(_Lane(ballX.toDouble(), y.toDouble(), ballX.toDouble(), slopeY(ballX) - lift, pourBallRadius + 12));
    ballX += toward * _between(random, spacing);
  }
  return true;
}

// 一段直坡：从 (endX, endY) 往回（朝 -toward）水平跨 span、按坡度 grade（百分比）抬高到起点，球摆在坡道上半段正上方。
// 返回坡道这一笔、球与通道；放不下（出了棋盘、太靠上）为空。
({List<int> stroke, List<int> balls, List<_Lane> lanes})? _slope(PuzzleRandom random, {required int toward, required int endX, required int endY, required int span, required int grade, required int count, (int, int) spacing = (44, 56)}) {
  final startX = endX - toward * span, startY = endY - span * grade ~/ 100;
  if (startY < 150 || startX < 16 || startX > pourWidth - 16) return null;
  final balls = <int>[];
  final lanes = <_Lane>[..._rampLanes(startX, startY, endX, endY)];
  if (!_dropBalls(random, toward: toward, x1: startX, y1: startY, x2: endX, y2: endY, count: count, balls: balls, lanes: lanes, spacing: spacing)) return null;
  return (stroke: [startX, startY, endX, endY], balls: balls, lanes: lanes);
}

// 杯子横向放在哪：离 toward 背面那一侧棋盘边至少 behind（坡道、球在那一侧），另一侧杯壁外沿离边至少 8。放不下为空。
PourCup? _cupBeside(PuzzleRandom random, {required int toward, required int behind, required int width, required int depth, required int bottom}) {
  final low = behind + width ~/ 2, high = pourWidth - 8 - pourCupWall - (width + 1) ~/ 2;
  if (low > high) return null;
  final offset = _between(random, (low, high));
  return PourCup(x: toward > 0 ? offset : pourWidth - offset, bottom: bottom, width: width, depth: depth);
}

// 一块板，上表面是 (x1, y1)–(x2, y2) 这一段（板厚是 half 的两倍、往下长），球滚在上表面上。
PourBlock _plank(num x1, num y1, num x2, num y2, int half) {
  if (x2 < x1) return _plank(x2, y2, x1, y1, half);
  final length = _distance(x1, y1, x2, y2), dx = (x2 - x1) / length, dy = (y2 - y1) / length;
  // 朝下的法线是 (-dy, dx)（x2 ≥ x1，所以 y 分量不为负）。
  return PourBlock(x: ((x1 + x2) / 2 - dy * half).round(), y: ((y1 + y2) / 2 + dx * half).round(), halfWidth: (length / 2).round(), halfHeight: half, angle: (math.atan2(dy, dx) * 180 / math.pi).round());
}

// 板（取整之后）的上表面在 x 处的 y：沿上沿两角插值。
double _topAt(PourBlock block, num x) {
  final corners = block.corners;
  final (ax, ay, bx, by) = (corners[0], corners[1], corners[2], corners[3]);
  return ay + (by - ay) * (x - ax) / (bx - ax);
}

// 入门到困难的直坡：球在一侧上方，一段直坡从球下方斜着通到杯口近侧（略探进杯口、高出杯沿一点），球顺坡滚下、越过近侧杯沿落进杯里，远侧杯壁挡住不飞出去。
_Layout? _ramp(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, recipe.balls > 1 ? (110, 135) : (100, 140));
  final depth = recipe.balls > 1 ? _between(random, (72, 90)) : _between(random, (60, 80));
  final bottom = _between(random, (690, 760));
  final span = _between(random, (160, 360)), grade = _between(random, (28, 58));
  final gap = _between(random, (12, 28)), over = _between(random, (8, 22));
  final cup = _cupBeside(random, toward: toward, behind: 30 + span - over, width: width, depth: depth, bottom: bottom);
  if (cup == null) return null;
  final endX = cup.x - toward * (width ~/ 2 - over), endY = cup.top - gap - pourLineRadius;
  final slope = _slope(random, toward: toward, endX: endX, endY: endY, span: span, grade: grade, count: recipe.balls);
  if (slope == null) return null;
  return _Layout(balls: slope.balls, cup: cup, strokes: [slope.stroke], lanes: [...slope.lanes, _into(endX, endY, cup)]);
}

// 漏斗：杯口上方一对张开的斜板（下端搭在杯沿上方、上端往外张开），球在漏斗外侧的上方；一段直坡把球送过漏斗外沿，球落在斜板上滑进杯里。
_Layout? _funnel(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, recipe.balls > 1 ? (100, 125) : (90, 120)), depth = _between(random, recipe.balls > 1 ? (72, 90) : (64, 84));
  final bottom = _between(random, (690, 760));
  final rise = _between(random, (70, 110)), spread = _between(random, (60, 100));
  final span = _between(random, (140, 260)), grade = _between(random, (28, 55));
  // 坡道末端越过漏斗外沿 reach、比外沿高 lift。
  final reach = _between(random, (0, 20)), lift = _between(random, (16, 32));
  final mouth = width ~/ 2 - 6 + spread;
  final cup = _cupBeside(random, toward: toward, behind: 24 + span + mouth - reach, width: width, depth: depth, bottom: bottom);
  if (cup == null || cup.x + mouth + 10 > pourWidth || cup.x - mouth - 10 < 0) return null;
  final blocks = [
    for (final side in [-1, 1]) _plank(cup.x + side * (width ~/ 2 - 6), cup.top - 4, cup.x + side * mouth, cup.top - 4 - rise, 7),
  ];
  final lipX = cup.x - toward * mouth, lipY = cup.top - 4 - rise;
  final endX = lipX + toward * reach, endY = lipY - lift;
  final slope = _slope(random, toward: toward, endX: endX, endY: endY, span: span, grade: grade, count: recipe.balls);
  if (slope == null) return null;
  return _Layout(
    balls: slope.balls,
    cup: cup,
    blocks: blocks,
    strokes: [slope.stroke],
    lanes: [...slope.lanes, _Lane(endX.toDouble(), endY - 23.0, cup.x.toDouble(), cup.bottom - 18.0, pourBallRadius + 12), _Lane(lipX.toDouble(), lipY - 23.0, cup.x.toDouble(), cup.top - 23.0, pourBallRadius + 12)],
  );
}

// 缓冲接住：球落在一块陡滑板的上端，顺板冲出去，什么都不画会飞过杯子；参考解是杯子远侧杯壁上方一笔竖着（略往外斜）的挡板，球撞上就落进杯里。
// 挡板摆在哪按同一份模拟算：先不画线放一次球，取球飞到杯子远侧那一刻的高度。
_Layout? _catcher(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, (95, 130)), depth = _between(random, (64, 84)), bottom = _between(random, (690, 760));
  final grade = _between(random, (55, 100)), span = _between(random, (110, 190)), lift = _between(random, (90, 220)), reach = _between(random, (10, 90));
  final cup = _cupBeside(random, toward: toward, behind: 24 + span + reach + pourCupWall, width: width, depth: depth, bottom: bottom);
  if (cup == null) return null;
  final endX = cup.x - toward * (width ~/ 2 + pourCupWall + reach), endY = cup.top - lift;
  final startX = endX - toward * span, startY = endY - span * grade ~/ 100;
  if (startY < 120) return null;
  final slide = _plank(startX, startY, endX, endY, 8);
  final balls = <int>[], lanes = <_Lane>[];
  if (!_dropBalls(random, toward: toward, x1: startX, y1: startY, x2: endX, y2: endY, count: recipe.balls, balls: balls, lanes: lanes, fall: (30, 80), surface: 0)) return null;
  final (outcome, path) = _trace(PourPuzzle(kind: PourKind.catcher, balls: balls, cup: cup, blocks: [slide], ink: pourMaxInk, par: 1), const []);
  if (outcome == PourOutcome.won) return null;
  // 挡板的中线在远侧杯壁内面往里 4；球撞上时球心离它半个线宽加球半径。
  final catchX = cup.x + toward * (width ~/ 2 - 4), contact = catchX - toward * (pourLineRadius + pourBallRadius);
  var hit = -1;
  for (var index = 0; index < path.length; index += 2) {
    if ((path[index] - contact) * toward >= 0) {
      hit = index;
      break;
    }
  }
  if (hit < 0) return null;
  final hitY = path[hit + 1];
  if (hitY > cup.top - 40 || hitY < 100) return null;
  final top = (hitY - _between(random, (45, 80))).round(), tilt = _between(random, (0, 16));
  if (top < 30) return null;
  // 球飞过的路线（每 4 步一段）与撞上之后落进杯里的那一段。
  for (var index = 8; index <= hit; index += 8) {
    lanes.add(_Lane(path[index - 8], path[index - 7], path[index], path[index + 1], pourBallRadius + 10));
  }
  lanes
    ..add(_Lane(catchX.toDouble(), top.toDouble(), catchX.toDouble(), cup.top - 2.0, pourLineRadius + 10, ramp: true))
    ..add(_Lane(contact.toDouble(), hitY, cup.x.toDouble(), cup.bottom - 18.0, pourBallRadius + 12));
  return _Layout(balls: balls, cup: cup, blocks: [slide], strokes: [[catchX + toward * tilt, top, catchX, cup.top - 2]], lanes: lanes);
}

// 搭桥：两块固定的斜板，下面那块的末端探进杯口上方；两块中间断开，缺口两头的落差比上面那块的坡缓得多，球冲下来会扎进缺口、从板底下掉出去。
// 参考解是一段比两块板都缓的桥：起点比上面那块的末端低一点（球落上去），终点比下面那块的起点高一点（球落下去）。
_Layout? _bridge(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, recipe.balls > 1 ? (110, 135) : (100, 130)), depth = _between(random, recipe.balls > 1 ? (72, 90) : (64, 84));
  final bottom = _between(random, (700, 760));
  final upper = _between(random, (60, 85)), lean = _between(random, (22, 32)), lower = _between(random, (25, 45));
  // 两个球都要落在上面那块的上半段，那块长一点。
  final spanA = _between(random, recipe.balls > 1 ? (160, 200) : (110, 160)), gapWidth = _between(random, (80, 115)), spanB = _between(random, (90, 150));
  final over = _between(random, (10, 22)), rise = _between(random, (24, 36));
  if (gapWidth * (upper - lean) ~/ 100 < 30) return null;
  final cup = _cupBeside(random, toward: toward, behind: 24 + spanA + gapWidth + spanB - over, width: width, depth: depth, bottom: bottom);
  if (cup == null) return null;
  final bx2 = cup.x - toward * (width ~/ 2 - over), by2 = cup.top - rise;
  final bx1 = bx2 - toward * spanB, by1 = by2 - spanB * lower ~/ 100;
  final ax2 = bx1 - toward * gapWidth, ay2 = by1 - gapWidth * lean ~/ 100;
  final ax1 = ax2 - toward * spanA, ay1 = ay2 - spanA * upper ~/ 100;
  if (ay1 < 150) return null;
  final shelfA = _plank(ax1, ay1, ax2, ay2, 8), shelfB = _plank(bx1, by1, bx2, by2, 8);
  final startX = ax2 + toward * 2, startY = (_topAt(shelfA, ax2) + 8).round();
  final finishX = bx1 + toward * 14, finishY = (_topAt(shelfB, finishX) - 9).round();
  if (finishY - startY < 8) return null;
  final balls = <int>[], lanes = <_Lane>[];
  if (!_dropBalls(random, toward: toward, x1: ax1, y1: ay1, x2: ax2, y2: ay2, count: recipe.balls, balls: balls, lanes: lanes, fall: (30, 70), surface: 0)) return null;
  lanes
    ..add(_rolling(ax1.toDouble(), ay1.toDouble(), ax2.toDouble(), ay2.toDouble()))
    ..addAll(_rampLanes(startX, startY, finishX, finishY))
    ..add(_rolling(bx1.toDouble(), by1.toDouble(), bx2.toDouble(), by2.toDouble()))
    ..add(_into(bx2, by2, cup));
  return _Layout(balls: balls, cup: cup, blocks: [shelfA, shelfB], strokes: [[startX, startY, finishX, finishY]], lanes: lanes);
}

// 借板回头：球下方一块往外斜下的板，内端在杯子内侧外沿以里、外端越过杯子外侧外沿，球滚出板外端就掉出棋盘（板也挡住了杯口）。
// 参考解一笔：板外端再往外一段竖着挡住飞出来的球，底下接一段斜坡从板底下穿回杯口外侧上方。
_Layout? _uturn(PuzzleRandom random, _Recipe recipe) {
  final outward = random.chance(.5) ? 1 : -1;
  final width = _between(random, recipe.balls > 1 ? (105, 125) : (95, 120)), depth = _between(random, (72, 90));
  final bottom = _between(random, (700, 760));
  final inset = _between(random, (16, 40)), beyond = _between(random, (40, 60)), lip = _between(random, (56, 84));
  final grade = _between(random, (18, 32)), height = _between(random, (140, 200));
  final inner = (width + 1) ~/ 2 + pourCupWall + inset, outer = (width + 1) ~/ 2 + pourCupWall + beyond;
  final low = math.max(inner + 20, 90), high = pourWidth - (outer + lip + 24);
  if (low > high) return null;
  final offset = _between(random, (low, high));
  final cup = PourCup(x: outward > 0 ? offset : pourWidth - offset, bottom: bottom, width: width, depth: depth);
  final endX = cup.x + outward * outer, endY = cup.top - height;
  final startX = cup.x - outward * inner, startY = endY - (inner + outer) * grade ~/ 100;
  final plank = _plank(startX, startY, endX, endY, 8);
  final balls = <int>[], lanes = <_Lane>[];
  if (!_dropBalls(random, toward: outward, x1: startX, y1: startY, x2: endX, y2: endY, count: recipe.balls, balls: balls, lanes: lanes, fall: (40, 100), surface: 0)) return null;
  final over = _between(random, (8, 22)), gap = _between(random, (12, 28));
  final lipX = endX + outward * lip, lipTop = endY - _between(random, (10, 30));
  final finishX = cup.x + outward * (width ~/ 2 - over), finishY = cup.top - gap - pourLineRadius;
  final lipBottom = finishY - (lipX - finishX).abs() * _between(random, (18, 40)) ~/ 100;
  if (lipBottom - endY < pourBallRadius * 2 + 30 || lipBottom - lipTop < 60) return null;
  // 回头的那一段在板外端处离板底要留出球滚过的空间。
  final underPlank = lipBottom + (lipX - endX).abs() * (finishY - lipBottom) ~/ (lipX - finishX).abs();
  if (underPlank - (endY + 16) < pourBallRadius * 2 + pourLineRadius + 16) return null;
  lanes
    ..add(_rolling(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble()))
    ..add(_Lane(endX.toDouble(), endY - 18.0, lipX - outward * 24.0, lipBottom - 24.0, pourBallRadius + 12))
    ..add(_Lane(lipX.toDouble(), lipTop.toDouble(), lipX.toDouble(), lipBottom.toDouble(), pourLineRadius + 10, ramp: true))
    ..addAll(_rampLanes(lipX, lipBottom, finishX, finishY))
    ..add(_into(finishX, finishY, cup));
  return _Layout(balls: balls, cup: cup, blocks: [plank], strokes: [[lipX, lipTop, lipX, lipBottom, finishX, finishY]], lanes: lanes);
}

// 绕障与风车：照直从球下方到杯口近侧的那条坡上有一块障碍（绕障）或一根转动的杆（风车），参考线折一下：
// 从上面绕是先缓后陡（障碍垫在缓的那段下面），从下面绕是先陡后缓（障碍悬在拐点上方，留出球滚过的空间）。照直画的那条坡必须进不了。
_Layout? _detour(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final spin = recipe.kind == PourKind.windmill;
  final width = _between(random, recipe.balls > 1 ? (110, 135) : (100, 135));
  final depth = recipe.balls > 1 ? _between(random, (72, 90)) : _between(random, (60, 80));
  final bottom = _between(random, (690, 760));
  final over = _between(random, (8, 22)), gap = _between(random, (12, 28));
  final above = random.chance(.5);
  // 风车要折得更深：照直那条坡离折线够远，才能既撞上风车的轴、参考线又离风车扫过的范围够远。
  final g1 = _between(random, above ? (14, 24) : (spin ? (75, 105) : (65, 95))), g2 = _between(random, above ? (spin ? (80, 110) : (65, 95)) : (12, 24));
  final l1 = _between(random, spin ? (170, 220) : (150, 210)), l2 = _between(random, spin ? (130, 170) : (110, 160));
  final cup = _cupBeside(random, toward: toward, behind: 24 + l1 + l2 - over, width: width, depth: depth, bottom: bottom);
  if (cup == null) return null;
  final endX = cup.x - toward * (width ~/ 2 - over), endY = cup.top - gap - pourLineRadius;
  final kinkX = endX - toward * l2, kinkY = endY - l2 * g2 ~/ 100;
  final startX = kinkX - toward * l1, startY = kinkY - l1 * g1 ~/ 100;
  if (startY < 150) return null;
  double lineY(num x) => (x - kinkX) * toward <= 0 ? startY + (x - startX) * toward * g1 / 100 : kinkY + (x - kinkX) * toward * g2 / 100;
  final balls = <int>[];
  final lanes = <_Lane>[..._rampLanes(startX, startY, kinkX, kinkY), ..._rampLanes(kinkX, kinkY, endX, endY), _into(endX, endY, cup)];
  if (!_dropBalls(random, toward: toward, x1: startX, y1: startY, x2: kinkX, y2: kinkY, count: recipe.balls, balls: balls, lanes: lanes, fall: (40, 120))) return null;
  final layout = _Layout(balls: balls, cup: cup, strokes: [[startX, startY, kinkX, kinkY, endX, endY]], lanes: lanes, misses: [[[startX, startY, endX, endY]]]);
  // 照直那条坡上滚的球心（坡上方抬起球半径加线半径）：障碍要挡住它。
  final straight = _rolling(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble());
  if (spin) {
    final reach = _between(random, (36, 50));
    final speed = _between(random, (60, 120)) * (random.chance(.5) ? 1 : -1);
    final angle = _between(random, (0, 179));
    // 风车在折线的哪一侧：从上面绕时在线下方，从下面绕时在线上方；离两段线的中线够它扫过、再留出线宽（从上面绕）或球滚过（从下面绕）的空间；
    // 照直那条坡上滚的球要撞上风车的轴（轴不动，照直画一定进不了）。在拐点附近随机试几处。
    final need = reach + pourLineRadius + (above ? 12 : pourBallRadius * 2 + 14);
    for (var attempt = 0; attempt < 40; attempt++) {
      final x = kinkX + _between(random, (-reach * 3 ~/ 2, reach * 3 ~/ 2)), y = kinkY + _between(random, (-reach * 3 - 80, reach * 2 + 40));
      if ((y - lineY(x)) * (above ? 1 : -1) <= 0) continue;
      final px = x.toDouble(), py = y.toDouble();
      if (math.min(_pointSegment(px, py, startX.toDouble(), startY.toDouble(), kinkX.toDouble(), kinkY.toDouble()), _pointSegment(px, py, kinkX.toDouble(), kinkY.toDouble(), endX.toDouble(), endY.toDouble())) < need) continue;
      if (_pointSegment(px, py, straight.x1, straight.y1, straight.x2, straight.y2) > pourSpinnerHub + pourBallRadius - 6) continue;
      final spinner = PourSpinner(x: x, y: y, halfLength: reach, speed: speed, angle: angle);
      if (!_spinnerFits(layout, spinner)) continue;
      return _Layout(balls: balls, cup: cup, strokes: layout.strokes, lanes: lanes, spinners: [spinner], misses: layout.misses);
    }
    return null;
  }
  final PourBlock block;
  if (above) {
    final half = _between(random, (22, 34)), angle = _between(random, (-8, 8));
    final x = kinkX - toward * (half + _between(random, (4, 16)));
    block = PourBlock(x: x, y: (lineY(x + toward * half) + pourLineRadius + 12 + half + half * 15 ~/ 100).round(), halfWidth: half, halfHeight: half, angle: angle);
  } else {
    final halfWidth = _between(random, (36, 64)), halfHeight = _between(random, (9, 13)), angle = _between(random, (-10, 10));
    final x = kinkX + toward * (halfWidth ~/ 2 + _between(random, (0, 20)));
    final clear = math.min(lineY(x - halfWidth), lineY(x + halfWidth));
    block = PourBlock(x: x, y: (clear - pourLineRadius - pourBallRadius * 2 - 14 - halfHeight - halfWidth * 18 ~/ 100).round(), halfWidth: halfWidth, halfHeight: halfHeight, angle: angle);
  }
  if (_polygonSegment(block.corners, straight.x1, straight.y1, straight.x2, straight.y2) > pourBallRadius - 4 || !_fits(layout, block)) return null;
  layout.blocks.add(block);
  return layout;
}

// 两边来球：杯子在中间一带，两边各有球（三个球时一边两个），参考解每边一段直坡引到杯口那一侧；少画哪一边都进不了。
_Layout? _pair(PuzzleRandom random, _Recipe recipe) {
  final width = _between(random, recipe.balls > 2 ? (130, 155) : (115, 140)), depth = _between(random, (76, 92));
  final cup = PourCup(x: _between(random, (240, 360)), bottom: _between(random, (700, 760)), width: width, depth: depth);
  final heavy = random.chance(.5) ? 1 : -1;
  final balls = <int>[], strokes = <List<int>>[], lanes = <_Lane>[];
  for (final toward in [1, -1]) {
    final over = _between(random, (8, 18)), gap = _between(random, (12, 34));
    final endX = cup.x - toward * (width ~/ 2 - over), endY = cup.top - gap - pourLineRadius;
    final room = toward > 0 ? endX - 24 : pourWidth - 24 - endX;
    if (room < 130) return null;
    final slope = _slope(random, toward: toward, endX: endX, endY: endY, span: _between(random, (130, math.min(230, room))), grade: _between(random, (30, 60)), count: recipe.balls > 2 && toward == heavy ? 2 : 1);
    if (slope == null) return null;
    balls.addAll(slope.balls);
    strokes.add(slope.stroke);
    lanes
      ..addAll(slope.lanes)
      ..add(_into(endX, endY, cup));
  }
  return _Layout(balls: balls, cup: cup, strokes: strokes, lanes: lanes, misses: [[strokes[0]], [strokes[1]]]);
}

// 窄口：杯口盖着两块搭在杯壁顶上的平板，中间只留一道比球宽一点的缝；球滚得快会越过缝、从远侧盖板滚出去。
// 参考解两笔：一段直坡把球送上近侧盖板，缝的远边再竖着挡一下，球撞上就落进缝里。少画哪一笔都必须进不了。
_Layout? _slot(PuzzleRandom random, _Recipe recipe) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, (120, 150));
  final depth = recipe.balls > 1 ? _between(random, (84, 96)) : _between(random, (64, 84));
  final bottom = _between(random, (700, 760));
  // 近侧盖板在杯口里至少 36：球落到盖板上先滚稳了再过缝。
  final opening = _between(random, (50, 58)), near = _between(random, (36, width - opening - 24));
  final span = _between(random, (180, 300)), grade = _between(random, (36, 60));
  final cup = _cupBeside(random, toward: toward, behind: 30 + span + pourCupWall, width: width, depth: depth, bottom: bottom);
  if (cup == null) return null;
  const lidHalf = 6;
  final lidTop = cup.top - lidHalf * 2;
  final edge = cup.x - toward * (width ~/ 2 + pourCupWall), far = cup.x + toward * ((width + 1) ~/ 2 + pourCupWall);
  final slotNear = cup.x - toward * (width ~/ 2) + toward * near, slotFar = slotNear + toward * opening;
  // 近侧盖板朝缝微微斜下（被挡回来或被后一个球撞回来的球会滚回缝口，不停在板上），缝口那头与远侧盖板一样高（外端垫高一点），
  // 球冲过缝不会撞上远侧盖板的侧面被弹回缝里；远侧是平的，没挡住的球从它上面滚出去。
  final nearLid = _plank(edge, lidTop - (slotNear - edge).abs() * _between(random, (9, 14)) ~/ 100, slotNear, lidTop, lidHalf);
  final farLid = PourBlock(x: (slotFar + far) ~/ 2, y: cup.top - lidHalf, halfWidth: (far - slotFar).abs() ~/ 2, halfHeight: lidHalf, angle: 0);
  final endX = edge + toward * _between(random, (0, 12)), endY = (_topAt(nearLid, endX) - _between(random, (14, 22))).round();
  // 两个球隔开一点：前一个落进缝里了后一个再到。
  final slope = _slope(random, toward: toward, endX: endX, endY: endY, span: span, grade: grade, count: recipe.balls, spacing: (70, 90));
  if (slope == null) return null;
  final stopX = slotFar - toward * 3;
  final stopper = [stopX + toward * _between(random, (0, 10)), lidTop - _between(random, (56, 76)), stopX, lidTop + 4];
  return _Layout(
    balls: slope.balls,
    cup: cup,
    blocks: [nearLid, farLid],
    strokes: [slope.stroke, stopper],
    lanes: [
      ...slope.lanes,
      _Lane(endX.toDouble(), lidTop - 18.0, stopX - toward * 23.0, lidTop - 18.0, pourBallRadius + 12),
      _Lane(stopX.toDouble(), stopper[1].toDouble(), stopX.toDouble(), lidTop.toDouble(), pourLineRadius + 10, ramp: true),
      _Lane(stopX - toward * 26.0, lidTop - 18.0, stopX - toward * 26.0, cup.bottom - 18.0, pourBallRadius + 12),
    ],
    misses: [[slope.stroke], [stopper]],
  );
}

// 两笔折返：球在杯子正上方，中间横着一块挡板（什么都不画时球落在挡板上停住）。参考解两笔：第一笔从球下方往外斜下、越过挡板外沿；
// 第二笔先竖着一小段挡住飞出来的球，再从挡板下面斜着引回杯口近侧。少画哪一笔都进不了。
_Layout? _switchback(PuzzleRandom random, _Recipe recipe) {
  final outward = random.chance(.5) ? 1 : -1;
  final width = _between(random, (95, 115));
  final depth = _between(random, (72, 90));
  final bottom = _between(random, (700, 760));
  final reach = (width + 1) ~/ 2 + pourCupWall + _between(random, (30, 60));
  final beyond = _between(random, (30, 50)), lip = _between(random, (60, 90));
  // 杯子离内侧棋盘边的距离：内侧放得下杯壁与第一笔起点，外侧放得下挡板外沿、第一笔末端与竖挡。
  final low = math.max((width + 1) ~/ 2 + pourCupWall + 16, 90), high = pourWidth - (reach + beyond + lip + 24);
  if (low > high) return null;
  final offset = _between(random, (low, high));
  final cup = PourCup(x: outward > 0 ? offset : pourWidth - offset, bottom: bottom, width: width, depth: depth);
  final roofY = cup.top - _between(random, (170, 240)), roofHalf = _between(random, (10, 13));
  final roof = PourBlock(x: cup.x + _between(random, (-10, 10)), y: roofY, halfWidth: reach, halfHeight: roofHalf, angle: _between(random, (-4, 4)));
  final edge = cup.x + outward * reach;
  final endX = edge + outward * beyond, endY = roofY - roofHalf - _between(random, (64, 100));
  final ballX = cup.x - outward * _between(random, (0, 20));
  final startX = ballX - outward * _between(random, (30, 50));
  final grade = _between(random, (25, 45));
  final startY = endY - (endX - startX).abs() * grade ~/ 100;
  int rampY(int x) => startY + (x - startX) * outward * grade ~/ 100;
  final fall = _between(random, (40, 100));
  final balls = <int>[];
  final lanes = <_Lane>[..._rampLanes(startX, startY, endX, endY)];
  var x = ballX;
  for (var count = 0; count < recipe.balls; count++) {
    final y = rampY(x) - fall - pourBallRadius - pourLineRadius + (count == 0 ? 0 : _between(random, (-12, 12)));
    if (y < 40 || (endX - x) * outward < 80) return null;
    balls.addAll([x, y]);
    lanes.add(_Lane(x.toDouble(), y.toDouble(), x.toDouble(), rampY(x) - _lift(startX, startY, endX, endY), pourBallRadius + 12));
    x += outward * _between(random, (44, 52));
  }
  // 第二笔：竖挡的顶比第一笔末端高一点，底下接一段斜坡穿过挡板下方、停在杯口近侧上方。
  final over = _between(random, (8, 22)), gap = _between(random, (12, 28));
  final lipX = endX + outward * lip, lipTop = endY - _between(random, (10, 30));
  final finishX = cup.x + outward * (width ~/ 2 - over), finishY = cup.top - gap - pourLineRadius;
  final lipBottom = finishY - (lipX - finishX).abs() * _between(random, (18, 40)) ~/ 100;
  if (lipBottom - endY < pourBallRadius * 2 + 30 || lipBottom - lipTop < 60) return null;
  // 第二笔在挡板外沿处离挡板底面要留出球滚过的空间。
  final underRoof = lipBottom + (lipX - edge).abs() * (finishY - lipBottom) ~/ (lipX - finishX).abs();
  if (underRoof - (roofY + roofHalf) < pourBallRadius * 2 + pourLineRadius + 16) return null;
  lanes
    ..add(_Lane(endX.toDouble(), endY - pourBallRadius - pourLineRadius.toDouble(), endX + outward * 40.0, lipBottom - pourBallRadius - 20.0, pourBallRadius + 12))
    ..add(_Lane(lipX.toDouble(), lipTop.toDouble(), lipX.toDouble(), lipBottom.toDouble(), pourLineRadius + 10, ramp: true))
    ..addAll(_rampLanes(lipX, lipBottom, finishX, finishY))
    ..add(_into(finishX, finishY, cup));
  final first = [startX, startY, endX, endY], second = [lipX, lipTop, lipX, lipBottom, finishX, finishY];
  final layout = _Layout(balls: balls, cup: cup, strokes: [first, second], lanes: lanes, misses: [[first], [second]]);
  if (!_fits(layout, roof)) return null;
  layout.blocks.add(roof);
  return layout;
}

// 模拟一次，记下第一个球每一步的球心（缓冲接住按它摆挡板）。
(PourOutcome, List<double>) _trace(PourPuzzle puzzle, List<List<int>> strokes) {
  final simulation = PourSimulation(puzzle, strokes);
  final path = <double>[];
  try {
    while (simulation.outcome == PourOutcome.running) {
      simulation.step();
      final ball = simulation.ball(0);
      path
        ..add(ball.x)
        ..add(ball.y);
    }
    return (simulation.outcome, path);
  } finally {
    simulation.dispose();
  }
}

// 摆随机障碍：一半贴着参考线（在线的上方或下方，留出通道），其余在棋盘里随便放；第一块尽量放在球正下方、坡道底下，
// 什么都不画时球会砸在它上面。每块试若干次放不下就换一张草图。
bool _placeBlocks(PuzzleRandom random, _Layout layout, int count) {
  for (var index = 0; index < count; index++) {
    var placed = false;
    for (var attempt = 0; attempt < 60 && !placed; attempt++) {
      final plank = random.chance(.6);
      final halfWidth = plank ? _between(random, (36, 80)) : _between(random, (20, 32));
      final halfHeight = plank ? _between(random, (9, 13)) : halfWidth;
      final angle = plank ? _between(random, (-35, 35)) : _between(random, (-20, 20));
      final int x, y;
      final ramps = layout.ramps;
      final mode = index == 0 && attempt < 20 ? 0 : (ramps.isNotEmpty && random.chance(.6) ? 1 : 2);
      if (mode == 0) {
        x = layout.balls[0] + _between(random, (-16, 16));
        y = layout.balls[1] + _between(random, (160, 360));
      } else if (mode == 1) {
        final lane = random.pick(ramps);
        final t = _between(random, (10, 90)) / 100;
        final length = _distance(lane.x1, lane.y1, lane.x2, lane.y2);
        final side = random.chance(.5) ? 1 : -1;
        final push = (pourBallRadius * 2 + 40 + halfHeight + _between(random, (0, 60))) * side;
        x = (lane.x1 + (lane.x2 - lane.x1) * t + (lane.y2 - lane.y1) / length * push).round();
        y = (lane.y1 + (lane.y2 - lane.y1) * t - (lane.x2 - lane.x1) / length * push).round();
      } else {
        x = _between(random, (40, pourWidth - 40));
        y = _between(random, (120, layout.cup.bottom));
      }
      final block = PourBlock(x: x, y: y, halfWidth: halfWidth, halfHeight: halfHeight, angle: angle);
      if (_fits(layout, block)) {
        layout.blocks.add(block);
        placed = true;
      }
    }
    if (!placed) return false;
  }
  return true;
}

// 杯子外沿（含杯壁）。
List<double> _cupOutline(PourCup cup) => [cup.left - pourCupWall, cup.top.toDouble(), cup.right + pourCupWall, cup.top.toDouble(), cup.right + pourCupWall, cup.bottom + pourCupWall.toDouble(), cup.left - pourCupWall, cup.bottom + pourCupWall.toDouble()];

// 一块障碍放得下：在棋盘里，不挡通道，离杯子、球、别的障碍与风车都留出空隙。
bool _fits(_Layout layout, PourBlock block) {
  final corners = block.corners;
  for (var index = 0; index < corners.length; index += 2) {
    if (corners[index] < 10 || corners[index] > pourWidth - 10 || corners[index + 1] < 60 || corners[index + 1] > pourHeight - 10) return false;
  }
  for (final lane in layout.lanes) {
    if (_polygonSegment(corners, lane.x1, lane.y1, lane.x2, lane.y2) < lane.clearance) return false;
  }
  if (_polygonPolygon(corners, _cupOutline(layout.cup)) < 24) return false;
  for (var index = 0; index < layout.balls.length; index += 2) {
    if (_polygonPoint(corners, layout.balls[index].toDouble(), layout.balls[index + 1].toDouble()) < pourBallRadius + 24) return false;
  }
  for (final spinner in layout.spinners) {
    if (_polygonPoint(corners, spinner.x.toDouble(), spinner.y.toDouble()) < spinner.halfLength + 20) return false;
  }
  return layout.blocks.every((other) => _polygonPolygon(corners, other.corners) >= 20);
}

// 一根风车杆放得下：扫过的圆在棋盘里，离通道、杯子、球与障碍都留出空隙。
bool _spinnerFits(_Layout layout, PourSpinner spinner) {
  final x = spinner.x.toDouble(), y = spinner.y.toDouble(), reach = spinner.halfLength;
  if (x - reach < 10 || x + reach > pourWidth - 10 || y - reach < 60 || y + reach > pourHeight - 10) return false;
  for (final lane in layout.lanes) {
    if (_pointSegment(x, y, lane.x1, lane.y1, lane.x2, lane.y2) < reach + lane.clearance) return false;
  }
  if (_polygonPoint(_cupOutline(layout.cup), x, y) < reach + 24) return false;
  for (var index = 0; index < layout.balls.length; index += 2) {
    if (_distance(x, y, layout.balls[index], layout.balls[index + 1]) < reach + pourBallRadius + 24) return false;
  }
  return layout.blocks.every((block) => _polygonPoint(block.corners, x, y) >= reach + 20);
}

// 照手指画的样子重描一笔：沿线从 first 起每走 pourMinSegment 取一个点（同页面记点），拐角被削掉一点，末尾不够一段的那截丢掉
// （检查画得不那么准也能进；first 取两种，点落在不同位置）。
List<int> _traced(List<int> stroke, int first) {
  final traced = [stroke[0], stroke[1]];
  var carry = (pourMinSegment - first).toDouble();
  for (var index = 2; index + 1 < stroke.length; index += 2) {
    final x1 = stroke[index - 2], y1 = stroke[index - 1], x2 = stroke[index], y2 = stroke[index + 1];
    final length = _distance(x1, y1, x2, y2);
    for (var at = pourMinSegment - carry; at <= length; at += pourMinSegment) {
      traced.addAll([(x1 + (x2 - x1) * at / length).round(), (y1 + (y2 - y1) * at / length).round()]);
    }
    carry = (carry + length) % pourMinSegment;
  }
  return traced.length >= 4 ? traced : stroke;
}

// 参考线整体上下平移（检查参考线挪一点也能进）。
List<List<int>> _shift(List<List<int>> strokes, int dy) => [
  for (final stroke in strokes) [for (var index = 0; index < stroke.length; index++) index.isOdd ? stroke[index] + dy : stroke[index]],
];

// ---------- 几何 ----------

double _distance(num x1, num y1, num x2, num y2) {
  final dx = x2 - x1, dy = y2 - y1;
  return math.sqrt(dx * dx + dy * dy);
}

double _pointSegment(double px, double py, double x1, double y1, double x2, double y2) {
  final dx = x2 - x1, dy = y2 - y1, length = dx * dx + dy * dy;
  final t = length == 0 ? 0.0 : (((px - x1) * dx + (py - y1) * dy) / length).clamp(0.0, 1.0);
  return _distance(px, py, x1 + dx * t, y1 + dy * t);
}

double _cross(double ox, double oy, double ax, double ay, double bx, double by) => (ax - ox) * (by - oy) - (ay - oy) * (bx - ox);

double _segmentSegment(double ax, double ay, double bx, double by, double cx, double cy, double dx, double dy) {
  final d1 = _cross(cx, cy, dx, dy, ax, ay), d2 = _cross(cx, cy, dx, dy, bx, by), d3 = _cross(ax, ay, bx, by, cx, cy), d4 = _cross(ax, ay, bx, by, dx, dy);
  if (((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))) return 0;
  return math.min(math.min(_pointSegment(ax, ay, cx, cy, dx, dy), _pointSegment(bx, by, cx, cy, dx, dy)), math.min(_pointSegment(cx, cy, ax, ay, bx, by), _pointSegment(dx, dy, ax, ay, bx, by)));
}

// 点在凸多边形里（各边叉积同号）。
bool _inside(List<double> polygon, double x, double y) {
  var sign = 0;
  for (var index = 0; index < polygon.length; index += 2) {
    final next = (index + 2) % polygon.length;
    final cross = _cross(polygon[index], polygon[index + 1], polygon[next], polygon[next + 1], x, y);
    if (cross == 0) continue;
    final side = cross > 0 ? 1 : -1;
    if (sign != 0 && side != sign) return false;
    sign = side;
  }
  return true;
}

double _polygonPoint(List<double> polygon, double x, double y) {
  if (_inside(polygon, x, y)) return 0;
  var best = double.infinity;
  for (var index = 0; index < polygon.length; index += 2) {
    final next = (index + 2) % polygon.length;
    best = math.min(best, _pointSegment(x, y, polygon[index], polygon[index + 1], polygon[next], polygon[next + 1]));
  }
  return best;
}

double _polygonSegment(List<double> polygon, double x1, double y1, double x2, double y2) {
  if (_inside(polygon, x1, y1) || _inside(polygon, x2, y2)) return 0;
  var best = double.infinity;
  for (var index = 0; index < polygon.length; index += 2) {
    final next = (index + 2) % polygon.length;
    best = math.min(best, _segmentSegment(polygon[index], polygon[index + 1], polygon[next], polygon[next + 1], x1, y1, x2, y2));
  }
  return best;
}

// 两个凸多边形的距离：任一条边与对方相交或一方的顶点在另一方里面就是 0（两块细长板十字交叉时顶点都在外面，所以逐边查）。
double _polygonPolygon(List<double> first, List<double> second) {
  var best = double.infinity;
  for (var index = 0; index < first.length; index += 2) {
    final next = (index + 2) % first.length;
    best = math.min(best, _polygonSegment(second, first[index], first[index + 1], first[next], first[next + 1]));
  }
  return best;
}
