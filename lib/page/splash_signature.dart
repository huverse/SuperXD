import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

// 开屏一笔写出的「SuperXD」（同苹果开机的 hello，人工决策见 painting_splash.dart 类上）：连笔草书，Super 一笔连写，X 两笔，D 一笔，
// 按书写顺序逐笔画出，单线等宽、圆头。
// 字形就是下面的节点：_K(x, y) 是曲线自由经过的点，_K(x, y, 方向) 指定笔尖经过这里时前进的方向（度，0 向右、90 向上）；
// 同一点连写两次是尖角（前一个写到达方向、后一个写离开方向，笔在这里折返）。设计坐标直立书写、y 向上：基线 0、x 高 100、大写高约 240、下伸 100，
// 运行时整体右斜 15°。相邻节点之间按 Hobby 曲线（METAFONT 设计字形的同一套）求切线与控制柄：自由节点处曲率连续，弯得匀、不打折。改字形只改节点。
class _K {
  const _K(this.x, this.y, [this.heading]);
  final double x, y;
  final double? heading;
}

const _strokes = <List<_K>>[
  // Super：一笔连写。
  [
    // S：左下起笔斜上，上半个碗逆时针绕回、和起笔交叉，右腹鼓出落到基线，回勾碰到起笔再原路折回，向右上连 u。
    _K(0, 12, 22), _K(70, 70), _K(128, 150), _K(168, 222, 80), _K(148, 246, 180), _K(100, 200, 270), _K(122, 152), _K(198, 78, 270), _K(128, 0, 180),
    _K(72, 22), _K(58, 48, 115), _K(58, 48, 295), _K(72, 22), _K(128, 0, 0), _K(190, 12), _K(245, 70), _K(258, 100, 80),
    // u：两个尖顶、两个圆底。
    _K(258, 100, 268), _K(256, 40, 270), _K(279, 0, 0), _K(313, 50), _K(328, 100, 82),
    _K(328, 100, 268), _K(326, 40, 270), _K(349, 0, 0), _K(385, 45),
    // p：竖笔落到下伸再原路折回，向右绕一个碗回到竖笔，沿碗底折回连 e。
    _K(410, 112, 80), _K(410, 112, 267), _K(404, -100, 267), _K(404, -100, 87), _K(408, 68, 87), _K(443, 102, 0), _K(475, 52, 270),
    _K(445, 0, 180), _K(415, 16, 135), _K(415, 16, -45), _K(445, 0, 0),
    // e：一个水滴形的圈。
    _K(493, 40), _K(528, 90), _K(513, 103, 180), _K(493, 60, 270), _K(518, 0, 0), _K(558, 40),
    // r：竖笔落到基线折回，向右起一个肩，收在右下。
    _K(588, 104, 78), _K(588, 104, 268), _K(585, 0, 268), _K(585, 0, 88), _K(587, 55, 88), _K(614, 98, 0), _K(642, 72, -65),
  ],
  // X：左上带钩，落到右下上挑收笔。
  [_K(662, 188, 70), _K(684, 224, 0), _K(705, 205), _K(784, 32), _K(814, 0, 0), _K(846, 30, 55)],
  // X：右上略带弧度落到左下。
  [_K(830, 226, 240), _K(762, 120), _K(714, 40), _K(684, 2, 235)],
  // D：竖下来圆转，绕大碗回到顶上，越过起笔收住。
  [_K(890, 205, 266), _K(885, 40, 268), _K(917, 0, 0), _K(997, 112, 90), _K(927, 240, 180), _K(877, 230), _K(857, 206, 245)],
];

// 线宽（设计单位，随签名一起缩放，约 x 高的六分之一）与右斜。
const _weight = 17.0;
final _shear = math.tan(15 * math.pi / 180);

// 书写节奏按人手书写的三分之二幂律：笔速与曲率的负三分之一次方成正比，弯越急越慢；每 2 个设计单位取一次样。
// 直线上按半径约 170 的弯算（不至于一闪而过）；起笔、收笔前后约 70 个单位里加速、减速（最慢到四分之一），尖角前后约 18 个单位里减速折返；
// 笔画之间提笔：停顿占书写的 3%，再加上笔尖在空中移到下一笔起点的时间（同样距离约是书写的三成）。
const _step = 2.0;
const _flat = .006;
const _ends = (distance: 70.0, slowest: .25);
const _cusp = (distance: 18.0, slowest: .45);
const _lift = .03;
const _air = .3;

class SplashSignature {
  SplashSignature._(this._metrics, this._costs, this._lifts, this.bounds);

  static final shared = SplashSignature._build();

  final List<PathMetric> _metrics;
  // 每一笔沿长度的累计书写耗时（任意单位，每 _step 一格），进度按它换成画到的长度。
  final List<Float64List> _costs;
  // 前后两笔之间提笔的耗时。
  final List<double> _lifts;
  // 墨迹占的范围（中心线向外半个线宽）。
  final Rect bounds;

  static SplashSignature _build() {
    final metrics = [for (final stroke in _strokes) _strokePath(stroke).computeMetrics().single];
    final costs = [for (final metric in metrics) _strokeCost(metric)];
    final drawing = costs.fold(0.0, (sum, cost) => sum + cost.last);
    final perUnit = drawing / metrics.fold(0.0, (sum, metric) => sum + metric.length);
    final lifts = [
      for (var index = 1; index < metrics.length; index++)
        drawing * _lift + (_point(metrics[index], 0) - _point(metrics[index - 1], metrics[index - 1].length)).distance * perUnit * _air,
    ];
    // 按曲线上的点算范围（Path.getBounds 含控制点，会偏大偏斜）。
    var bounds = Rect.fromCircle(center: _point(metrics.first, 0), radius: _weight / 2);
    for (final metric in metrics) {
      for (var offset = 0.0; offset < metric.length + _step; offset += _step) {
        bounds = bounds.expandToInclude(Rect.fromCircle(center: _point(metric, math.min(offset, metric.length)), radius: _weight / 2));
      }
    }
    return SplashSignature._(metrics, costs, lifts, bounds);
  }

  double get _total => _costs.fold(0.0, (sum, cost) => sum + cost.last) + _lifts.fold(0.0, (sum, lift) => sum + lift);

  // 进度 0–1 画到哪里：写完的笔整笔画，正在写的那笔画到对应长度，还没写到的不画。
  void paint(Canvas canvas, double progress, Paint paint) {
    var remaining = progress.clamp(0.0, 1.0) * _total;
    for (var index = 0; index < _metrics.length && remaining > 0; index++) {
      final metric = _metrics[index], cost = _costs[index];
      canvas.drawPath(metric.extractPath(0, remaining >= cost.last ? metric.length : _lengthAt(cost, remaining, metric.length)), paint);
      remaining -= cost.last + (index < _lifts.length ? _lifts[index] : 0);
    }
  }

  static Offset _point(PathMetric metric, double offset) => metric.getTangentForOffset(offset)!.position;

  static double _lengthAt(Float64List cost, double value, double length) {
    var low = 0, high = cost.length - 1;
    while (high - low > 1) {
      final middle = (low + high) ~/ 2;
      if (cost[middle] <= value) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final span = cost[high] - cost[low];
    final fraction = span <= 0 ? 0.0 : (value - cost[low]) / span;
    return math.min((low + fraction) * _step, length);
  }

  // 一笔的书写耗时：每格耗时 = 距离 ÷ 笔速；笔速按这一格的曲率，再乘起笔、收笔与尖角处的减速。一格里方向转过 60° 以上的是尖角。
  static Float64List _strokeCost(PathMetric metric) {
    final steps = (metric.length / _step).ceil();
    final offsets = [for (var index = 0; index <= steps; index++) math.min(index * _step, metric.length)];
    final angles = [for (final offset in offsets) metric.getTangentForOffset(offset)!.angle];
    final turns = [for (var index = 0; index < steps; index++) _turn(angles[index + 1] - angles[index])];
    final cusps = [
      for (var index = 0; index < steps; index++)
        if (turns[index] > math.pi / 3) (offsets[index] + offsets[index + 1]) / 2,
    ];
    final cost = Float64List(steps + 1);
    for (var index = 0; index < steps; index++) {
      final distance = offsets[index + 1] - offsets[index];
      final middle = offsets[index] + distance / 2;
      var speed = math.pow(turns[index] / distance + _flat, -1 / 3) * _ramp(middle, _ends) * _ramp(metric.length - middle, _ends);
      for (final cusp in cusps) {
        speed *= _ramp((middle - cusp).abs(), _cusp);
      }
      cost[index + 1] = cost[index] + distance / speed;
    }
    return cost;
  }

  // 离停笔处（起笔、收笔、尖角）越近越慢，最慢到 slowest。
  static double _ramp(double distance, ({double distance, double slowest}) ramp) => ramp.slowest + (1 - ramp.slowest) * (1 - math.exp(-distance / ramp.distance));

  static double _turn(double angle) {
    final turn = angle.abs() % (2 * math.pi);
    return turn > math.pi ? 2 * math.pi - turn : turn;
  }

  static Path _strokePath(List<_K> knots) {
    final start = _canvas(Offset(knots.first.x, knots.first.y));
    final path = Path()..moveTo(start.dx, start.dy);
    var first = 0;
    for (var index = 1; index < knots.length; index++) {
      final knot = knots[index], previous = knots[index - 1];
      if (knot.x == previous.x && knot.y == previous.y) {
        first = index;
      } else if (knot.heading != null) {
        _hobby(path, knots.sublist(first, index + 1));
        first = index;
      }
    }
    return path;
  }

  // 设计坐标（直立、y 向上）换成画布坐标：右斜、y 向下。
  static Offset _canvas(Offset point) => Offset(point.dx + point.dy * _shear, -point.dy);

  // 两端方向已知的一段：中间自由节点的方向按「两侧曲率相等」解三对角方程（Hobby 的 mock curvature），控制柄长度用 Knuth 的 velocity 函数；接着 path 的终点画。
  // theta 是离开节点时偏离弦的角度，phi 是到达节点时偏离弦的角度，psi 是弦在节点处转过的角度（都是逆时针为正）。
  static void _hobby(Path path, List<_K> knots) {
    final points = [for (final knot in knots) Offset(knot.x, knot.y)];
    final n = points.length - 1;
    final chords = [for (var k = 0; k < n; k++) points[k + 1] - points[k]];
    final psi = [0.0, for (var k = 1; k < n; k++) _wrap(chords[k].direction - chords[k - 1].direction)];
    final theta = Float64List(n)..[0] = _wrap(knots.first.heading! * math.pi / 180 - chords.first.direction);
    final phiEnd = _wrap(chords.last.direction - knots.last.heading! * math.pi / 180);
    // 第 k 个自由节点：theta[k-1]/d[k-1] + 2·theta[k]·(1/d[k-1] + 1/d[k]) + theta[k+1]/d[k] = −2·psi[k]/d[k-1] − psi[k+1]/d[k]，
    // 最后一个自由节点右边换成已知的 phiEnd/d[k]；追赶法消元、回代。
    final diagonal = Float64List(n), upper = Float64List(n), right = Float64List(n);
    for (var k = 1; k < n; k++) {
      final before = chords[k - 1].distance, after = chords[k].distance;
      diagonal[k] = 2 / before + 2 / after;
      upper[k] = k + 1 < n ? 1 / after : 0;
      right[k] = -2 * psi[k] / before + (k + 1 < n ? -psi[k + 1] / after : phiEnd / after);
      if (k == 1) {
        right[k] -= theta[0] / before;
      } else {
        final factor = 1 / before / diagonal[k - 1];
        diagonal[k] -= factor * upper[k - 1];
        right[k] -= factor * right[k - 1];
      }
    }
    for (var k = n - 1; k >= 1; k--) {
      theta[k] = (right[k] - (k + 1 < n ? upper[k] * theta[k + 1] : 0)) / diagonal[k];
    }
    for (var k = 0; k < n; k++) {
      final phi = k + 1 < n ? -psi[k + 1] - theta[k + 1] : phiEnd;
      final chord = chords[k];
      final c1 = _canvas(points[k] + Offset.fromDirection(chord.direction + theta[k], chord.distance * _velocity(theta[k], phi)));
      final c2 = _canvas(points[k + 1] - Offset.fromDirection(chord.direction - phi, chord.distance * _velocity(phi, theta[k])));
      final end = _canvas(points[k + 1]);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
    }
  }

  static double _velocity(double theta, double phi) {
    final sinTheta = math.sin(theta), sinPhi = math.sin(phi), cosTheta = math.cos(theta), cosPhi = math.cos(phi);
    return (2 + math.sqrt2 * (sinTheta - sinPhi / 16) * (sinPhi - sinTheta / 16) * (cosTheta - cosPhi)) /
        (3 * (1 + (math.sqrt(5) - 1) / 2 * cosTheta + (3 - math.sqrt(5)) / 2 * cosPhi));
  }

  static double _wrap(double angle) => angle - 2 * math.pi * (angle / (2 * math.pi)).roundToDouble();
}

// 把签名按比例放进给定大小、居中，线宽随签名缩放。墨色沿书写方向（从左到右）从 ink.$1 渐变到 ink.$2。
class SplashSignaturePainter extends CustomPainter {
  const SplashSignaturePainter({required this.progress, required this.ink});
  final double progress;
  final (Color, Color) ink;

  @override
  void paint(Canvas canvas, Size size) {
    final signature = SplashSignature.shared;
    final bounds = signature.bounds;
    final scale = math.min(size.width / bounds.width, size.height / bounds.height);
    canvas
      ..save()
      ..translate((size.width - bounds.width * scale) / 2, (size.height - bounds.height * scale) / 2)
      ..scale(scale)
      ..translate(-bounds.left, -bounds.top);
    signature.paint(
      canvas,
      progress,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = _weight
        ..shader = LinearGradient(colors: [ink.$1, ink.$2]).createShader(bounds),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SplashSignaturePainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.ink != ink;
}
