import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/curve_geometry.dart';

class CampusLoader extends StatefulWidget {
  const CampusLoader({
    super.key,
    this.curve = CampusCurve.rose,
    this.size = 56,
    this.color,
    this.delay = const Duration(milliseconds: 150),
    this.progress,
  });
  final CampusCurve curve;
  final double size;
  final Color? color;
  final Duration delay;
  // 固定进度用于截图与确定性几何测试，不创建循环ticker。
  final double? progress;
  @override
  State<CampusLoader> createState() => _CampusLoaderState();
}

class _CampusLoaderState extends State<CampusLoader>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 4800),
  );
  Timer? _delay;
  bool _visible = false;
  bool _allowed = false;
  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _visible = true;
    } else {
      _delay = Timer(widget.delay, () {
        if (mounted) {
          setState(() => _visible = true);
          _animate();
        }
      });
    }
  }

  void _animate() {
    if (_allowed && _visible && widget.progress == null) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed = CampusMotion.allowed(context);
    _animate();
  }

  @override
  void didUpdateWidget(CampusLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    _animate();
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: !_visible
        ? null
        : RepaintBoundary(
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: CurveLoaderPainter(
                  curve: widget.curve,
                  progress: widget.progress == null && _allowed
                      ? _controller
                      : AlwaysStoppedAnimation(widget.progress ?? .18),
                  color:
                      widget.color ??
                      IconTheme.of(context).color ??
                      CampusPalette.of(context).primary,
                  compact: widget.size <= 28,
                  moving: _allowed,
                ),
              ),
            ),
          ),
  );
}

class CurveLoaderPainter extends CustomPainter {
  CurveLoaderPainter({
    required this.curve,
    required this.progress,
    required this.color,
    required this.compact,
    required this.moving,
  }) : super(repaint: progress);
  final CampusCurve curve;
  final Animation<double> progress;
  final Color color;
  final bool compact;
  final bool moving;
  final Paint _paint = Paint()
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  @override
  void paint(Canvas canvas, Size size) {
    final geometry = CurveGeometry.of(curve);
    final phase = progress.value;
    final breathing = moving && !compact
        ? .97 + .03 * math.sin(phase * math.pi * 2)
        : 1.0;
    final scale = math.min(size.width, size.height) * .40 * breathing;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    _paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = (compact ? 1.4 : 1.6) / scale
      ..color = color.withValues(alpha: color.a * .22);
    canvas.drawPath(geometry.path, _paint);
    _paint.style = PaintingStyle.fill;
    final count = compact ? 12 : 24;
    for (var index = count - 1; index >= 0; index--) {
      final weight = 1 - index / (count - 1);
      final point = geometry.at(phase - index / count * .25);
      _paint.color = color.withValues(alpha: color.a * (.12 + weight * .88));
      canvas.drawCircle(
        point,
        (compact ? .6 + weight * .9 : .8 + weight * 1.5) / scale,
        _paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(CurveLoaderPainter oldDelegate) =>
      oldDelegate.curve != curve ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.compact != compact ||
      oldDelegate.moving != moving;
}

class CampusLoading extends StatefulWidget {
  const CampusLoading({
    super.key,
    required this.label,
    this.inline = false,
    this.network = false,
    this.animating = true,
    this.color,
  });
  final String label;
  final bool inline;
  final bool network;
  final bool animating;
  final Color? color;
  @override
  State<CampusLoading> createState() => _CampusLoadingState();
}

class _CampusLoadingState extends State<CampusLoading> {
  Timer? _wait;
  bool _longWait = false;
  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _wait?.cancel();
    _longWait = false;
    if (widget.network && widget.animating) {
      _wait = Timer(const Duration(seconds: 8), () {
        if (mounted) setState(() => _longWait = true);
      });
    }
  }

  @override
  void didUpdateWidget(CampusLoading oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.label != widget.label ||
        oldWidget.animating != widget.animating) {
      _start();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = _longWait ? '${widget.label}\n仍在等待教务响应，请稍候' : widget.label;
    final loader = CampusLoader(
      curve: widget.network ? CampusCurve.lissajous : CampusCurve.rose,
      size: widget.inline ? 36 : 56,
      color: widget.color ?? CampusPalette.of(context).primary,
      progress: widget.animating ? null : .18,
    );
    final text = Text(
      label,
      textAlign: widget.inline ? TextAlign.start : TextAlign.center,
      style: TextStyle(
        fontSize: 14,
        color: widget.color ?? CampusPalette.of(context).onSurfaceVariant,
        height: 1.5,
      ),
    );
    return Semantics(
      label: label,
      liveRegion: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: widget.inline ? 8 : 24,
          ),
          child: widget.inline
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    loader,
                    const SizedBox(width: 12),
                    Flexible(child: text),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [loader, const SizedBox(height: 12), text],
                ),
        ),
      ),
    );
  }
}

class CampusBusyContent extends StatelessWidget {
  const CampusBusyContent({
    super.key,
    required this.busy,
    required this.label,
    required this.busyLabel,
    this.icon,
    this.color,
  });
  final bool busy;
  final String label;
  final String busyLabel;
  final Widget? icon;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    final style = DefaultTextStyle.of(context).style;
    var width = 0.0;
    for (final value in [label, busyLabel]) {
      painter.text = TextSpan(text: value, style: style);
      painter.layout();
      width = math.max(width, painter.width);
    }
    painter.dispose();
    return Semantics(
      label: busy ? busyLabel : label,
      liveRegion: busy,
      child: ExcludeSemantics(
        child: SizedBox(
          width: width + 32,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy || icon != null) ...[
                SizedBox.square(
                  dimension: 24,
                  child: busy
                      ? CampusLoader(curve: CampusCurve.infinity, size: 24, color: color ?? style.color)
                      : icon,
                ),
                const SizedBox(width: 8),
              ],
              Flexible(child: SizedBox(width: width, child: Text(busy ? busyLabel : label, textAlign: TextAlign.center))),
            ],
          ),
        ),
      ),
    );
  }
}

// 不增加业务等待时间；弹窗只在已有异步操作期间可见，失败原样交还调用方处理。
Future<T> showCampusWaiting<T>(
  BuildContext context, {
  required String label,
  required Future<T> Function() operation,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = CampusDialogRoute<void>(context: context, barrierDismissible: false, builder: (context) => PopScope(canPop: false, child: CampusGlassDialog(content: CampusLoading(label: label))));
  final delay = Timer(const Duration(milliseconds: 150), () {
    if (context.mounted &&
        navigator.mounted &&
        (ModalRoute.of(context)?.isCurrent ?? true)) {
      unawaited(navigator.push(route));
    }
  });
  try {
    return await operation();
  } finally {
    delay.cancel();
    if (route.isActive && navigator.mounted) navigator.removeRoute(route);
  }
}
