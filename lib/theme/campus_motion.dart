import 'package:flutter/material.dart';

// [人工决策-2026-10-02 16:43:38] 只有玻璃控件用物理弹簧：按下近临界阻尼快速到位不回弹，松手低阻尼过冲一次再回位；页面转场、列表、切日、课表形变仍不回弹；减少动画时不用弹簧，直接到位。
SpringDescription? campusGlassSpring(BuildContext context, {required bool release}) =>
    MediaQuery.disableAnimationsOf(context) ? null : release ? _glassRelease : _glassPress;
// 指示器跨格移动用的弹簧：过冲约5%，比按压回位更收敛，避免长距离移动时晃动。
SpringDescription? campusGlassTravelSpring(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context) ? null : _glassTravel;
final _glassPress = SpringDescription.withDampingRatio(mass: 1, stiffness: 900, ratio: .9);
final _glassRelease = SpringDescription.withDampingRatio(mass: 1, stiffness: 340, ratio: .45);
final _glassTravel = SpringDescription.withDampingRatio(mass: 1, stiffness: 500, ratio: .7);

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
