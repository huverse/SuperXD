import 'dart:math' as math;
import 'dart:ui';

// 改编自Paidax01/math-curve-loaders（70f4e00）；用户确认允许改编与分发，详见第三方声明。
// 只保留三种闭合曲线。呼吸从逐帧改几何改为Canvas等比缩放，轨迹按弧长预采样。
enum CampusCurve { infinity, rose, lissajous }

class CurveGeometry {
  CurveGeometry._(this.points, this.path);
  final List<Offset> points;
  final Path path;
  static final _curves = {
    for (final curve in CampusCurve.values) curve: _build(curve),
  };
  static CurveGeometry of(CampusCurve curve) => _curves[curve]!;
  Offset at(double progress) {
    final value = (progress % 1) * (points.length - 1);
    final index = value.floor();
    return Offset.lerp(
      points[index % (points.length - 1)],
      points[(index + 1) % (points.length - 1)],
      value - index,
    )!;
  }

  static CurveGeometry _build(CampusCurve curve) {
    const count = 192;
    final sampled = <Offset>[];
    for (var index = 0; index <= count; index++) {
      final angle =
          index / count * (curve == CampusCurve.rose ? math.pi : 2 * math.pi);
      final sine = math.sin(angle);
      sampled.add(switch (curve) {
        CampusCurve.infinity => Offset(
          math.cos(angle) / (1 + sine * sine),
          sine * math.cos(angle) / (1 + sine * sine),
        ),
        CampusCurve.rose => Offset(
          math.cos(3 * angle) * math.cos(angle),
          math.cos(3 * angle) * math.sin(angle),
        ),
        CampusCurve.lissajous => Offset(
          math.sin(3 * angle + math.pi / 2),
          .92 * math.sin(4 * angle),
        ),
      });
    }
    sampled[sampled.length - 1] = sampled.first;
    final lengths = <double>[0];
    for (var index = 1; index < sampled.length; index++) {
      lengths.add(
        lengths.last + (sampled[index] - sampled[index - 1]).distance,
      );
    }
    final uniform = <Offset>[];
    var segment = 1;
    for (var index = 0; index <= count; index++) {
      final distance = lengths.last * index / count;
      while (segment < lengths.length - 1 && lengths[segment] < distance) {
        segment++;
      }
      final fraction =
          (distance - lengths[segment - 1]) /
          (lengths[segment] - lengths[segment - 1]);
      uniform.add(
        Offset.lerp(sampled[segment - 1], sampled[segment], fraction)!,
      );
    }
    uniform[uniform.length - 1] = uniform.first;
    final path = Path()..moveTo(uniform.first.dx, uniform.first.dy);
    for (final point in uniform.skip(1)) {
      path.lineTo(point.dx, point.dy);
    }
    path.close();
    return CurveGeometry._(List.unmodifiable(uniform), path);
  }
}
