import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/curve_geometry.dart';

// 下拉刷新（同 iOS 原生：列表本身被拉下，露出的空白里画指示；拉够即开始刷新，松手后列表停在指示高度，完成再收起）。
// 指示器沿用应用自己的曲线动效，不用 Material 的转圈：下拉时按拉动距离把玫瑰曲线一笔描出来，拉够时描满并轻震一下，
// 刷新中换成同一条曲线上的循环加载，完成后缩小淡出。放在 CustomScrollView 的第一个 sliver，列表需可越界回弹。
// 指示至少停留 minimum：数据一到就更新，只是指示不一闪而过，让人看清“刷新过了”。
class CampusRefreshControl extends StatelessWidget {
  const CampusRefreshControl({super.key, required this.onRefresh, this.minimum = const Duration(milliseconds: 600)});
  final Future<void> Function() onRefresh;
  final Duration minimum;
  static const trigger = 88.0;
  static const extent = 64.0;

  Future<void> _refresh() => Future.wait([onRefresh(), Future<void>.delayed(minimum)]);

  @override
  Widget build(BuildContext context) => CupertinoSliverRefreshControl(
    refreshTriggerPullDistance: trigger,
    refreshIndicatorExtent: extent,
    onRefresh: _refresh,
    builder: (context, mode, pulled, trigger, extent) => _RefreshIndicator(mode: mode, pulled: pulled, trigger: trigger),
  );
}

class _RefreshIndicator extends StatefulWidget {
  const _RefreshIndicator({required this.mode, required this.pulled, required this.trigger});
  final RefreshIndicatorMode mode;
  final double pulled;
  final double trigger;
  @override
  State<_RefreshIndicator> createState() => _RefreshIndicatorState();
}

class _RefreshIndicatorState extends State<_RefreshIndicator> {
  @override
  void didUpdateWidget(_RefreshIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 拉过阈值的那一刻轻震一下（同 iOS 下拉刷新），确认松手就会刷新。
    if (widget.mode == RefreshIndicatorMode.armed && oldWidget.mode == RefreshIndicatorMode.drag) HapticFeedback.mediumImpact();
  }

  @override
  Widget build(BuildContext context) {
    final color = CampusPalette.of(context).primary;
    final reveal = (widget.pulled / widget.trigger).clamp(0.0, 1.0);
    final instant = MediaQuery.disableAnimationsOf(context);
    // 描线与循环加载之间交叉淡化，不在描满的一刻突变；完成时循环加载缩小淡出。
    final Widget indicator = AnimatedSwitcher(
      duration: instant ? Duration.zero : const Duration(milliseconds: 180),
      child: switch (widget.mode) {
        RefreshIndicatorMode.inactive => const SizedBox.shrink(key: ValueKey('idle')),
        RefreshIndicatorMode.drag => Opacity(
          key: const ValueKey('reveal'),
          opacity: Curves.easeOut.transform(((reveal - .15) / .5).clamp(0.0, 1.0)),
          child: Transform.scale(scale: .7 + .3 * reveal, child: CustomPaint(size: const Size.square(36), painter: CurveRevealPainter(fraction: reveal, color: color))),
        ),
        _ => TweenAnimationBuilder<double>(
          key: const ValueKey('loading'),
          tween: Tween(begin: 1, end: widget.mode == RefreshIndicatorMode.done ? 0 : 1),
          duration: instant ? Duration.zero : const Duration(milliseconds: 200),
          builder: (context, value, child) => Opacity(opacity: value, child: Transform.scale(scale: .6 + .4 * value, child: child)),
          child: CampusLoader(size: 36, color: color, delay: Duration.zero),
        ),
      },
    );
    // 指示贴着露出区的底部居中：拉动时跟着列表下沿走，刷新时停在指示高度正中。
    return Semantics(
      label: switch (widget.mode) { RefreshIndicatorMode.refresh || RefreshIndicatorMode.armed => MaterialLocalizations.of(context).refreshIndicatorSemanticLabel, _ => null },
      liveRegion: widget.mode == RefreshIndicatorMode.refresh,
      child: Align(alignment: Alignment.bottomCenter, child: Padding(padding: const EdgeInsets.only(bottom: 14), child: SizedBox.square(dimension: 36, child: Center(child: indicator)))),
    );
  }
}

// 按比例把闭合曲线从起点一笔描出：浅色底线是整条曲线，实线随比例延伸，笔头一个圆点；描满即整条曲线。
class CurveRevealPainter extends CustomPainter {
  CurveRevealPainter({required this.fraction, required this.color, this.curve = CampusCurve.rose});
  final double fraction;
  final Color color;
  final CampusCurve curve;

  @override
  void paint(Canvas canvas, Size size) {
    final geometry = CurveGeometry.of(curve);
    final scale = math.min(size.width, size.height) * .40;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 1.6 / scale
      ..color = color.withValues(alpha: color.a * .22);
    canvas.drawPath(geometry.path, paint);
    final points = geometry.points;
    final count = (fraction * (points.length - 1)).round();
    if (count > 0) {
      final drawn = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1).take(count)) {
        drawn.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(drawn, paint..color = color..strokeWidth = 2.2 / scale);
      canvas.drawCircle(points[count], 2.3 / scale, Paint()..color = color);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CurveRevealPainter oldDelegate) => oldDelegate.fraction != fraction || oldDelegate.color != color || oldDelegate.curve != curve;
}
