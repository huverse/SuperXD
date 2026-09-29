import 'package:flutter/material.dart';

import 'package:superxd/domain/week.dart';
import 'package:superxd/page/today_day_navigation.dart';
import 'package:superxd/theme/campus_motion.dart';

class TodayDateFrame {
  const TodayDateFrame({
    required this.header,
    required this.body,
    required this.scrollable,
  });
  final Widget header;
  final Widget body;
  final bool scrollable;
}

// [人工决策-2026-09-27 17:28:58] 移除切日形变胶囊，日期和正文以同一进度纵向交接；上滑新日从下入、下滑从上入，预览不提交，取消恢复原页。
class TodayDateTransition extends StatefulWidget {
  const TodayDateTransition({
    super.key,
    required this.date,
    required this.revision,
    required this.recenter,
    required this.canSelect,
    required this.frameBuilder,
    required this.onCommit,
    required this.builder,
    this.bodyInset = 24,
  });
  final String date;
  final int revision;
  final int recenter;
  final double bodyInset;
  final bool Function(String date) canSelect;
  final TodayDateFrame Function(String date) frameBuilder;
  final ValueChanged<String> onCommit;
  final Widget Function(
    BuildContext context,
    Widget header,
    Widget body,
    bool previewing,
  )
  builder;
  @override
  State<TodayDateTransition> createState() => _TodayDateTransitionState();
}

class _TodayDateTransitionState extends State<TodayDateTransition>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final _progress = AnimationController(vsync: this);
  late final _outOpacity = _progress
      .drive(
        CurveTween(curve: const Interval(0, .52, curve: Curves.easeInOutCubic)),
      )
      .drive(Tween(begin: 1.0, end: 0.0));
  late final _inOpacity = _progress.drive(
    CurveTween(curve: const Interval(.40, 1, curve: Curves.easeOutCubic)),
  );
  late String _from = widget.date;
  late TodayDateFrame _current = widget.frameBuilder(_from);
  String? _to;
  TodayDateFrame? _candidate;
  String? _pending;
  String? _gestureBase;
  double _gestureStart = 0;
  double _rawDistance = 0;
  double _boundaryOffset = 0;
  bool _dragging = false;
  bool _returning = false;
  bool _paused = false;
  bool _resetAtRest = false;
  double? _boundaryReturn;

  bool get _motion => !_paused && CampusMotion.allowed(context);
  String _adjacent(String date, int step) =>
      formatIsoDate(parseIsoDate(date).add(Duration(days: step)));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _progress.addStatusListener(_settled);
  }

  void _settled(AnimationStatus status) {
    if (_dragging ||
        !mounted ||
        status != AnimationStatus.completed &&
            status != AnimationStatus.dismissed) {
      return;
    }
    if (_to == null) {
      if (_boundaryReturn != null) setState(() { _boundaryReturn = null; _boundaryOffset = 0; });
      return;
    }
    final forward = status == AnimationStatus.completed;
    setState(() {
      if (forward) {
        _from = _to!;
        _current = _candidate!;
      }
      _to = null;
      _candidate = null;
      _returning = false;
      _boundaryOffset = 0;
      if (_resetAtRest) {
        _current = widget.frameBuilder(_from);
        _resetAtRest = false;
      }
    });
    final pending = _pending;
    _pending = null;
    if (pending != null && pending != _from) _request(pending);
  }

  void _startPair(String date) {
    _progress.stop();
    _progress.value = 0;
    setState(() {
      _to = date;
      _candidate = widget.frameBuilder(date);
      _boundaryOffset = 0;
    });
  }

  void _animateTo(double goal) {
    _returning = goal == 0;
    if (_progress.value == goal) {
      _settled(goal == 0 ? AnimationStatus.dismissed : AnimationStatus.completed);
      return;
    }
    if (!_motion) {
      _progress.value = goal;
      _settled(
        goal == 0 ? AnimationStatus.dismissed : AnimationStatus.completed,
      );
      return;
    }
    final duration = Duration(
      milliseconds: (300 * (goal - _progress.value).abs()).round().clamp(
        80,
        300,
      ),
    );
    if (goal == 0) {
      _progress.animateBack(0, duration: duration, curve: Curves.easeOutCubic);
    } else {
      _progress.animateTo(1, duration: duration, curve: Curves.easeOutCubic);
    }
  }

  void _request(String date) {
    if (_to == date) {
      _animateTo(1);
      return;
    }
    if (_to != null && _from == date) {
      _pending = null;
      _animateTo(0);
      return;
    }
    if (_to != null) {
      _pending = date;
      _animateTo(_returning ? 0 : 1);
      return;
    }
    if (_from == date) return;
    _startPair(date);
    _animateTo(1);
  }

  void _begin() {
    if (_boundaryReturn != null) {
      _boundaryOffset = _boundaryReturn! * (1 - _progress.value);
      _boundaryReturn = null;
      _progress.stop();
    }
    _gestureBase = widget.date;
    _rawDistance = 0;
    _gestureStart = _progress.value;
    _dragging = true;
    if (_to == null || _returning) _progress.stop();
  }

  void _pull(double distance) {
    if (_paused) return;
    if (!_dragging) _begin();
    _rawDistance = distance;
    final step = distance < 0 ? 1 : -1;
    final target = _adjacent(_gestureBase!, step);
    if (_gestureBase == _to && target != _from && _progress.value == 1) {
      // 前一交接已完成但新手势仍按住：提升目标节点后继续预览，最多两份页面。
      setState(() { _from = _to!; _current = _candidate!; _to = null; _candidate = null; _gestureStart = 0; });
    }
    if (distance == 0) {
      if (_to != null && _gestureBase == _from) _progress.value = 0;
      return;
    }
    if (!widget.canSelect(target)) {
      if (_to == null) {
        setState(() => _boundaryOffset = (distance / 8).clamp(-10, 10));
      }
      return;
    }
    if (_to == null) {
      if (distance.abs() < 4) return;
      _startPair(target);
      _gestureStart = 0;
    }
    if (_gestureBase == _from && _to != target) {
      // 跨过手势起点再更换候选；候选替换时进度为零，没有第三个离场页面。
      _gestureStart = 0;
      _progress.value = 0;
      setState(() {
        _to = target;
        _candidate = widget.frameBuilder(target);
      });
    }
    if (!_motion) return;
    final preview = (distance.abs() / 160).clamp(0.0, .75);
    if (_gestureBase == _from && _to == target) {
      _progress.stop();
      _progress.value = (_gestureStart + preview).clamp(0.0, .85);
    } else if (_gestureBase == _to && target == _from) {
      _progress.stop();
      _progress.value = (_gestureStart - preview).clamp(.05, 1.0);
    }
  }

  void _release(bool cancelled) {
    if (!_dragging) return;
    _dragging = false;
    final base = _gestureBase!;
    _gestureBase = null;
    final step = _rawDistance < 0 ? 1 : -1;
    final target = _adjacent(base, step);
    final accepted =
        !cancelled &&
        _rawDistance.abs() >= todayPullThreshold &&
        widget.canSelect(target);
    _rawDistance = 0;
    if (_boundaryOffset != 0 && _to == null) {
      if (_motion) {
        final offset = _boundaryOffset;
        _progress.value = 0;
        _boundaryReturn = offset;
        _progress.animateTo(1, duration: const Duration(milliseconds: 160), curve: Curves.easeOutCubic);
      } else { setState(() => _boundaryOffset = 0); }
    }
    if (accepted) {
      widget.onCommit(target);
      _request(target);
    } else if (_to != null) {
      // 外部date是已提交值；反向打断完成动画又取消，应恢复已提交的目标页。
      _animateTo(widget.date == _from ? 0 : 1);
    }
  }

  void _resetToCommitted() {
    _progress.stop();
    _dragging = false;
    _gestureBase = null;
    _pending = null;
    _from = widget.date;
    _current = widget.frameBuilder(_from);
    _to = null;
    _candidate = null;
    _boundaryOffset = 0;
    _boundaryReturn = null;
    _returning = false;
    _progress.value = 0;
  }

  @override
  void didUpdateWidget(TodayDateTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revision != oldWidget.revision) {
      setState(_resetToCommitted);
      return;
    }
    if (widget.recenter != oldWidget.recenter) {
      _dragging = false;
      _gestureBase = null;
      _pending = null;
      _resetAtRest = true;
      if (_to == null && _from == widget.date) {
        setState(() {
          _current = widget.frameBuilder(_from);
          _resetAtRest = false;
        });
      } else {
        _request(widget.date);
      }
      return;
    }
    if (widget.date != oldWidget.date && !_dragging && widget.date != _to && widget.date != _pending) _request(widget.date);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!TickerMode.valuesOf(context).enabled || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      if (_to != null || _dragging) _resetToCommitted();
    } else if (!CampusMotion.allowed(context) && _to != null && !_dragging) {
      _resetToCommitted();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) setState(_resetToCommitted);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progress.removeStatusListener(_settled);
    _progress.dispose();
    super.dispose();
  }

  Widget _frame(
    String date,
    TodayDateFrame frame, {
    required bool entering,
    required bool header,
  }) {
    final active = date == widget.date && !_dragging;
    final direction = _to == null || _to!.compareTo(_from) >= 0 ? 1.0 : -1.0;
    final travel = header ? 12.0 : 32.0;
    return Positioned.fill(
      top: header ? 0 : widget.bodyInset,
      bottom: header ? 0 : widget.bodyInset,
      key: ValueKey('today-${header ? 'header' : 'frame'}-$date'),
      child: IgnorePointer(
        ignoring: !active || _to != null,
        child: ExcludeSemantics(
          excluding: !active,
          child: TickerMode(
            enabled: active,
            child: FadeTransition(
              opacity: _to == null
                  ? const AlwaysStoppedAnimation(1.0)
                  : entering
                  ? _inOpacity
                  : _outOpacity,
              child: AnimatedBuilder(
                animation: _progress,
                child: header ? frame.header : frame.body,
                builder: (context, child) => Transform.translate(
                  key: ValueKey(
                    'today-${header ? 'date-offset' : 'offset'}-$date',
                  ),
                  offset: Offset(
                    0,
                    _to == null
                        ? (_boundaryReturn == null ? _boundaryOffset : _boundaryReturn! * (1 - _progress.value))
                        : direction *
                              travel *
                              (entering
                                  ? 1 - _progress.value
                                  : -_progress.value),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewport({required bool header}) => ClipRect(
    child: Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        _frame(_from, _current, entering: false, header: header),
        if (_to != null)
          _frame(_to!, _candidate!, entering: true, header: header),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final header = TodayDayNavigation(
      onStart: _begin,
      onPull: _pull,
      onRelease: _release,
      child: _viewport(header: true),
    );
    final body = TodayDayNavigation(
      onStart: _begin,
      onPull: _pull,
      onRelease: _release,
      scrollable: _current.scrollable,
      child: _viewport(header: false),
    );
    return widget.builder(context, header, body, _to != null);
  }
}
