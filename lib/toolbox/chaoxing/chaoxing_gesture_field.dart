import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_palette.dart';

// 手势签到的 3×3 图案输入，同学习通客户端：按下开始，滑过圆点依次连成图案，抬起即算画完，
// 回调点的序号串（从 1 起）。少于两个点当误触，抬起即清空。校验失败由调用方把 error 置上来：
// [人工决策-2026-10-09 20:32:45] 画错的图案留在原处标红并轻震一下，到下一次按下才清空（同 Android 锁屏）；不加位移动画。用户选定。
// 图案用原始指针事件画、不走手势竞技场：pan 的触发阈值（36 像素）比弹层拖动关闭的竖向拖动（18 像素）大，
// 在弹层里竞技场会判给弹层；外面再包一层空的竖向拖动先把手势接走，图案区里拖动不会把弹层拖走。
class ChaoxingGestureField extends StatefulWidget {
  const ChaoxingGestureField({super.key, required this.onCompleted, this.error});
  final ValueChanged<String> onCompleted;
  final String? error;

  @override
  State<ChaoxingGestureField> createState() => _ChaoxingGestureFieldState();
}

class _ChaoxingGestureFieldState extends State<ChaoxingGestureField> {
  final _selected = <int>[];
  Offset? _dragPosition;
  bool _dragging = false;

  // 画错的图案是否还标着红：调用方给出错误时亮起，下一次按下时熄灭。
  late bool _showError = widget.error != null;

  @override
  void didUpdateWidget(ChaoxingGestureField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null && oldWidget.error == null) {
      _showError = true;
      HapticFeedback.heavyImpact();
    }
    if (widget.error == null) _showError = false;
  }

  Offset _centerOf(Size size, int index) {
    final cell = size.width / 3;
    return Offset((index % 3 + 0.5) * cell, (index ~/ 3 + 0.5) * cell);
  }

  // 滑到某点附近就选中它；已选过的不再重复。
  void _hit(Size size, Offset position) {
    final radius = size.width / 3 * 0.45;
    for (var index = 0; index < 9; index++) {
      if (_selected.contains(index)) continue;
      if ((position - _centerOf(size, index)).distance <= radius) {
        setState(() => _selected.add(index));
        HapticFeedback.selectionClick();
        return;
      }
    }
  }

  void _track(Size size, Offset position) {
    if (!_dragging) return;
    setState(() => _dragPosition = position);
    _hit(size, position);
  }

  void _end() {
    final pattern = [for (final index in _selected) '${index + 1}'].join();
    setState(() {
      _dragging = false;
      _dragPosition = null;
      if (_selected.length < 2) _selected.clear();
    });
    if (pattern.length >= 2) widget.onCompleted(pattern);
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final color = _showError ? palette.danger : palette.accent;
    return AspectRatio(
      aspectRatio: 1,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxWidth);
          return GestureDetector(
            onVerticalDragStart: (_) {},
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                // 每次按下都从空图案开始：上一次画的（含校验没过的）不能接着连，否则提交的是旧点加新点。
                _selected.clear();
                _showError = false;
                _dragging = true;
                _track(size, event.localPosition);
              },
              onPointerMove: (event) => _track(size, event.localPosition),
              onPointerUp: (_) => _end(),
              onPointerCancel: (_) => _end(),
              child: CustomPaint(
                painter: _GesturePainter(
                  selected: List.of(_selected),
                  dragging: _dragging,
                  dragPosition: _dragPosition,
                  color: color,
                  base: palette.onSurfaceVariant,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GesturePainter extends CustomPainter {
  const _GesturePainter({required this.selected, required this.dragging, this.dragPosition, required this.color, required this.base});
  final List<int> selected;
  final bool dragging;
  final Offset? dragPosition;
  final Color color;
  final Color base;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 3;
    Offset centerOf(int index) => Offset((index % 3 + 0.5) * cell, (index ~/ 3 + 0.5) * cell);
    for (var index = 0; index < 9; index++) {
      final chosen = selected.contains(index);
      final dot = Paint()
        ..color = chosen ? color : base
        ..style = chosen ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(centerOf(index), cell * 0.1, dot);
    }
    final line = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    Offset? previous;
    for (final index in selected) {
      final center = centerOf(index);
      if (previous != null) canvas.drawLine(previous, center, line);
      previous = center;
    }
    if (dragging && dragPosition != null && previous != null) canvas.drawLine(previous, dragPosition!, line);
  }

  @override
  bool shouldRepaint(_GesturePainter old) => selected.length != old.selected.length || dragging != old.dragging || dragPosition != old.dragPosition || color != old.color;
}
