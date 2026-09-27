import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// [人工决策-2026-09-25 16:24:31] 全应用页面360ms进入/320ms返回、弹层300ms，保留即时操作与减少动画，不保留旧账号截图。
const campusEnter = Duration(milliseconds: 360);
const campusExit = Duration(milliseconds: 320);
const campusOverlay = AnimationStyle(
  duration: Duration(milliseconds: 300),
  reverseDuration: Duration(milliseconds: 260),
  curve: Curves.easeInOutCubic,
  reverseCurve: Curves.easeInOutCubic,
);

Widget campusPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  if (MediaQuery.disableAnimationsOf(context)) return child;
  final direction = Directionality.of(context) == TextDirection.rtl
      ? -1.0
      : 1.0;
  final curve = animation.drive(CurveTween(curve: Curves.easeInOutCubic));
  final outgoing = secondaryAnimation
      .drive(
        CurveTween(curve: Curves.easeInOutCubic),
      )
      .drive(Tween(begin: 1.0, end: 0.0));
  return FadeTransition(
    opacity: outgoing,
    child: FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: curve.drive(
          Tween(begin: Offset(.035 * direction, .012), end: Offset.zero),
        ),
        child: child,
      ),
    ),
  );
}

// [人工决策-2026-09-25 17:43:48] GoRouter与push统一Material路由契约，旧页在完整进度内退场，不前半段抢先消失。
MaterialPage<void> campusPage({required LocalKey key, required Widget child}) => MaterialPage<void>(key: key, child: child);

class CampusPageTransitions extends PageTransitionsBuilder {
  const CampusPageTransitions();
  @override
  Duration get transitionDuration => campusEnter;
  @override
  Duration get reverseTransitionDuration => campusExit;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => campusPageTransition(context, animation, secondaryAnimation, child);
}

class CampusEntryFade extends StatefulWidget {
  const CampusEntryFade({super.key, required this.child});
  final Widget child;
  @override
  State<CampusEntryFade> createState() => _CampusEntryFadeState();
}

class _CampusEntryFadeState extends State<CampusEntryFade>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: campusEnter,
  );
  bool _started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 1;
      _started = true;
    } else if (!_started) {
      _started = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _controller.drive(CurveTween(curve: Curves.easeInOutCubic)),
    child: widget.child,
  );
}

class CampusDialogRoute<T> extends DialogRoute<T> {
  CampusDialogRoute({required super.context, required super.builder, super.barrierDismissible = true})
      : super(themes: InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: true).context),
          animationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : campusOverlay);
  @override
  Curve get barrierCurve => Curves.easeInOutCubic;
  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final media = MediaQuery.of(context);
    if (media.disableAnimations) return child;
    // [人工决策-2026-09-25 17:43:48] 遮罩、模糊、弹窗共用route进度；反向同程，修复固定sigma导致的突变，不叠加默认fade。
    return AnimatedBuilder(animation: animation, child: child, builder: (context, child) {
      final progress = Curves.easeInOutCubic.transform(animation.value);
      final sigma = media.highContrast || media.accessibleNavigation ? 0.0 : 5 * progress;
      return Stack(children: [
        if (sigma > 0) Positioned.fill(child: IgnorePointer(child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: const SizedBox.expand()))),
        Opacity(opacity: progress, child: Transform.translate(offset: Offset(0, 8 * (1 - progress)), child: child)),
      ]);
    });
  }
}

Future<T?> showCampusDialog<T>({required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true}) => Navigator.of(context, rootNavigator: true).push<T>(CampusDialogRoute<T>(context: context, builder: builder, barrierDismissible: barrierDismissible));
