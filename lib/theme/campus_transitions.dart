import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/native_glass.dart';
import 'package:superxd/theme/campus_typesetting.dart';

// [人工决策-2026-09-25 16:24:31] 全应用页面360ms进入/320ms返回、弹层300ms，保留即时操作与减少动画，不保留旧账号截图。
// iOS 的页面推入与返回改用系统的 500ms（[人工决策] 见 _IosPageSlide），弹层照旧。
const campusEnter = Duration(milliseconds: 360);
const campusExit = Duration(milliseconds: 320);
const _iosPush = Duration(milliseconds: 500);
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
  Widget child, {
  bool coversPopup = false,
}) {
  if (campusIos) return _IosPageSlide(animation: animation, secondaryAnimation: secondaryAnimation, child: _CoverBackdrop(animation: animation, child: child));
  if (MediaQuery.disableAnimationsOf(context)) return child;
  return _CampusPageSlide(animation: animation, secondaryAnimation: secondaryAnimation, child: coversPopup ? _CoverBackdrop(animation: animation, child: child) : child);
}

// 页面推在弹窗、弹层之上（如协议更新提示里点开政策）：页面透明，下面的弹窗不跟着退场，进出转场时会透过新页露出来、叠成两层，
// 停稳后才被路由摘掉。这时转场期间给页面垫一份同相位的背景副本，像原生打开新页面那样整页盖住弹窗；停稳即撤，背景仍只画一份。
mixin _CampusCoverRoute<T> on PageRoute<T> {
  bool _coversPopup = false;
  // 路由自己的动画控制器：iOS 跟手返回松手后要按系统的收尾曲线续接（见 _IosBackSwipe）。
  AnimationController? _campusController;

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    _coversPopup = previousRoute is PopupRoute;
    super.didChangePrevious(previousRoute);
  }
}

class _CoverBackdrop extends StatefulWidget {
  const _CoverBackdrop({required this.animation, required this.child});
  final Animation<double> animation;
  final Widget child;

  @override
  State<_CoverBackdrop> createState() => _CoverBackdropState();
}

class _CoverBackdropState extends State<_CoverBackdrop> {
  late bool _settled = widget.animation.isCompleted;
  // 副本画一次就拍成图，之后每帧只贴图：弹窗开着时云雾停着（见 CampusAtmosphere 的 overlays），副本不会变；
  // 直接画副本每帧要重画几层全屏大渐变，OPPO 上转场每帧多约 3ms。
  final _snapshot = SnapshotController(allowSnapshotting: true);

  void _status(AnimationStatus status) {
    if (status.isCompleted != _settled) setState(() => _settled = status.isCompleted);
  }

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_status);
  }

  @override
  void didUpdateWidget(_CoverBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation == widget.animation) return;
    oldWidget.animation.removeStatusListener(_status);
    widget.animation.addStatusListener(_status);
    _settled = widget.animation.isCompleted;
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_status);
    _snapshot.dispose();
    super.dispose();
  }

  // 副本与页面同在平移里；子树位置不变，换显隐时页面不重建。
  @override
  Widget build(BuildContext context) {
    final backdrop = CampusBackdrop.maybeOf(context);
    return Stack(fit: StackFit.expand, children: [
      if (backdrop != null && !_settled) SnapshotWidget(controller: _snapshot, child: backdrop(context)) else const SizedBox.shrink(),
      widget.child,
    ]);
  }
}

// 页面透明、共用一份背景，新旧页整屏并排平移、互不重叠；不淡入淡出：玻璃在 Opacity 下取不到背景，
// 整段转场会显示成底色，最后一帧才突然变回玻璃。旧页由新页同一进度、同一曲线推出，全程连续退场。
// 曲线为临界阻尼弹簧（见 campus_motion.dart），推入与返回都先快后慢；跟手返回期间（含松手后的收尾）按进度线性
// 平移，页面严格跟着手指，收尾到端点时两种映射重合，切回曲线不跳。
class _CampusPageSlide extends StatefulWidget {
  const _CampusPageSlide({required this.animation, required this.secondaryAnimation, required this.child});
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_CampusPageSlide> createState() => _CampusPageSlideState();
}

class _CampusPageSlideState extends State<_CampusPageSlide> {
  late CurvedAnimation _enter = _curved(widget.animation);
  late CurvedAnimation _leave = _curved(widget.secondaryAnimation);

  static CurvedAnimation _curved(Animation<double> parent) =>
      CurvedAnimation(parent: parent, curve: campusSpringCurve, reverseCurve: campusSpringCurve.flipped);

  @override
  void didUpdateWidget(_CampusPageSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _enter.dispose();
      _enter = _curved(widget.animation);
    }
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _leave.dispose();
      _leave = _curved(widget.secondaryAnimation);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _leave.dispose();
    super.dispose();
  }

  Widget _slide(BuildContext context, bool following) {
    final direction = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    return SlideTransition(
      position: (following ? widget.secondaryAnimation : _leave).drive(Tween(begin: Offset.zero, end: Offset(-direction, 0))),
      child: SlideTransition(
        position: (following ? widget.animation : _enter).drive(Tween(begin: Offset(direction, 0), end: Offset.zero)),
        child: widget.child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gesture = Navigator.maybeOf(context)?.userGestureInProgressNotifier;
    return gesture == null
        ? _slide(context, false)
        : ValueListenableBuilder<bool>(valueListenable: gesture, builder: (context, following, _) => _slide(context, following));
  }
}

// [人工决策-2026-10-04 16:08:17] 开启跟手返回：侧滑时页面随手指平移，松手续接返回或回弹，只作用于最前面的页面；用户实测确认。
// 跟手返回（Android 14 起的预测性返回，同 iOS、鸿蒙的侧滑返回）：手势中页面随手指平移、露出上一页，
// 松手由系统判定返回或回弹，都从当前位置续接。只有真正在最前面的页面响应：底栏其他分支里压着的页面、
// 被上层页面盖住的页面都不响应，否则一次手势会把看不见的页面也返回掉。
// 不允许返回的页面（首页、有未保存编辑的 PopScope）和减少动画时不接管，手势按普通返回处理。
class _CampusBackGesture extends StatefulWidget {
  const _CampusBackGesture({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_CampusBackGesture> createState() => _CampusBackGestureState();
}

class _CampusBackGestureState extends State<_CampusBackGesture> with WidgetsBindingObserver {
  bool _tracking = false;

  // 被不透明页面盖住的路由、底栏不可见的分支都处在关闭的 TickerMode 下，据此排除。
  bool get _frontmost => widget.route.isCurrent && widget.route.popGestureEnabled && TickerMode.valuesOf(context).enabled;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || MediaQuery.disableAnimationsOf(context) || !_frontmost) return false;
    _tracking = true;
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (_tracking) widget.route.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_tracking) return;
    _tracking = false;
    widget.route.handleCancelBackGesture();
  }

  // 不用路由自带的 handleCommitBackGesture：它在返回中把进度重置到 1 再倒放，并排平移会先跳回原位。
  // 直接返回，路由从手指松开的进度倒放；收尾结束再结束手势状态，期间保持线性跟手映射。
  @override
  void handleCommitBackGesture() {
    if (!_tracking) return;
    _tracking = false;
    final navigator = widget.route.navigator!, animation = widget.route.animation!;
    navigator.pop();
    if (!animation.isAnimating) {
      navigator.didStopUserGesture();
      return;
    }
    late final AnimationStatusListener settled;
    settled = (status) {
      if (status.isAnimating) return;
      animation.removeStatusListener(settled);
      navigator.didStopUserGesture();
    };
    animation.addStatusListener(settled);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// [人工决策-2026-09-25 17:43:48] GoRouter与push统一Material路由契约，旧页在完整进度内退场，不前半段抢先消失。
MaterialPage<void> campusPage({required LocalKey key, required Widget child}) => _CampusPage<void>(key: key, child: child);

// 全应用页面路由一律用它（GoRouter 页面经 campusPage），不直接用 MaterialPageRoute：契约与转场同 Material，
// 只是转场计时从新页首帧画完后开始，首帧再慢也能完整滑入，不会硬切（见 CampusFirstFrameVsync）。
class CampusPageRoute<T> extends MaterialPageRoute<T> with _CampusCoverRoute<T> {
  CampusPageRoute({required super.builder, super.settings});
  // 开发者模式下记一笔命令式推入与返回的页面（go_router 的页面按路径另记，见 app_diagnostics.dart 的 watchRoutes），
  // 卡顿统计才对得上是哪个页面（10-27 iPhone 日志里卡得最重的两段落在这类页面上，看不出是哪页）。
  String? _page;
  @override
  AnimationController createAnimationController() => _campusController = _firstFrameController(this);
  @override
  Widget buildContent(BuildContext context) {
    final page = super.buildContent(context);
    if (_page == null) {
      _page = page.runtimeType.toString();
      if (campusDiagnostics) campusLog('[Route] action=push page=$_page');
    }
    return page;
  }

  @override
  bool didPop(T? result) {
    if (campusDiagnostics && _page != null) campusLog('[Route] action=pop page=$_page');
    return super.didPop(result);
  }
}

AnimationController _firstFrameController(PageRoute<dynamic> route) => AnimationController(
  duration: route.transitionDuration,
  reverseDuration: route.reverseTransitionDuration,
  debugLabel: route.debugLabel,
  vsync: CampusFirstFrameVsync(route.navigator!),
);

class _CampusPage<T> extends MaterialPage<T> {
  const _CampusPage({required super.key, required super.child});
  @override
  Route<T> createRoute(BuildContext context) => _CampusPageBasedRoute<T>(page: this);
}

class _CampusPageBasedRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T>, _CampusCoverRoute<T> {
  _CampusPageBasedRoute({required MaterialPage<T> page}) : super(settings: page);
  MaterialPage<T> get _page => settings as MaterialPage<T>;
  @override
  Widget buildContent(BuildContext context) => _page.child;
  @override
  bool get maintainState => _page.maintainState;
  @override
  bool get fullscreenDialog => _page.fullscreenDialog;
  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
  @override
  AnimationController createAnimationController() => _campusController = _firstFrameController(this);
}

class CampusPageTransitions extends PageTransitionsBuilder {
  const CampusPageTransitions();
  @override
  Duration get transitionDuration => campusIos ? _iosPush : campusEnter;
  @override
  Duration get reverseTransitionDuration => campusIos ? _iosPush : campusExit;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => campusIos
      ? _IosBackSwipe(route: route, child: campusPageTransition(context, animation, secondaryAnimation, child))
      : _CampusBackGesture(route: route, child: campusPageTransition(context, animation, secondaryAnimation, child, coversPopup: route is _CampusCoverRoute<T> && route._coversPopup));
}

// [人工决策-2026-10-27 00:26:51] iOS 的页面转场同系统推入（用户选定「iOS 系统推入样式」，取代 09-25「整屏并排平移」与 360/320ms 在 iOS 上的做法，安卓照旧）：
// 新页面从右边盖进来、左边缘带一道阴影，旧页面左移三分之一并略微变暗；两页的曲线与 500ms 时长同 Flutter 的 CupertinoPageRoute，
// 系统底栏跟着壳页走用的是同一对曲线（见 native_glass.dart 的 NativeTabBar）。页面透明、共用一份背景，所以新页面在转场期间垫一份背景副本
// （_CoverBackdrop，停稳即撤），盖住下面的旧页面。变暗是画在旧页面上的一层，不用祖先 Opacity（玻璃在半透明图层下取不到背景）。
// 跟手返回期间按进度线性平移；减少动画时推入与返回直接到位，跟手返回照样跟手。
class _IosPageSlide extends StatefulWidget {
  const _IosPageSlide({required this.animation, required this.secondaryAnimation, required this.child});
  final Animation<double> animation;
  final Animation<double> secondaryAnimation;
  final Widget child;

  @override
  State<_IosPageSlide> createState() => _IosPageSlideState();
}

class _IosPageSlideState extends State<_IosPageSlide> {
  late CurvedAnimation _enter = NativeTabBar.enterCurve(widget.animation);
  late CurvedAnimation _leave = NativeTabBar.leaveCurve(widget.secondaryAnimation);

  @override
  void didUpdateWidget(_IosPageSlide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _enter.dispose();
      _enter = NativeTabBar.enterCurve(widget.animation);
    }
    if (oldWidget.secondaryAnimation != widget.secondaryAnimation) {
      _leave.dispose();
      _leave = NativeTabBar.leaveCurve(widget.secondaryAnimation);
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _leave.dispose();
    super.dispose();
  }

  Widget _slide(BuildContext context, bool following) {
    if (MediaQuery.disableAnimationsOf(context) && !following) return widget.child;
    final direction = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    final enter = following ? widget.animation : _enter, leave = following ? widget.secondaryAnimation : _leave;
    return SlideTransition(
      position: leave.drive(Tween(begin: Offset.zero, end: Offset(-direction / 3, 0))),
      transformHitTests: false,
      child: Stack(fit: StackFit.expand, children: [
        SlideTransition(
          position: enter.drive(Tween(begin: Offset(direction, 0), end: Offset.zero)),
          child: CustomPaint(painter: _IosEdgeShadow(enter, direction), child: widget.child),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: leave,
              builder: (context, _) => leave.value <= 0 ? const SizedBox.shrink() : ColoredBox(color: Colors.black.withValues(alpha: .094 * leave.value)),
            ),
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final gesture = Navigator.maybeOf(context)?.userGestureInProgressNotifier;
    return gesture == null
        ? _slide(context, false)
        : ValueListenableBuilder<bool>(valueListenable: gesture, builder: (context, following, _) => _slide(context, following));
  }
}

// 新页面左边缘外的阴影（同 Flutter 的 CupertinoPageTransition）：宽为页面的 5%，随进入的进度加深；停稳时在屏幕外。
class _IosEdgeShadow extends CustomPainter {
  _IosEdgeShadow(this.progress, this.direction) : super(repaint: progress);
  final Animation<double> progress;
  final double direction;

  @override
  void paint(Canvas canvas, Size size) {
    final strength = progress.value;
    if (strength <= 0 || strength >= 1) return;
    final width = size.width * .05;
    final rect = direction > 0 ? Rect.fromLTWH(-width, 0, width, size.height) : Rect.fromLTWH(size.width, 0, width, size.height);
    canvas.drawRect(rect, Paint()..shader = LinearGradient(
      begin: direction > 0 ? Alignment.centerLeft : Alignment.centerRight,
      end: direction > 0 ? Alignment.centerRight : Alignment.centerLeft,
      colors: [for (final alpha in const [0, 4, 18, 56]) Color.fromARGB((alpha * strength).round(), 0, 0, 0)],
      stops: const [0, .3, .6, 1],
    ).createShader(rect));
  }

  @override
  bool shouldRepaint(_IosEdgeShadow oldDelegate) => oldDelegate.progress != progress || oldDelegate.direction != direction;
}

// [人工决策] 见 _IosPageSlide：iOS 跟手返回在页面任意位置向右滑都能返回（同 iOS 26 的系统导航），页面随手指平移，
// 松手按速度与位置决定返回还是弹回（同 CupertinoPageRoute：快甩超过每秒一屏宽按方向，否则过半返回），收尾 350ms。
// 只有最前面的页面响应；首页与有未保存编辑（PopScope 不许返回）的页面不接；横向滚动的列表、滑杆、输入框等里层手势优先。
class _IosBackSwipe extends StatefulWidget {
  const _IosBackSwipe({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;

  @override
  State<_IosBackSwipe> createState() => _IosBackSwipeState();
}

class _IosBackSwipeState extends State<_IosBackSwipe> {
  static const _settle = Duration(milliseconds: 350);
  bool _tracking = false;

  void _start(DragStartDetails details) {
    final route = widget.route;
    if (!route.isCurrent || !route.popGestureEnabled || !TickerMode.valuesOf(context).enabled) return;
    _tracking = true;
    route.handleStartBackGesture(progress: 1);
  }

  double get _width => context.size?.width ?? 1;

  double get _direction => Directionality.of(context) == TextDirection.rtl ? -1 : 1;

  void _update(DragUpdateDetails details) {
    if (!_tracking) return;
    widget.route.handleUpdateBackGestureProgress(progress: (widget.route.animation!.value - _direction * details.primaryDelta! / _width).clamp(0.0, 1.0));
  }

  void _end(double velocity) {
    if (!_tracking) return;
    _tracking = false;
    final route = widget.route;
    final navigator = route.navigator!;
    final controller = route is _CampusCoverRoute ? route._campusController : null;
    if (controller == null || !route.isCurrent) {
      route.handleCommitBackGesture();
      return;
    }
    final back = velocity.abs() >= 1 ? velocity > 0 : controller.value < .5;
    if (back) {
      navigator.pop();
      if (controller.isAnimating) controller.animateBack(0, duration: _settle, curve: Curves.fastEaseInToSlowEaseOut);
    } else {
      controller.animateTo(1, duration: _settle, curve: Curves.fastEaseInToSlowEaseOut);
    }
    if (!controller.isAnimating) {
      navigator.didStopUserGesture();
      return;
    }
    // 收尾期间保持跟手状态，页面按进度线性走，不中途换曲线。
    late final AnimationStatusListener settled;
    settled = (status) {
      controller.removeStatusListener(settled);
      navigator.didStopUserGesture();
    };
    controller.addStatusListener(settled);
  }

  @override
  Widget build(BuildContext context) => widget.route.isFirst
      ? widget.child
      : GestureDetector(
          behavior: HitTestBehavior.translucent,
          dragStartBehavior: DragStartBehavior.down,
          onHorizontalDragStart: _start,
          onHorizontalDragUpdate: _update,
          onHorizontalDragEnd: (details) => _end(_direction * details.velocity.pixelsPerSecond.dx / _width),
          onHorizontalDragCancel: () => _end(0),
          child: widget.child,
        );
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

  // 内容不套透明度，改由上面一层同相位背景淡出，观感等同内容淡入，玻璃从第一帧起取到真实背景；没有背景时直接显示。
  @override
  Widget build(BuildContext context) {
    final backdrop = CampusBackdrop.maybeOf(context);
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) => Stack(
        fit: StackFit.expand,
        children: [
          child!,
          if (backdrop != null && !_controller.isCompleted)
            IgnorePointer(
              child: Opacity(
                opacity: 1 - Curves.easeInOutCubic.transform(_controller.value),
                child: backdrop(context),
              ),
            ),
        ],
      ),
    );
  }
}

// glassPanel 为真表示内容是 CampusGlassDialog 这类 overlay 玻璃面板，由面板按路由进度自己显隐；
// 日期选择器等系统弹窗传 false，仍整体改不透明度。
class CampusDialogRoute<T> extends DialogRoute<T> with CampusOverlayDepthRoute<T> {
  CampusDialogRoute({required super.context, required super.builder, super.barrierDismissible = true, this.glassPanel = true})
      : super(themes: InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: true).context),
          animationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : campusOverlay);
  final bool glassPanel;
  late final Animation<double> _reveal = animation!.drive(CurveTween(curve: Curves.easeInOutCubic));
  @override
  Curve get barrierCurve => Curves.easeInOutCubic;
  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) {
    final media = MediaQuery.of(context);
    if (media.disableAnimations) return child;
    // [人工决策-2026-09-25 17:43:48] 遮罩、模糊、弹窗共用route进度；反向同程，修复固定sigma导致的突变，不叠加默认fade。
    // 玻璃面板的显隐同样取这条进度，只是交给面板自己做（见 CampusOverlayReveal），外层不再套 Opacity。
    return AnimatedBuilder(animation: animation, child: glassPanel ? CampusOverlayReveal(animation: _reveal, child: child) : child, builder: (context, child) {
      final progress = Curves.easeInOutCubic.transform(animation.value);
      // iOS 不模糊整屏、只压暗（同系统弹窗；整屏模糊在转场里每帧都要重算，更费电）。
      final sigma = campusIos || media.highContrast || media.accessibleNavigation ? 0.0 : 5 * progress;
      final moved = Transform.translate(offset: Offset(0, 8 * (1 - progress)), child: child);
      return Stack(children: [
        if (sigma > 0) Positioned.fill(child: IgnorePointer(child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: const SizedBox.expand()))),
        glassPanel ? moved : Opacity(opacity: progress, child: moved),
      ]);
    });
  }
}

Future<T?> showCampusDialog<T>({required BuildContext context, required WidgetBuilder builder, bool barrierDismissible = true, bool glassPanel = true}) => Navigator.of(context, rootNavigator: true).push<T>(CampusDialogRoute<T>(context: context, builder: builder, barrierDismissible: barrierDismissible, glassPanel: glassPanel));

// 统一的玻璃弹窗：版式同 AlertDialog（标题、可滚动内容、右下操作），面板为 overlay 玻璃、圆角 24。
// options 对应 SimpleDialog 的选项行，贴边排列、整体可滚动；solid 为真时固定实色（如验证码需要稳定底色）。
// 弹窗操作区：两个以内按钮等宽并排；三个及以上，或并排时任一个按钮的文字在自己那一半里放不下，就竖排、主操作在最上
// （调用处仍按“取消在前”书写，竖排时倒过来摆；读屏与焦点顺序照写的顺序）。放不放得下按按钮的最大固有宽度判断。
class _CampusDialogActions extends MultiChildRenderObjectWidget {
  const _CampusDialogActions({required this.stacked, required super.children});
  final bool stacked;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCampusDialogActions(stacked);

  @override
  void updateRenderObject(BuildContext context, _RenderCampusDialogActions renderObject) => renderObject.stacked = stacked;
}

class _DialogActionData extends ContainerBoxParentData<RenderBox> {}

class _RenderCampusDialogActions extends RenderBox with ContainerRenderObjectMixin<RenderBox, _DialogActionData>, RenderBoxContainerDefaultsMixin<RenderBox, _DialogActionData> {
  _RenderCampusDialogActions(this._stacked);
  static const _rowGap = 12.0, _columnGap = 8.0;
  bool _stacked;
  set stacked(bool value) {
    if (value == _stacked) return;
    _stacked = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _DialogActionData) child.parentData = _DialogActionData();
  }

  List<RenderBox> get _children {
    final children = <RenderBox>[];
    var child = firstChild;
    while (child != null) {
      children.add(child);
      child = childAfter(child);
    }
    return children;
  }

  bool _fitsRow(double width) {
    if (_stacked || childCount == 0) return !_stacked;
    final each = (width - _rowGap * (childCount - 1)) / childCount;
    return _children.every((child) => child.getMaxIntrinsicWidth(double.infinity) <= each);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _children.fold(0.0, (widest, child) => math.max(widest, child.getMinIntrinsicWidth(height)));

  @override
  double computeMaxIntrinsicWidth(double height) => _children.fold(0.0, (sum, child) => sum + child.getMaxIntrinsicWidth(height)) + _rowGap * math.max(0, childCount - 1);

  @override
  double computeMinIntrinsicHeight(double width) => _fitsRow(width)
      ? _children.fold(0.0, (tallest, child) => math.max(tallest, child.getMinIntrinsicHeight((width - _rowGap * (childCount - 1)) / childCount)))
      : _children.fold(0.0, (sum, child) => sum + child.getMinIntrinsicHeight(width)) + _columnGap * math.max(0, childCount - 1);

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, dry: true);

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    final children = _children;
    if (children.isEmpty) return constraints.smallest;
    if (_fitsRow(width)) {
      final each = (width - _rowGap * (children.length - 1)) / children.length;
      final sizes = [for (final child in children) dry ? child.getDryLayout(BoxConstraints.tightFor(width: each)) : (child..layout(BoxConstraints.tightFor(width: each), parentUsesSize: true)).size];
      final height = sizes.fold(0.0, (tallest, size) => math.max(tallest, size.height));
      if (!dry) {
        for (final (index, child) in children.indexed) {
          (child.parentData! as _DialogActionData).offset = Offset(index * (each + _rowGap), (height - child.size.height) / 2);
        }
      }
      return constraints.constrain(Size(width, height));
    }
    var y = 0.0;
    for (final child in children.reversed) {
      final size = dry ? child.getDryLayout(BoxConstraints.tightFor(width: width)) : (child..layout(BoxConstraints.tightFor(width: width), parentUsesSize: true)).size;
      if (!dry) (child.parentData! as _DialogActionData).offset = Offset(0, y);
      y += size.height + _columnGap;
    }
    return constraints.constrain(Size(width, y - _columnGap));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => defaultHitTestChildren(result, position: position);
}

class CampusGlassDialog extends StatelessWidget {
  const CampusGlassDialog({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.options,
    this.scrollable = false,
    this.solid = false,
  });
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final List<Widget>? options;
  final bool scrollable;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final dialogTheme = Theme.of(context).dialogTheme;
    final textTheme = Theme.of(context).textTheme;
    final titleStyle = dialogTheme.titleTextStyle ?? textTheme.headlineSmall!;
    final contentStyle = dialogTheme.contentTextStyle ?? textTheme.bodyMedium!;
    final options = this.options;
    final body = options != null
        ? SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: options))
        : scrollable
        ? SingleChildScrollView(child: content)
        : content;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: title == null ? MaterialLocalizations.of(context).alertDialogLabel : null,
        child: CampusOverlayGlass(
          radius: 24,
          solid: solid,
          child: IntrinsicWidth(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title case final title?)
                  Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, options == null && body == null ? 20 : 0),
                    child: DefaultTextStyle(style: titleStyle, child: title),
                  ),
                if (body != null)
                  Flexible(
                    child: Padding(
                      padding: options == null
                          ? EdgeInsets.fromLTRB(24, title == null ? 24 : 16, 24, actions.isEmpty ? 24 : 0)
                          : const EdgeInsets.fromLTRB(0, 12, 0, 16),
                      child: DefaultTextStyle(style: contentStyle, child: body),
                    ),
                  ),
                // [人工决策-2026-10-04 15:29:32] 操作按钮同鸿蒙对话框、iOS 26 弹窗：一到两个等宽并排铺满（取消在左、主操作在右），
                // 三个及以上竖排；操作区的 FilledButton 即本弹窗主操作，自动为强调按钮，TextButton 为中性胶囊。
                // [人工决策-2026-10-19 19:22:39] 两个按钮并排时任一个的文字在半宽里放不下（窄屏、大字号），改为竖排（用户选定，同 iOS、鸿蒙放不下时的做法）：
                // 以前硬并排，「开始同步」在 360dp、1.3 倍字号下折出单独一个「步」。竖排同三个及以上：主操作在最上。
                // iOS 上确认与提示改用系统弹窗、按系统排布（[人工决策] 见 native_glass.dart），带自定义内容的弹窗仍按上两条。
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                    child: FilledButtonTheme(
                      data: FilledButtonThemeData(style: campusProminent.merge(Theme.of(context).filledButtonTheme.style)),
                      child: _CampusDialogActions(stacked: actions.length > 2, children: actions),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// 轻提示：沿用 SnackBar 的排队、读屏播报、时长与滑动关闭，背景透明，内容是 overlay 玻璃胶囊；
// 不用库的 GlassToast，因为它的操作按钮触区只有 32，低于 48 的下限。实色档面板为 surface。
// 用固定样式：M3 浮动样式会整体淡入，玻璃要到淡入结束才突然出现；固定样式只做高度展开，边距由胶囊外层自己留。
// [人工决策-2026-10-15 23:17:30] 弹层、弹窗、菜单里发的提示浮在最上层（用户选定主题层统一修，同 Android 弹层里的 Snackbar、
// iOS 窗口最上层的提示）：SnackBar 只会进底下那页的 Scaffold，被弹层盖住（真机试用时发现内嵌地图与签到弹层的提示都看不到）；
// 也不能给弹层套 Scaffold，它的 Material 会吃掉点按，点遮罩关不掉弹层。所以这种情况改插进根 Overlay，外观、时长、读屏播报与下滑关闭同 SnackBar。
void showCampusToast(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  final duration = Duration(seconds: action == null ? 4 : 6);
  if (ModalRoute.of(context) is PopupRoute) {
    _showOverlayToast(context, message, duration: duration, action: action, onAction: onAction);
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  final palette = CampusPalette.of(context);
  // 同一时刻一条、新的顶掉旧的：连着发几条时（如连点版本号）hideCurrentSnackBar 只收起正在显示的那条，其余排队各放 4 秒，
  // 最新的那条要等很久才出来；clearSnackBars 连排队的一起清掉。
  messenger
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.fixed,
      hitTestBehavior: HitTestBehavior.deferToChild,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      duration: duration,
      content: _toastCapsule(palette, message, action: action, onAction: () {
        messenger.hideCurrentSnackBar();
        onAction!();
      }),
    ));
}

Widget _toastCapsule(CampusPalette palette, String message, {required String? action, required VoidCallback onAction}) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
  child: CampusOverlayGlass(
    radius: 18,
    floating: true,
    child: Padding(
      padding: EdgeInsets.fromLTRB(16, action == null ? 14 : 0, action == null ? 16 : 4, action == null ? 14 : 0),
      child: Row(children: [
        Expanded(child: Text(message, style: TextStyle(color: palette.onSurface, fontSize: 14))),
        if (action != null) TextButton(onPressed: onAction, child: Text(action)),
      ]),
    ),
  ),
);

// 浮层里的提示同一时刻只有一条，新的直接顶掉旧的（同 hideCurrentSnackBar）。
OverlayEntry? _overlayToast;

void _showOverlayToast(BuildContext context, String message, {required Duration duration, String? action, VoidCallback? onAction}) {
  _dismissOverlayToast();
  late final OverlayEntry entry;
  void remove() {
    if (_overlayToast != entry) return;
    _dismissOverlayToast();
  }
  entry = OverlayEntry(
    builder: (context) => _OverlayToast(
      message: message,
      duration: duration,
      action: action,
      onAction: () {
        remove();
        onAction!();
      },
      onDone: remove,
    ),
  );
  _overlayToast = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
}

void _dismissOverlayToast() {
  final entry = _overlayToast;
  _overlayToast = null;
  if (entry == null || !entry.mounted) return;
  entry
    ..remove()
    ..dispose();
}

class _OverlayToast extends StatefulWidget {
  const _OverlayToast({required this.message, required this.duration, required this.action, required this.onAction, required this.onDone});
  final String message;
  final Duration duration;
  final String? action;
  final VoidCallback onAction;
  final VoidCallback onDone;

  @override
  State<_OverlayToast> createState() => _OverlayToastState();
}

class _OverlayToastState extends State<_OverlayToast> with SingleTickerProviderStateMixin {
  // 同 SnackBar 固定样式：250ms 高度展开与收起，减少动画时直接出现。
  late final _height = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));
  Timer? _hold;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_hold != null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _height.value = 1;
    } else {
      _height.forward();
    }
    _hold = Timer(widget.duration, () => _height.reverse().then((_) {
      if (mounted) widget.onDone();
    }));
  }

  @override
  void dispose() {
    _hold?.cancel();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      // 弹层被键盘顶起时，提示跟着浮在键盘上面。
      bottom: math.max(media.viewInsets.bottom, media.padding.bottom),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: ClipRect(
          child: AnimatedBuilder(
            animation: _height,
            builder: (context, child) => Align(
              alignment: AlignmentDirectional.topStart,
              heightFactor: Curves.fastOutSlowIn.transform(_height.value),
              child: child,
            ),
            child: Dismissible(
              key: const ValueKey('campusOverlayToast'),
              direction: DismissDirection.down,
              behavior: HitTestBehavior.deferToChild,
              onDismissed: (_) => widget.onDone(),
              child: _toastCapsule(CampusPalette.of(context), widget.message, action: widget.action, onAction: widget.onAction),
            ),
          ),
        ),
      ),
    );
  }
}

// 底部弹层：沿用系统弹层的拖动关闭、返回键与读屏，背景透明，内容放进 CampusSheetPanel。
class CampusSheetRoute<T> extends ModalBottomSheetRoute<T> with CampusOverlayDepthRoute<T> {
  CampusSheetRoute({
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required super.sheetAnimationStyle,
  }) : super(isScrollControlled: true, useSafeArea: true, backgroundColor: Colors.transparent, elevation: 0);
}

// 同弹窗与菜单挂根导航器：遮罩盖住底栏，弹层开着时切不了分支，返回键先关弹层
// （挂在分支导航器上时遮罩盖不到底栏，开着弹层切走再切回，返回键会直接退出应用）。
Future<T?> showCampusSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final localizations = MaterialLocalizations.of(context);
  return navigator.push(CampusSheetRoute<T>(
    builder: builder,
    capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    barrierLabel: localizations.scrimLabel,
    barrierOnTapHint: localizations.scrimOnTapHint(localizations.bottomSheetLabel),
    sheetAnimationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : campusOverlay,
  ));
}

// 弹层面板：与 iOS 26 一致，四周留 8 悬浮、圆角 24 的 overlay 玻璃，底部让出系统手势条；
// 键盘弹出时整块浮到键盘上方（弹层里的签到码、坐标、账号输入框不被键盘盖住）。
class CampusSheetPanel extends StatelessWidget {
  const CampusSheetPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + (media.viewInsets.bottom > 0 ? media.viewInsets.bottom : media.padding.bottom)),
      child: CampusOverlayGlass(radius: 24, child: child),
    );
  }
}

// 只读提示：长文本可滚动，唯一按钮“知道了”。iOS 是系统弹窗（[人工决策] 见 native_glass.dart）。
Future<void> showCampusNotice(BuildContext context, String message, {String? title}) async {
  if (campusIos) {
    await showNativeAlert(title: title, message: message, actions: const [NativeAlertAction('知道了', preferred: true)]);
    return;
  }
  await showCampusDialog<void>(
    context: context,
    builder: (context) => CampusGlassDialog(
      title: title == null ? null : Text(title),
      content: SingleChildScrollView(child: BalancedText(message)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
    ),
  );
}

// 二次确认：仅点确认按钮返回true，取消、点遮罩或系统返回都视为不确认。
// destructive 为真时主按钮是警示红（删除、清空、退出、覆盖、放弃修改等不可撤销的操作）。
// iOS 是系统弹窗：取消在系统给的位置，确认按钮是主操作（警示时为系统警示红）；系统弹窗点空白关不掉。
Future<bool> showCampusConfirm(BuildContext context, {required String title, required String message, required String action, String cancel = '取消', bool barrierDismissible = true, bool destructive = false}) async => campusIos
    ? await showNativeAlert(title: title, message: message, actions: [NativeAlertAction(cancel, cancel: true), NativeAlertAction(action, destructive: destructive, preferred: !destructive)]) == 1
    : await showCampusDialog<bool>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => CampusGlassDialog(
    title: Text(title),
    content: SingleChildScrollView(child: BalancedText(message)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancel)),
      FilledButton(style: destructive ? campusDestructive : null, onPressed: () => Navigator.pop(context, true), child: Text(action)),
    ],
  ),
) == true;
