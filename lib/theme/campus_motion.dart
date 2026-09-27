import 'package:flutter/material.dart';

// 仅视觉生命周期；后台暂停不代表取消业务请求。
class CampusMotion extends StatefulWidget {
  const CampusMotion({super.key, required this.child});
  final Widget child;
  static bool allowed(BuildContext context) =>
      !MediaQuery.disableAnimationsOf(context) &&
      !WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion &&
      TickerMode.valuesOf(context).enabled &&
      (_MotionScope.maybeOf(context)?.foreground ?? true) &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  @override
  State<CampusMotion> createState() => _CampusMotionState();
}

class _CampusMotionState extends State<CampusMotion>
    with WidgetsBindingObserver {
  bool _reduceMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion;
  @override
  void didChangeAccessibilityFeatures() {
    setState(() => _reduceMotion = WidgetsBinding.instance.platformDispatcher.accessibilityFeatures.reduceMotion);
  }
  bool _foreground =
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground != _foreground) setState(() => _foreground = foreground);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _MotionScope(foreground: _foreground, child: MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: MediaQuery.disableAnimationsOf(context) || _reduceMotion), child: widget.child));
}

class _MotionScope extends InheritedWidget {
  const _MotionScope({required this.foreground, required super.child});
  final bool foreground;
  static _MotionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MotionScope>();
  @override
  bool updateShouldNotify(_MotionScope oldWidget) =>
      foreground != oldWidget.foreground;
}
