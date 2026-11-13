import 'dart:math' as math;

import 'package:forge2d/forge2d.dart';

import 'package:superxd/playground/puzzle_rules.dart';

// 画线入杯：上方几个小球、下方一只杯子、中间几块固定的障碍。玩家用有限的墨水画线（松手后成为固定不动的刚体），
// 点「放球」后小球在重力下落，全部滚进杯子并停稳才算过关。
// 物理模拟用 forge2d（Box2D v3 的 Dart 绑定，原生库经 FFI 调用，不依赖 Flutter），规则与页面跑的是同一份 PourSimulation。
// 坐标是整数单位，1 单位当 1 厘米：棋盘 pourWidth × pourHeight，y 朝下（重力也朝下）；送进物理世界时除以 100 换成米（Box2D 按米调参）。
// 判定的稳定性：模拟是固定步长、固定子步数、按同一顺序建物体的确定性计算，同一台设备上同一道题同一种画法每次结果一样；
// 换平台（arm64 与 x64、不同编译器）浮点细节可能有微小差异、边缘情况会走向不同结果，所以这个游戏只进自由模式（challengeable 为假），
// 不承诺跨设备逐位复现。出题时只有坐标取整等整数运算用 PuzzleRandom，验证可解靠同一份模拟。

const pourWidth = 600, pourHeight = 800;
const pourBallRadius = 18;
// 线的半宽（画出来的线宽是它的两倍）。
const pourLineRadius = 5;
const pourCupWall = 12;
// 线离球的起点至少这么远（球半径加线半径再留一点），否则放球那一刻球就压在线上。
const pourBallClearance = pourBallRadius + pourLineRadius + 6;
const pourMaxBalls = 3, pourMaxBlocks = 6, pourMaxInk = 3000;
// 答案的上限：笔数与总点数（页面每走 pourMinSegment 记一个点，满墨水也远用不到）。
const pourMaxStrokes = 20, pourMaxPoints = 800;
const pourMinSegment = 8;
// 模拟的固定步长与最长时长（12 秒）；页面每帧按真实流逝的时间推进若干步。
const pourStep = 1 / 60;
const pourMaxSteps = 60 * 12;

// 一块固定的障碍：中心、半宽、半高与转角（度，y 朝下所以正角是顺时针）。
class PourBlock {
  const PourBlock({required this.x, required this.y, required this.halfWidth, required this.halfHeight, required this.angle});
  final int x, y, halfWidth, halfHeight, angle;

  // 四个角，按 x、y 交替排（顺序绕一圈）。
  List<double> get corners {
    final radians = angle * math.pi / 180, cos = math.cos(radians), sin = math.sin(radians);
    return [
      for (final (dx, dy) in [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]) ...[x + dx * cos - dy * sin, y + dx * sin + dy * cos],
    ];
  }
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
  const PourPuzzle({required this.balls, required this.cup, required this.blocks, required this.ink});
  // 球的起点，按 x、y 交替排。
  final List<int> balls;
  final PourCup cup;
  final List<PourBlock> blocks;
  // 墨水：所有线的总长上限（单位）。
  final int ink;

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
  final _balls = <Body>[];
  int steps = 0;
  PourOutcome outcome = PourOutcome.running;
  int _settled = 0, _resting = 0;

  static Vector2 _meters(num x, num y) => Vector2(x / 100, y / 100);

  // 第 index 个球此刻的球心（单位）与转角（弧度）。
  ({double x, double y, double angle}) ball(int index) {
    final body = _balls[index], position = body.position;
    return (x: position.x * 100, y: position.y * 100, angle: body.angle);
  }

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

// 每档的参数：球数、随机障碍数、杯内宽、坡道的水平跨度、坡度（百分比，竖直落差除以水平跨度）、墨水是参考线长的几倍（百分比）、
// 是否折返（专家：球就在杯子正上方，中间横着一块挡板，参考解是先往外引、再用第二笔接住引回杯口）。
typedef _Tier = ({int balls, int blocks, (int, int) cup, (int, int) span, (int, int) grade, (int, int) ink, bool switchback});

const Map<PuzzleTier, _Tier> _tiers = {
  PuzzleTier.entry: (balls: 1, blocks: 0, cup: (130, 150), span: (150, 230), grade: (35, 60), ink: (220, 260), switchback: false),
  PuzzleTier.easy: (balls: 1, blocks: 1, cup: (115, 135), span: (190, 290), grade: (32, 60), ink: (180, 210), switchback: false),
  PuzzleTier.normal: (balls: 1, blocks: 2, cup: (100, 120), span: (280, 400), grade: (25, 50), ink: (155, 180), switchback: false),
  PuzzleTier.hard: (balls: 2, blocks: 2, cup: (100, 120), span: (220, 340), grade: (28, 50), ink: (140, 160), switchback: false),
  PuzzleTier.expert: (balls: 2, blocks: 1, cup: (95, 115), span: (0, 0), grade: (25, 45), ink: (125, 140), switchback: true),
};

// 难度分里「墨水紧」的分界：墨水除以最远的球到杯口近侧内沿的直线距离，低于这一类的分界加 1 分（分界取各类出题的中位数附近）。
const _tight = [2.1, 1.8, 1.7, 1.45, 1.85];

class PourRules extends PuzzleRules<PourPuzzle, List<List<int>>> {
  const PourRules();

  // 出题：先按档搭出一条参考线（一段把球引向杯口的斜坡，专家是两笔折返），再在不挡参考线的地方摆障碍；
  // 用同一份模拟确认「画了参考线放球能进杯」、参考线整体上下挪 6 单位也照样进（不是卡在刀刃上的题），并且「什么都不画放球进不了杯」，才用。
  @override
  PuzzleDraw<PourPuzzle, List<List<int>>> generate(int seed, PuzzleTier tier) {
    final random = PuzzleRandom(seed);
    final spec = _tiers[tier]!;
    while (true) {
      final layout = spec.switchback ? _switchback(random, spec) : _ramp(random, spec);
      if (layout == null || !_placeBlocks(random, layout, spec.blocks)) continue;
      final length = pourInkUsed(layout.strokes);
      final ink = ((length * _between(random, spec.ink) / 100) / 10).ceil() * 10;
      final puzzle = PourPuzzle(balls: layout.balls, cup: layout.cup, blocks: layout.blocks, ink: math.min(ink, pourMaxInk));
      if (!pourAnswerValid(puzzle, layout.strokes)) continue;
      if (pourSimulate(puzzle, layout.strokes) != PourOutcome.won) continue;
      if (pourSimulate(puzzle, _shift(layout.strokes, -6)) != PourOutcome.won || pourSimulate(puzzle, _shift(layout.strokes, 6)) != PourOutcome.won) continue;
      if (pourSimulate(puzzle, const []) == PourOutcome.won) continue;
      return PuzzleDraw(puzzle, layout.strokes);
    }
  }

  @override
  bool solved(PourPuzzle puzzle, List<List<int>> answer) => pourAnswerValid(puzzle, answer) && pourSimulate(puzzle, answer) == PourOutcome.won;

  // 难度分：先按结构分五类（单球没有障碍、单球一块、单球两块及以上、多球、多球且球在杯子正上方要折返），各占两分，
  // 再看墨水：墨水比这一类的分界紧就加 1。同一档出的题结构相同，所以同档相差最多 1 分，档与档之间不重叠。
  @override
  int difficulty(PourPuzzle puzzle) {
    final cup = puzzle.cup;
    var reach = 0.0, above = false;
    for (var index = 0; index < puzzle.balls.length; index += 2) {
      final x = puzzle.balls[index], y = puzzle.balls[index + 1];
      above = above || (x > cup.left - pourCupWall && x < cup.right + pourCupWall);
      reach = math.max(reach, math.sqrt(math.pow(x - (x < cup.x ? cup.left : cup.right), 2) + math.pow(y - cup.top, 2)));
    }
    final rank = puzzle.ballCount == 1 ? math.min(puzzle.blocks.length, 2) : (above ? 4 : 3);
    final tight = puzzle.ink / math.max(reach, 100) < _tight[rank];
    return 1 + rank * 2 + (tight ? 1 : 0);
  }

  @override
  Object encodePuzzle(PourPuzzle puzzle) => {
    'balls': puzzle.balls,
    'cup': [puzzle.cup.x, puzzle.cup.bottom, puzzle.cup.width, puzzle.cup.depth],
    'blocks': [for (final block in puzzle.blocks) ...[block.x, block.y, block.halfWidth, block.halfHeight, block.angle]],
    'ink': puzzle.ink,
  };

  // 解码校验：球、杯、障碍都在棋盘里、尺寸在范围内，球与球、球与障碍和杯壁不重叠（重叠的话放球那一刻会被弹飞）。
  @override
  PourPuzzle decodePuzzle(Object? json) {
    if (json is! Map) throw const FormatException('题目不合法');
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
    final ink = puzzleInt(json, 'ink', min: 50, max: pourMaxInk);
    final walls = [for (final (left, top, right, bottom) in cup.walls) [left, top, right, top, right, bottom, left, bottom]];
    for (var index = 0; index < balls.length; index += 2) {
      final x = balls[index].toDouble(), y = balls[index + 1].toDouble();
      for (var other = index + 2; other < balls.length; other += 2) {
        if (_distance(x, y, balls[other], balls[other + 1]) < pourBallRadius * 2) throw const FormatException('题目里的球重叠');
      }
      for (final polygon in [for (final block in blocks) block.corners, ...walls]) {
        if (_polygonPoint(polygon, x, y) < pourBallRadius) throw const FormatException('题目里的球压在障碍上');
      }
    }
    return PourPuzzle(balls: balls, cup: cup, blocks: blocks, ink: ink);
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

// 一张草图：球、杯、参考线，和摆障碍时要让开的通道（球会经过的路线，每段带要让开的距离）。
class _Layout {
  _Layout({required this.balls, required this.cup, required this.strokes, required this.lanes});
  final List<int> balls;
  final PourCup cup;
  final List<List<int>> strokes;
  final List<_Lane> lanes;
  final blocks = <PourBlock>[];
  // 摆随机障碍时优先放在参考线附近（不挡路，但挡住别的画法），这里记下参考线的各段。
  List<_Lane> get ramps => [for (final lane in lanes) if (lane.ramp) lane];
}

class _Lane {
  const _Lane(this.x1, this.y1, this.x2, this.y2, this.clearance, {this.ramp = false});
  final double x1, y1, x2, y2, clearance;
  final bool ramp;
}

int _between(PuzzleRandom random, (int, int) range) => range.$1 + random.nextInt(range.$2 - range.$1 + 1);

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
List<_Lane> _rampLanes(double x1, double y1, double x2, double y2) => [_Lane(x1, y1, x2, y2, pourLineRadius + 10, ramp: true), _rolling(x1, y1, x2, y2)];

double _lift(double x1, double y1, double x2, double y2) => (pourBallRadius + pourLineRadius) * _distance(x1, y1, x2, y2) / (x2 - x1).abs();

// 入门到困难：球在一侧上方，一段直坡从球下方斜着通到杯口近侧（略探进杯口、高出杯沿一点），球顺坡滚下、越过近侧杯沿落进杯里，远侧杯壁挡住不飞出去。
_Layout? _ramp(PuzzleRandom random, _Tier spec) {
  final toward = random.chance(.5) ? 1 : -1;
  final width = _between(random, spec.cup);
  final depth = spec.balls > 1 ? _between(random, (72, 90)) : _between(random, (60, 80));
  final bottom = _between(random, (690, 760));
  final span = _between(random, spec.span), grade = _between(random, spec.grade);
  final gap = _between(random, (12, 28)), over = _between(random, (8, 22));
  // 杯子离球那一侧棋盘边的距离：坡道起点离边至少 30，杯子外沿离另一边至少 8。
  final low = 30 + span + width ~/ 2 - over, high = pourWidth - 8 - pourCupWall - (width + 1) ~/ 2;
  if (low > high) return null;
  final offset = _between(random, (low, high));
  final cup = PourCup(x: toward > 0 ? offset : pourWidth - offset, bottom: bottom, width: width, depth: depth);
  final endX = cup.x - toward * (width ~/ 2 - over), endY = cup.top - gap - pourLineRadius;
  final startX = endX - toward * span, startY = endY - span * grade ~/ 100;
  if (startY < 150) return null;
  int rampY(int x) => startY + (x - startX) * toward * grade ~/ 100;
  final balls = <int>[];
  final lanes = <_Lane>[..._rampLanes(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble())];
  var ballX = startX + toward * _between(random, (30, math.max(30, math.min(90, span * 35 ~/ 100))));
  final fall = _between(random, (50, 140));
  final ballY = rampY(ballX) - fall - pourBallRadius - pourLineRadius;
  for (var count = 0; count < spec.balls; count++) {
    final y = ballY + (count == 0 ? 0 : _between(random, (-20, 20)));
    // 每个球都要落在坡道的上半段，离坡道末端至少 80。
    if (y < 40 || (endX - ballX) * toward < 80) return null;
    balls.addAll([ballX, y]);
    lanes.add(_Lane(ballX.toDouble(), y.toDouble(), ballX.toDouble(), rampY(ballX) - _lift(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble()), pourBallRadius + 12));
    ballX += toward * _between(random, (44, 56));
  }
  // 从坡道末端落进杯底。
  lanes.add(_Lane(endX.toDouble(), endY - pourBallRadius - pourLineRadius.toDouble(), cup.x.toDouble(), (bottom - pourBallRadius).toDouble(), pourBallRadius + 12));
  return _Layout(balls: balls, cup: cup, strokes: [[startX, startY, endX, endY]], lanes: lanes);
}

// 专家：球在杯子正上方，中间横着一块挡板（什么都不画时球落在挡板上停住）。参考解两笔：第一笔从球下方往外斜下、越过挡板外沿；
// 第二笔先竖着一小段挡住飞出来的球，再从挡板下面斜着引回杯口近侧。
_Layout? _switchback(PuzzleRandom random, _Tier spec) {
  final outward = random.chance(.5) ? 1 : -1;
  final width = _between(random, spec.cup);
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
  final grade = _between(random, spec.grade);
  final startY = endY - (endX - startX).abs() * grade ~/ 100;
  int rampY(int x) => startY + (x - startX) * outward * grade ~/ 100;
  final fall = _between(random, (40, 100));
  final balls = <int>[];
  final lanes = <_Lane>[..._rampLanes(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble())];
  var x = ballX;
  for (var count = 0; count < spec.balls; count++) {
    final y = rampY(x) - fall - pourBallRadius - pourLineRadius + (count == 0 ? 0 : _between(random, (-12, 12)));
    if (y < 40 || (endX - x) * outward < 80) return null;
    balls.addAll([x, y]);
    lanes.add(_Lane(x.toDouble(), y.toDouble(), x.toDouble(), rampY(x) - _lift(startX.toDouble(), startY.toDouble(), endX.toDouble(), endY.toDouble()), pourBallRadius + 12));
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
    ..addAll(_rampLanes(lipX.toDouble(), lipBottom.toDouble(), finishX.toDouble(), finishY.toDouble()))
    ..add(_Lane(finishX.toDouble(), finishY - pourBallRadius - pourLineRadius.toDouble(), cup.x.toDouble(), (bottom - pourBallRadius).toDouble(), pourBallRadius + 12));
  final layout = _Layout(balls: balls, cup: cup, strokes: [[startX, startY, endX, endY], [lipX, lipTop, lipX, lipBottom, finishX, finishY]], lanes: lanes);
  if (!_fits(layout, roof)) return null;
  layout.blocks.add(roof);
  return layout;
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
      final mode = index == 0 && attempt < 20 ? 0 : (random.chance(.6) ? 1 : 2);
      if (mode == 0) {
        x = layout.balls[0] + _between(random, (-16, 16));
        y = layout.balls[1] + _between(random, (160, 360));
      } else if (mode == 1) {
        final lane = random.pick(layout.ramps);
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

// 一块障碍放得下：在棋盘里，不挡通道，离杯子、球与别的障碍都留出空隙。
bool _fits(_Layout layout, PourBlock block) {
  final corners = block.corners;
  for (var index = 0; index < corners.length; index += 2) {
    if (corners[index] < 10 || corners[index] > pourWidth - 10 || corners[index + 1] < 60 || corners[index + 1] > pourHeight - 10) return false;
  }
  for (final lane in layout.lanes) {
    if (_polygonSegment(corners, lane.x1, lane.y1, lane.x2, lane.y2) < lane.clearance) return false;
  }
  final cup = layout.cup;
  final outer = [cup.left - pourCupWall, cup.top.toDouble(), cup.right + pourCupWall, cup.top.toDouble(), cup.right + pourCupWall, cup.bottom + pourCupWall.toDouble(), cup.left - pourCupWall, cup.bottom + pourCupWall.toDouble()];
  if (_polygonPolygon(corners, outer) < 24) return false;
  for (var index = 0; index < layout.balls.length; index += 2) {
    if (_polygonPoint(corners, layout.balls[index].toDouble(), layout.balls[index + 1].toDouble()) < pourBallRadius + 24) return false;
  }
  return layout.blocks.every((other) => _polygonPolygon(corners, other.corners) >= 20);
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
