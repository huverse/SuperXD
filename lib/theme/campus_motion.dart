import 'dart:math' as math;

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

// [人工决策-2026-10-04 16:08:17] 页面推入、返回与底栏切换用临界阻尼弹簧曲线（先快后慢、不回弹），时长仍为 360/320/300ms；用户实测确认。
// 页面与底栏分支转场的曲线：临界阻尼弹簧（同鸿蒙 Navigation 默认转场 interpolatingSpring(0, 1, 342, 37)、
// iOS 推入），起步不突兀但立即跟上（约 1/7 处速度最大）、之后长尾减速，不回弹；按固定时长归一化，时长仍以
// campus_transitions.dart 为准。取代 easeInOutCubic：它前 15% 时长只走 1.4%，点按后页面像慢半拍才动。
// 返回、反向时用 flipped，同样先快后慢。
class CampusSpringCurve extends Curve {
  const CampusSpringCurve();
  // ωT：时长内走完约 99.3%，末端速度只剩约 4%，与归一化后的到位衔接无感。
  static const _stiffness = 7.0;
  static final _end = 1 - (1 + _stiffness) * math.exp(-_stiffness);

  @override
  double transformInternal(double t) => (1 - (1 + _stiffness * t) * math.exp(-_stiffness * t)) / _end;
}

const campusSpringCurve = CampusSpringCurve();

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
