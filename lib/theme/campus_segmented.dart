import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_palette.dart';

// 分段控件（iOS 分段控件、鸿蒙 Segment 的做法）：中性浅底的胶囊槽，选中项是浮起的实色胶囊，切换时滑过去；
// 属于内容区，不用玻璃。选中项文字加粗、不着主色；整行 48dp 触区；减少动画时直接到位。
// [人工决策-2026-10-03 19:52:06] 选中块可拖动（同 iOS 分段控件与底栏拖动的规则）：任意位置起拖，选中块连续跟手、按下轻缩到 95%，
// 经过每一段给一次轻触感；正常松手吸附手指下的一段、只提交一次，系统取消退回原选中；纵向滑动仍交给页面滚动。
// 选中块保持实色而不是 iOS 26 的玻璃透镜：内容区不用玻璃，且外层滚动渐隐遮罩里的玻璃取不到背景。
class CampusSegmented<T> extends StatefulWidget {
  const CampusSegmented({super.key, required this.values, required this.label, required this.selected, required this.onSelected});
  final List<T> values;
  final String Function(T value) label;
  final T selected;
  // 为空时整组禁用（如保存中），不响应点按和拖动。
  final ValueChanged<T>? onSelected;

  @override
  State<CampusSegmented<T>> createState() => _CampusSegmentedState<T>();
}

class _CampusSegmentedState<T> extends State<CampusSegmented<T>> with TickerProviderStateMixin {
  // 选中块位置，单位为段（0 为第一段）。
  late final _position = AnimationController.unbounded(vsync: this, value: widget.values.indexOf(widget.selected).toDouble());
  // 按下进度：选中块轻缩。
  late final _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 120), reverseDuration: const Duration(milliseconds: 200));
  final _trackKey = GlobalKey();
  int? _pointer;
  bool _dragging = false;

  bool get _reduced => MediaQuery.disableAnimationsOf(context);
  int get _selectedIndex => widget.values.indexOf(widget.selected);

  void _settle(int index) {
    if (_reduced) {
      _position.value = index.toDouble();
      return;
    }
    _position.animateTo(index.toDouble(), duration: const Duration(milliseconds: 260), curve: Curves.easeOutCubic);
  }

  double _slotAt(Offset global) {
    final box = _trackKey.currentContext!.findRenderObject()! as RenderBox;
    final x = box.globalToLocal(global).dx;
    return (x / (box.size.width / widget.values.length) - .5).clamp(0.0, widget.values.length - 1.0);
  }

  void _release({required bool commit}) {
    _pointer = null;
    _press.reverse();
    if (!_dragging) return;
    _dragging = false;
    final index = commit ? _position.value.round() : _selectedIndex;
    _settle(index);
    if (commit && index != _selectedIndex) widget.onSelected!(widget.values[index]);
  }

  @override
  void didUpdateWidget(CampusSegmented<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected && !_dragging) _settle(_selectedIndex);
  }

  @override
  void dispose() {
    _position.dispose();
    _press.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final count = widget.values.length;
    final enabled = widget.onSelected != null;
    return SizedBox(
      height: 48 * scale,
      child: Listener(
        onPointerDown: (event) {
          if (!enabled || _pointer != null) return;
          _pointer = event.pointer;
          if (!_reduced) _press.forward();
        },
        onPointerUp: (event) {
          if (event.pointer == _pointer) _release(commit: true);
        },
        onPointerCancel: (event) {
          if (event.pointer == _pointer) _release(commit: false);
        },
        child: GestureDetector(
          onHorizontalDragStart: enabled ? (details) {
            _dragging = true;
            _position.stop();
            _position.value = _slotAt(details.globalPosition);
          } : null,
          onHorizontalDragUpdate: enabled ? (details) {
            final previous = _position.value.round();
            _position.value = _slotAt(details.globalPosition);
            if (_position.value.round() != previous) HapticFeedback.selectionClick();
          } : null,
          child: AnimatedBuilder(
            animation: Listenable.merge([_position, _press]),
            builder: (context, _) {
              final preview = _position.value.round();
              return Stack(children: [
                Positioned.fill(child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: DecoratedBox(
                    key: _trackKey,
                    decoration: ShapeDecoration(color: palette.onSurface.withValues(alpha: palette.isDark ? .10 : .06), shape: const StadiumBorder()),
                    child: LayoutBuilder(builder: (context, constraints) {
                      final width = constraints.maxWidth / count;
                      return Stack(children: [
                        Positioned(
                          left: _position.value * width,
                          top: 0,
                          bottom: 0,
                          width: width,
                          child: Transform.scale(
                            scale: 1 - .05 * _press.value,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: DecoratedBox(
                                key: const ValueKey('segment-pill'),
                                decoration: ShapeDecoration(
                                  color: palette.surface,
                                  shape: StadiumBorder(side: palette.isDark ? BorderSide(color: palette.outlineSubtle) : BorderSide.none),
                                  shadows: palette.isDark ? null : [BoxShadow(color: palette.onSurface.withValues(alpha: .12), blurRadius: 6, offset: const Offset(0, 1))],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ]);
                    }),
                  ),
                )),
                Row(children: [
                  for (var index = 0; index < count; index++)
                    Expanded(child: Semantics(
                      button: true,
                      enabled: enabled,
                      selected: widget.values[index] == widget.selected,
                      child: InkWell(
                        customBorder: const StadiumBorder(),
                        onTap: enabled ? () => widget.onSelected!(widget.values[index]) : null,
                        child: Center(child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            widget.label(widget.values[index]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: index == preview ? FontWeight.w600 : FontWeight.w500,
                              color: index == preview ? palette.onSurface : palette.onSurfaceVariant,
                            ),
                          ),
                        )),
                      ),
                    )),
                ]),
              ]);
            },
          ),
        ),
      ),
    );
  }
}
