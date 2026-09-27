import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';

// 唯一背景循环，不随路由/列表项复制。纹理固定，不逐帧生成随机噪点。
class CampusAtmosphere extends StatefulWidget {
  const CampusAtmosphere({super.key, required this.child, this.phase});
  final Widget child;
  final double? phase;
  @override
  State<CampusAtmosphere> createState() => _CampusAtmosphereState();
}

class _CampusAtmosphereState extends State<CampusAtmosphere>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );
  bool _allowed = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed =
        CampusMotion.allowed(context) &&
        !MediaQuery.highContrastOf(context) &&
        !MediaQuery.accessibleNavigationOf(context);
    _updatePlayback();
  }

  void _updatePlayback() {
    if (_allowed && widget.phase == null) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void didUpdateWidget(CampusAtmosphere oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase) _updatePlayback();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: AtmospherePainter(
                  palette: CampusPalette.of(context),
                  progress: _allowed && widget.phase == null
                      ? _controller
                      : AlwaysStoppedAnimation(widget.phase ?? .18),
                  highContrast: MediaQuery.highContrastOf(context),
                ),
              ),
            ),
          ),
        ),
      ),
      widget.child,
    ],
  );
}

class AtmospherePainter extends CustomPainter {
  AtmospherePainter({
    required this.progress,
    required this.highContrast,
    required this.palette,
  }) : super(repaint: progress);
  final Animation<double> progress;
  final bool highContrast;
  final CampusPalette palette;
  final _paint = Paint();
  static const _unitBounds = Rect.fromLTRB(-1, -1, 1, 1);
  static const _clouds = [
    (x: .06, y: .24, phase: 0.0, angle: -.5, color: 0),
    (x: .93, y: .43, phase: 2.1, angle: .6, color: 1),
    (x: .22, y: .79, phase: 4.2, angle: -.4, color: 2),
    (x: .91, y: .95, phase: 1.3, angle: .5, color: 0),
  ];
  late final _colors = [
    palette.fogSage,
    palette.fogChampagne,
    palette.fogPearl,
  ];
  late final _wideShaders = [
    for (final color in _colors)
      _fogGradient(color, .92).createShader(_unitBounds),
  ];
  late final _foldShaders = [
    for (final color in _colors)
      _fogGradient(color, .40).createShader(_unitBounds),
  ];
  late final _pearlShader = _fogGradient(
    palette.surface,
    .44,
  ).createShader(_unitBounds);
  late final _baseShader = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [palette.backgroundTop, palette.backgroundBottom],
  ).createShader(const Rect.fromLTWH(0, 0, 1, 1));

  RadialGradient _fogGradient(Color color, double alpha) {
    final pearl = Color.lerp(color, palette.surface, .34)!;
    return RadialGradient(
      colors: [
        pearl.withValues(alpha: alpha),
        pearl.withValues(alpha: alpha * .82),
        pearl.withValues(alpha: alpha * .34),
        pearl.withValues(alpha: 0),
      ],
      stops: const [0, .34, .70, 1],
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.scale(size.width, size.height);
    _paint.shader = _baseShader;
    canvas.drawRect(const Rect.fromLTWH(0, 0, 1, 1), _paint);
    canvas.restore();
    if (highContrast) return;
    // [人工决策-2026-09-25 20:18:09] 以大面积冷暖珠光替代低对比九瓣；保留五主题、24秒和卡片遮色，留白及边缘须可见轮廓交融。
    final phase = progress.value * math.pi * 2;
    final extent = size.shortestSide;
    canvas.save();
    canvas.clipRect(bounds);
    for (final cloud in _clouds) {
      final drift = phase + cloud.phase;
      final center = Offset(
        size.width * (cloud.x + .27 * math.sin(drift)),
        size.height * (cloud.y + .13 * math.cos(drift)),
      );
      final angle = cloud.angle + .42 * math.sin(drift);
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(angle);
      canvas.save();
      canvas.scale(
        extent * (1.04 + .18 * math.sin(drift)),
        math.max(extent * .64, size.height * .36) * (1 + .20 * math.cos(drift)),
      );
      _paint.shader = _wideShaders[cloud.color];
      canvas.drawOval(_unitBounds, _paint);
      canvas.restore();
      // 相对主体独立舒展的光褶，而不是整张彩斑平移。
      canvas.translate(
        extent * .24 * math.cos(drift + .8),
        extent * .20 * math.sin(drift + .8),
      );
      canvas.rotate(.7 * math.sin(drift + 1.2));
      canvas.scale(
        extent * (.56 + .12 * math.cos(drift)),
        extent * (.34 + .08 * math.sin(drift)),
      );
      _paint.shader = _foldShaders[(cloud.color + 1) % _colors.length];
      canvas.drawOval(_unitBounds, _paint);
      canvas.restore();
    }
    // 珠白光脊保持纸面明度，分开冷暖雾团，避免叠色变成均匀脏灰。
    canvas.save();
    canvas.translate(
      size.width * (.49 + .16 * math.sin(phase + .7)),
      size.height * (.52 + .12 * math.cos(phase + .7)),
    );
    canvas.rotate(.35 * math.sin(phase));
    canvas.scale(extent * .53, size.height * .69);
    _paint.shader = _pearlShader;
    canvas.drawOval(_unitBounds, _paint);
    canvas.restore();
    canvas.restore();
    _paint.shader = null;
  }

  @override
  bool shouldRepaint(AtmospherePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.highContrast != highContrast ||
      oldDelegate.palette != palette;
}

class FrostTexture extends StatelessWidget {
  const FrostTexture({super.key, this.radius = 24});
  final double radius;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(
          painter: _GrainPainter(CampusPalette.of(context).onSurfaceVariant),
        ),
      ),
    ),
  );
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: .016);
    // 固定12px纹理单元，每帧不变；随当前表面像素面积增长，不随业务数据增长。
    for (var y = 3.0; y < size.height; y += 12) {
      for (var x = 3.0; x < size.width; x += 12) {
        canvas.drawCircle(Offset(x + (y.toInt() % 7), y), .55, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_GrainPainter oldDelegate) => oldDelegate.color != color;
}
