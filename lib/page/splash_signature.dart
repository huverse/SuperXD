import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PathMetric;

import 'package:flutter/widgets.dart';

// 开屏一笔写出的「SuperXD」（同苹果开机的 hello，人工决策见 painting_splash.dart 类上）：笔画是手写体的中心线，按书写顺序逐笔画出，
// 转弯、尖角与起笔收笔处慢，直线处快，笔画之间短暂提笔。
// 字形就是下面的控制点：直立书写的设计坐标（基线 270、x 高 205、大写顶 110、下伸 345），运行时整体右斜 14°、过向心 Catmull-Rom 成平滑曲线；
// 第三个值为 true 的是尖角（u 的两个尖顶、p 回到竖笔、r 的肩），在那里断开平滑，笔画照样连着。改字形只改这些点。
const _strokes = <List<(double, double, bool)>>[
  // Super：一笔连写。
  [
    (52, 262, false), (100, 205, false), (140, 150, false), (172, 115, false), (160, 100, false), (132, 108, false),
    (124, 138, false), (146, 168, false), (172, 200, false), (175, 238, false), (152, 266, false), (112, 272, false),
    (86, 260, false), (96, 246, false), (130, 256, false), (176, 268, false), (203, 238, false), (213, 206, true),
    (210, 242, false), (220, 267, false), (242, 262, false), (258, 230, false), (264, 206, true), (263, 246, false),
    (274, 268, false), (290, 238, false), (302, 200, true), (299, 272, false), (293, 345, false), (305, 300, false),
    (311, 240, false), (334, 205, false), (353, 226, false), (342, 261, false), (318, 267, true), (345, 266, false),
    (366, 258, false), (396, 235, false), (392, 208, false), (371, 213, false), (365, 246, false), (381, 268, false),
    (412, 262, false), (424, 236, false), (432, 205, true), (443, 214, false), (452, 207, true), (455, 236, false),
    (458, 268, false), (478, 262, false), (500, 246, false),
  ],
  // X：左上起笔带钩，右下收笔上挑。
  [
    (512, 140, false), (530, 118, false), (558, 112, false), (582, 140, false), (612, 215, false), (640, 262, false),
    (668, 266, false), (684, 250, false),
  ],
  // X：右上斜落到左下，收笔回钩。
  [
    (668, 110, false), (636, 160, false), (600, 215, false), (570, 258, false), (545, 270, false), (522, 262, false),
    (516, 248, false),
  ],
  // D：竖笔落到底绕一个小圈，大弧回到顶上，收在左上。
  [
    (740, 118, false), (734, 190, false), (727, 252, false), (714, 272, false), (692, 274, false), (682, 258, false),
    (698, 246, false), (726, 256, false), (768, 270, false), (808, 263, false), (842, 224, false), (848, 166, false),
    (824, 123, false), (780, 106, false), (736, 108, false), (704, 120, false), (700, 138, false), (720, 142, false),
  ],
];

const _baseline = 270.0;
final _slant = math.tan(14 * math.pi / 180);
// 书写节奏按笔画每 2 个设计单位取一次样：拐得越急越慢（curvature），起笔、收笔各慢一点（ends），提笔停顿约占书写的 6%。
const _step = 2.0;
const _curvature = 9.0;
const _lift = .06;

class SplashSignature {
  SplashSignature._(this._metrics, this._costs, this._liftCost, this.bounds);

  static final shared = SplashSignature._build();

  final List<PathMetric> _metrics;
  // 每一笔沿长度的累计书写「耗时」（任意单位），进度按它换成画到的长度。
  final List<Float64List> _costs;
  final double _liftCost;
  final Rect bounds;

  static SplashSignature _build() {
    final paths = [for (final stroke in _strokes) _strokePath(stroke)];
    final metrics = [for (final path in paths) path.computeMetrics().single];
    final costs = [for (final metric in metrics) _strokeCost(metric)];
    final drawing = costs.fold(0.0, (sum, cost) => sum + cost.last);
    return SplashSignature._(metrics, costs, drawing * _lift, paths.skip(1).fold(paths.first.getBounds(), (bounds, path) => bounds.expandToInclude(path.getBounds())));
  }

  double get _total => _costs.fold(0.0, (sum, cost) => sum + cost.last) + _liftCost * (_costs.length - 1);

  // 进度 0–1 画到哪里：写完的笔整笔画，正在写的那笔画到对应长度，还没写到的不画。
  void paint(Canvas canvas, double progress, Paint paint) {
    var remaining = progress.clamp(0.0, 1.0) * _total;
    for (var index = 0; index < _metrics.length && remaining > 0; index++) {
      final metric = _metrics[index], cost = _costs[index];
      if (remaining >= cost.last) {
        canvas.drawPath(metric.extractPath(0, metric.length), paint);
      } else {
        canvas.drawPath(metric.extractPath(0, _lengthAt(cost, remaining, metric.length)), paint);
      }
      remaining -= cost.last + _liftCost;
    }
  }

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

  static Float64List _strokeCost(PathMetric metric) {
    final steps = (metric.length / _step).ceil();
    final cost = Float64List(steps + 1);
    var previousAngle = metric.getTangentForOffset(0)!.angle;
    var previousOffset = 0.0;
    for (var index = 1; index <= steps; index++) {
      final offset = math.min(index * _step, metric.length);
      final angle = metric.getTangentForOffset(offset)!.angle;
      var turn = (angle - previousAngle).abs();
      if (turn > math.pi) turn = 2 * math.pi - turn;
      final distance = offset - previousOffset;
      final ends = .8 * math.exp(-offset / 24) + .5 * math.exp(-(metric.length - offset) / 24);
      cost[index] = cost[index - 1] + distance * (1 + ends) + _curvature * turn;
      previousAngle = angle;
      previousOffset = offset;
    }
    return cost;
  }

  static Path _strokePath(List<(double, double, bool)> points) {
    final slanted = [for (final (x, y, _) in points) Offset(x + (_baseline - y) * _slant, y)];
    final path = Path()..moveTo(slanted.first.dx, slanted.first.dy);
    var start = 0;
    for (var index = 1; index < points.length; index++) {
      if (points[index].$3 || index == points.length - 1) {
        _spline(path, slanted.sublist(start, index + 1));
        start = index;
      }
    }
    return path;
  }

  // 向心 Catmull-Rom 转三次贝塞尔（不打结、不过冲），首尾各补一个镜像点；接着 path 当前的终点往下画。
  static void _spline(Path path, List<Offset> points) {
    final padded = [points.first * 2 - points[1], ...points, points.last * 2 - points[points.length - 2]];
    double gap(Offset a, Offset b) => math.max(math.sqrt((a - b).distance), 1e-6);
    for (var index = 1; index < padded.length - 2; index++) {
      final p0 = padded[index - 1], p1 = padded[index], p2 = padded[index + 1], p3 = padded[index + 2];
      final t01 = gap(p0, p1), t12 = gap(p1, p2), t23 = gap(p2, p3);
      final m1 = p2 - p1 + ((p1 - p0) / t01 - (p2 - p0) / (t01 + t12)) * t12;
      final m2 = p2 - p1 + ((p3 - p2) / t23 - (p3 - p1) / (t12 + t23)) * t12;
      final c1 = p1 + m1 / 3, c2 = p2 - m2 / 3;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
  }
}

// 把签名按比例放进给定大小、居中（四周留出半个线宽），线宽是屏幕上的逻辑像素（不随缩放变粗变细）。
class SplashSignaturePainter extends CustomPainter {
  const SplashSignaturePainter({required this.progress, required this.color, required this.strokeWidth});
  final double progress;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final signature = SplashSignature.shared;
    final bounds = signature.bounds;
    final scale = math.min((size.width - strokeWidth) / bounds.width, (size.height - strokeWidth) / bounds.height);
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
        ..strokeWidth = strokeWidth / scale
        ..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(SplashSignaturePainter oldDelegate) => oldDelegate.progress != progress || oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
}
