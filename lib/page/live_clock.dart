import 'dart:async';

import 'package:flutter/material.dart';

class LiveClock extends StatefulWidget {
  const LiveClock({super.key, required this.child});
  final Widget child;
  static ValueNotifier<DateTime>? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ClockScope>()?.clock;
  // 测试用：由调用方拨时间、不挂整分计时器。真实的 LiveClock 到整分会用 DateTime.now() 盖掉测试拨好的时间。
  @visibleForTesting
  static Widget fixed(ValueNotifier<DateTime> clock, {required Widget child}) => _ClockScope(clock: clock, child: child);
  @override
  State<LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<LiveClock> with WidgetsBindingObserver {
  final _clock = ValueNotifier(DateTime.now());
  Timer? _timer;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _schedule(); }
  void _schedule() {
    _timer?.cancel();
    _clock.value = DateTime.now();
    final now = DateTime.now();
    _timer = Timer(Duration(milliseconds: 60000 - now.second * 1000 - now.millisecond), _schedule);
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) { _schedule(); } else { _timer?.cancel(); }
  }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); _timer?.cancel(); _clock.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => _ClockScope(clock: _clock, child: widget.child);
}

class _ClockScope extends InheritedWidget {
  const _ClockScope({required this.clock, required super.child});
  final ValueNotifier<DateTime> clock;
  @override
  bool updateShouldNotify(_ClockScope oldWidget) => clock != oldWidget.clock;
}
