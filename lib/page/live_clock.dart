import 'dart:async';

import 'package:flutter/material.dart';

class LiveClock extends StatefulWidget {
  const LiveClock({super.key, required this.child});
  final Widget child;
  static ValueNotifier<DateTime>? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ClockScope>()?.clock;
  // 是否跟着真实时间走（fixed 拨好的时钟不走）：要秒级刷新的界面只在真实时钟下自己计时。
  static bool liveOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ClockScope>()?.live ?? false;
  // 测试用：由调用方拨时间、不挂整分计时器。真实的 LiveClock 到整分会用 DateTime.now() 盖掉测试拨好的时间。
  @visibleForTesting
  static Widget fixed(ValueNotifier<DateTime> clock, {required Widget child}) => _ClockScope(clock: clock, live: false, child: child);
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
  Widget build(BuildContext context) => _ClockScope(clock: _clock, live: true, child: widget.child);
}

class _ClockScope extends InheritedWidget {
  const _ClockScope({required this.clock, required this.live, required super.child});
  final ValueNotifier<DateTime> clock;
  final bool live;
  @override
  bool updateShouldNotify(_ClockScope oldWidget) => clock != oldWidget.clock || live != oldWidget.live;
}
