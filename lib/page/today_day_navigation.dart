import 'package:flutter/material.dart';

const todayPullThreshold = 64.0;
const todayPullLimit = 120.0;

// [人工决策-2026-09-27 17:28:58] 手势入口保持在转场视口外；长列表先滚动，到边缘才预览相邻日，正常松手与系统取消分别处理。
class TodayDayNavigation extends StatefulWidget {
  const TodayDayNavigation({
    super.key,
    required this.onStart,
    required this.onPull,
    required this.onRelease,
    required this.child,
    this.scrollable = false,
  });
  final VoidCallback onStart;
  final ValueChanged<double> onPull;
  final ValueChanged<bool> onRelease;
  final Widget child;
  final bool scrollable;
  @override
  State<TodayDayNavigation> createState() => _TodayDayNavigationState();
}

class _TodayDayNavigationState extends State<TodayDayNavigation>
    with WidgetsBindingObserver {
  int? _pointer;
  bool _dragging = false;
  double _pull = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _pointer = null;
      _dragging = false;
      _pull = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _finish(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _start() {
    if (_pointer == null || _dragging) return;
    _dragging = true;
    _pull = 0;
    widget.onStart();
  }

  void _update(double value) {
    if (!_dragging) return;
    final next = value.clamp(-todayPullLimit, todayPullLimit);
    if (_pull == next) return;
    _pull = next;
    widget.onPull(next);
  }

  void _finish(bool cancelled) {
    _pointer = null;
    if (!_dragging) return;
    _dragging = false;
    _pull = 0;
    widget.onRelease(cancelled);
  }

  bool _scroll(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _start();
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _start();
      _update(_pull - notification.overscroll);
    }
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final delta = notification.dragDetails!.delta.dy;
      if (_pull > 0 && delta < 0) {
        _update((_pull + delta).clamp(0, todayPullLimit));
      }
      if (_pull < 0 && delta > 0) {
        _update((_pull + delta).clamp(-todayPullLimit, 0));
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) => _pointer ??= event.pointer,
    onPointerUp: (event) {
      if (event.pointer == _pointer) _finish(false);
    },
    onPointerCancel: (event) {
      if (event.pointer == _pointer) _finish(true);
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _start(),
      onVerticalDragUpdate: (details) => _update(_pull + details.delta.dy),
      // 列表在手势竞技场胜出时不是系统取消；真正取消只由PointerCancel处理。
      child: NotificationListener<ScrollNotification>(onNotification: widget.scrollable ? _scroll : (_) => false, child: widget.child),
    ),
  );
}
