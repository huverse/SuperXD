import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:superxd/theme/campus_motion.dart';

// 玻璃鼓起幅度：按满时放大 6%，内容只跟随一半（玻璃是液体，文字图标是固体）。
const campusGlassSwell = .06;

// 玻璃控件的按压物理：按下用近临界阻尼弹簧鼓起，松手用低阻尼弹簧过冲一次回位；减少动画时不形变。
// glowColor 不为空时在手指处画一圈径向高光，强度随按压进度。
class CampusGlassPress extends StatefulWidget {
  const CampusGlassPress({
    super.key,
    required this.pressed,
    required this.radius,
    required this.builder,
    this.glowColor,
  });
  final bool pressed;
  final double radius;
  final Color? glowColor;
  final Widget Function(BuildContext context, double contentScale) builder;
  @override
  State<CampusGlassPress> createState() => _CampusGlassPressState();
}

class _CampusGlassPressState extends State<CampusGlassPress>
    with SingleTickerProviderStateMixin {
  late final _progress = AnimationController.unbounded(vsync: this);
  final _touch = ValueNotifier<Offset?>(null);

  @override
  void didUpdateWidget(CampusGlassPress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pressed == widget.pressed) return;
    final spring = campusGlassSpring(context, release: !widget.pressed);
    if (spring == null) {
      _progress.value = 0;
      return;
    }
    _progress.animateWith(
      SpringSimulation(
        spring,
        _progress.value,
        widget.pressed ? 1 : 0,
        _progress.velocity,
      ),
    );
  }

  @override
  void dispose() {
    _progress.dispose();
    _touch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => _touch.value = event.localPosition,
    onPointerMove: (event) => _touch.value = event.localPosition,
    child: AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final progress = _progress.value;
        final swell = 1 + campusGlassSwell * progress;
        final glowColor = widget.glowColor;
        return Transform.scale(
          scale: swell,
          child: CustomPaint(
            foregroundPainter: glowColor == null
                ? null
                : _GlowPainter(
                    touch: _touch,
                    progress: progress.clamp(0.0, 1.0),
                    radius: widget.radius,
                    color: glowColor,
                  ),
            child: widget.builder(
              context,
              (1 + campusGlassSwell / 2 * progress) / swell,
            ),
          ),
        );
      },
    ),
  );
}

class _GlowPainter extends CustomPainter {
  _GlowPainter({
    required this.touch,
    required this.progress,
    required this.radius,
    required this.color,
  }) : super(repaint: touch);
  final ValueNotifier<Offset?> touch;
  final double progress;
  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final point = touch.value;
    if (point == null || progress <= 0) return;
    final reach = size.shortestSide * 1.2;
    canvas.clipRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(math.min(radius, size.shortestSide / 2)),
      ),
    );
    canvas.drawCircle(
      point,
      reach,
      Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: color.a * progress),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: point, radius: reach)),
    );
  }

  @override
  bool shouldRepaint(_GlowPainter oldDelegate) =>
      progress != oldDelegate.progress ||
      radius != oldDelegate.radius ||
      color != oldDelegate.color;
}
