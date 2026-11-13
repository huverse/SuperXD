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

  // 新页面盖上来时收起旧页面的提示条（提示属于弹出它的那一页，同 Compose 每页各自的 SnackbarHost），
  // 它可点可划，留在新页面上会挡住点按；弹窗与弹层盖上来时由提示条自己看 campusOverlayDepth。
  @override
  TickerFuture didPush() {
    hideCampusToast();
    return super.didPush();
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

// 轻提示：同一时刻一条、新的顶掉旧的，插进根 Overlay 浮在最上层；内容是 overlay 玻璃胶囊（实色档面板为 surface），
// 不用库的 GlassToast，因为它的操作按钮触区只有 32，低于 48 的下限。进场 250ms 从下方上浮并显形、退场 200ms 沉下隐去
// （显隐交给 CampusOverlayReveal，同菜单；不裁剪，以前的高度展开用矩形裁剪，把 32 模糊的投影切成了一个方框），
// 减少动画时直接出现、直接拿掉；不带操作 4 秒、带操作 6 秒收起，手指按着时暂停、松手重新计时（同 Material 的 Snackbar），
// 读屏开着时带操作的不自动收起（同 SnackBar），读屏的关闭操作可关。上面又推入页面、打开弹层弹窗菜单时收起（提示属于弹出它的那一层）。
// [人工决策-2026-10-15 23:17:30] 弹层、弹窗、菜单里发的提示浮在最上层（用户选定主题层统一修，同 Android 弹层里的 Snackbar、
// iOS 窗口最上层的提示）：SnackBar 只会进底下那页的 Scaffold，被弹层盖住（真机试用时发现内嵌地图与签到弹层的提示都看不到）；
// 也不能给弹层套 Scaffold，它的 Material 会吃掉点按，点遮罩关不掉弹层。
// [人工决策-2026-11-09 19:18:09] 提示条不挡要点的地方（用户选「上浮避让 + 点穿」；11-09 截图里「已开启开发者模式」压着列表末项，安卓底栏也被它挡住）：
// 停在最上层页面里 CampusToastAnchor 包着的底栏、底部按钮上方（同 Android Material 的 Snackbar.setAnchorView）；
// 不带操作的提示不拦点按，手指直接点到下面（同安卓系统 Toast；11-13 改为胶囊本身可点可划，见下条）；带「撤销」「去打开」的照常可点、下滑收起。
// 所以页面上也不再用 SnackBar：它外层整条 Material 连两边透明的留白都吃掉点按，做不了点穿，位置也只认 Scaffold 自己的底部栏位。
// [人工决策-2026-11-13 13:48:52] 提示条可点可划（用户选「可点可划」，取代上条的「不带操作的不拦点按」；用户反馈提示只能干等它自己消失）：
// 胶囊本身接住触摸，点一下收起，下滑或左右滑划走，按着时暂停计时（同 Sonner、iOS 通知横幅）；胶囊四周的透明留白照旧点穿，
// 带操作的点按钮执行操作；停在锚点上方照旧。
void showCampusToast(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  _dismissToast();
  late final OverlayEntry entry;
  void remove() {
    if (_toast == entry) _dismissToast();
  }
  entry = OverlayEntry(
    builder: (context) => _CampusToast(
      message: message,
      duration: Duration(seconds: action == null ? 4 : 6),
      action: action,
      onAction: () {
        remove();
        onAction!();
      },
      onDone: remove,
    ),
  );
  _toast = entry;
  // 从导航器自己的 context 发时（开发者工具的标记）祖先里没有 Overlay，用这个导航器的。
  (Overlay.maybeOf(context, rootOverlay: true) ?? Navigator.of(context, rootNavigator: true).overlay!).insert(entry);
}

// 提示条的锚点（同 Android Material 的 Snackbar.setAnchorView）：包住页面底部常驻的栏或按钮（底栏、回今天胶囊、页面底部的主按钮），
// 提示条停在它上方、不挡住它。只认最上层路由里、所在分支可见、enabled 的锚点，有几个取最靠上的；弹层开着时底下页面的锚点不算。
class CampusToastAnchor extends StatefulWidget {
  const CampusToastAnchor({super.key, this.enabled = true, required this.child});
  final bool enabled;
  final Widget child;

  @override
  State<CampusToastAnchor> createState() => _CampusToastAnchorState();
}

final _toastAnchors = <_CampusToastAnchorState>{};

class _CampusToastAnchorState extends State<CampusToastAnchor> {
  ModalRoute<Object?>? _route;
  var _branchVisible = true;

  // 锚点上沿在屏幕里的纵坐标；不在最上层路由、分支不可见、没启用或还没排版时为空。
  double? get top {
    if (!widget.enabled || !_branchVisible || !(_route?.isCurrent ?? true)) return null;
    final box = context.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box.localToGlobal(Offset.zero).dy : null;
  }

  @override
  void initState() {
    super.initState();
    _toastAnchors.add(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    _branchVisible = TickerMode.valuesOf(context).enabled;
  }

  @override
  void dispose() {
    _toastAnchors.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

// 提示条底边离所在 Overlay 底边的距离：系统手势区、键盘与锚点里最高的那个。锚点与 Overlay 的位置读的是上一帧排好的，
// 锚点按 Overlay 自己的坐标换算（不拿 MediaQuery 的屏幕尺寸，Overlay 不一定铺在屏幕原点）。
double _toastBottom(BuildContext context) {
  final media = MediaQuery.of(context);
  var bottom = math.max(media.viewInsets.bottom, media.padding.bottom);
  final overlay = Overlay.of(context).context.findRenderObject();
  if (overlay is! RenderBox || !overlay.attached || !overlay.hasSize) return bottom;
  for (final anchor in _toastAnchors) {
    if (anchor.top case final top?) bottom = math.max(bottom, overlay.size.height - overlay.globalToLocal(Offset(0, top)).dy);
  }
  return bottom;
}

Widget _toastCapsule(CampusPalette palette, String message, {required String? action, required VoidCallback onAction}) => CampusOverlayGlass(
  radius: 18,
  floating: true,
  child: Padding(
    padding: EdgeInsets.fromLTRB(16, action == null ? 14 : 0, action == null ? 16 : 4, action == null ? 14 : 0),
    child: Row(children: [
      Expanded(child: Text(message, style: TextStyle(color: palette.onSurface, fontSize: 14))),
      if (action != null) TextButton(onPressed: onAction, child: Text(action)),
    ]),
  ),
);

// 进场从下方上浮的距离。
const _toastRise = 16.0;

OverlayEntry? _toast;
_CampusToastState? _toastState;

// 收起正在显示的提示条（同 Android 的 Snackbar.dismiss()）：用户接着做了一步正常操作、提示已经过时时调（如过河问题犯规后又成功开了船），
// 走同自然收起一样的退场，减少动画时直接拿掉；没有提示条时什么也不做。
void hideCampusToast() {
  final state = _toastState;
  if (state == null || !state.mounted) return _dismissToast();
  state._hide();
}

void _dismissToast() {
  final entry = _toast;
  _toast = null;
  if (entry == null || !entry.mounted) return;
  entry
    ..remove()
    ..dispose();
}

class _CampusToast extends StatefulWidget {
  const _CampusToast({required this.message, required this.duration, required this.action, required this.onAction, required this.onDone});
  final String message;
  final Duration duration;
  final String? action;
  final VoidCallback onAction;
  final VoidCallback onDone;

  @override
  State<_CampusToast> createState() => _CampusToastState();
}

class _CampusToastState extends State<_CampusToast> with TickerProviderStateMixin {
  // 显形进度：进场上浮显形，退场原路沉下隐去（反向 200ms）。
  late final _reveal = AnimationController(vsync: this, duration: const Duration(milliseconds: 250), reverseDuration: const Duration(milliseconds: 200));
  // 松手后划出去或弹回原位。
  late final _settle = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
  Animation<Offset>? _settleOffset;
  // 手指拖动的位移，方向在第一次移动时锁定成横划或竖划；往上拖带阻尼。
  var _drag = Offset.zero;
  Axis? _axis;
  var _started = false;
  var _leaving = false;
  Timer? _hold;
  var _depth = campusOverlayDepth.value;

  @override
  void initState() {
    super.initState();
    _toastState = this;
    _settle.addListener(() => setState(() => _drag = _settleOffset!.value));
    campusOverlayDepth.addListener(_covered);
  }

  // 上面又盖了弹窗、弹层或菜单（层数变多）就收起：提示属于弹出它的那一层（同 Android 弹窗盖住 Snackbar），
  // 不留在新弹层上挡住它底部的按钮。在弹层里弹出的提示，弹层关上时照旧留着。
  void _covered() {
    final depth = campusOverlayDepth.value;
    if (depth > _depth) _hide();
    _depth = depth;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = 1;
    } else {
      _reveal.forward();
    }
    _holdOn();
  }

  // 开始倒计时到点收起；读屏开着时带操作的不自动收起。手指松开时也从头计（同 Material 的 Snackbar）。
  void _holdOn() {
    _hold?.cancel();
    if (_leaving) return;
    if (widget.action != null && MediaQuery.accessibleNavigationOf(context)) return;
    _hold = Timer(widget.duration, _hide);
  }

  // 收起：到时、点一下与 hideCampusToast 共用。
  void _hide() => _leave(Offset.zero);

  // 退场：朝 away 移开（划走时是划出去的方向）的同时隐去，走完拿掉；减少动画时直接拿掉。
  void _leave(Offset away) {
    if (_leaving) return;
    _leaving = true;
    _hold?.cancel();
    if (MediaQuery.disableAnimationsOf(context)) return widget.onDone();
    if (away != Offset.zero) _slide(away);
    _reveal.reverse().then((_) {
      if (mounted) widget.onDone();
    });
  }

  void _slide(Offset to) {
    _settleOffset = Tween(begin: _drag, end: to).animate(CurvedAnimation(parent: _settle, curve: Curves.easeOutCubic));
    _settle.forward(from: 0);
  }

  void _dragUpdate(DragUpdateDetails details) {
    if (_leaving) return;
    _settle.stop();
    final next = _drag + details.delta;
    _axis ??= next.dx.abs() > next.dy.abs() ? Axis.horizontal : Axis.vertical;
    setState(() => _drag = _axis == Axis.horizontal ? Offset(next.dx, 0) : Offset(0, next.dy));
  }

  // 横划过三分之一宽或甩得够快就划出屏幕，下拉过 24 或往下甩就沉下去，不然弹回原位。
  void _dragEnd(DragEndDetails details) {
    if (_leaving) return;
    final velocity = details.velocity.pixelsPerSecond;
    final width = context.size!.width;
    final flung = velocity.dx.abs() > 700 && velocity.dx.sign == _drag.dx.sign;
    if (_axis == Axis.horizontal && (_drag.dx.abs() > width / 3 || flung)) return _leave(Offset(_drag.dx.sign * width, 0));
    if (_axis == Axis.vertical && (_drag.dy > 24 || velocity.dy > 700)) return _leave(Offset(0, _drag.dy + 48));
    if (MediaQuery.disableAnimationsOf(context)) return setState(() => _drag = Offset.zero);
    _slide(Offset.zero);
  }

  @override
  void dispose() {
    if (_toastState == this) _toastState = null;
    campusOverlayDepth.removeListener(_covered);
    _hold?.cancel();
    _reveal.dispose();
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capsule = _toastCapsule(CampusPalette.of(context), widget.message, action: widget.action, onAction: widget.onAction);
    return Positioned(
      left: 0,
      right: 0,
      bottom: _toastBottom(context),
      child: Semantics(
        container: true,
        liveRegion: true,
        onDismiss: widget.onDone,
        child: AnimatedBuilder(
          animation: _reveal,
          builder: (context, child) => Transform.translate(
            offset: Offset(_drag.dx, (_drag.dy < 0 ? _drag.dy / 4 : _drag.dy) + _toastRise * (1 - Curves.easeOutCubic.transform(_reveal.value))),
            child: child,
          ),
          // 只有胶囊接住触摸，四周的留白照旧点穿；读屏用关闭操作收起，不把拖动报成可滚动。
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Listener(
              onPointerDown: (_) => _hold?.cancel(),
              onPointerUp: (_) => _holdOn(),
              onPointerCancel: (_) => _holdOn(),
              // 位移从按下处算起（不扣掉越过拖动阈值的那段）：快甩只有一两个移动事件时，扣掉就没有位移可判、划不走。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                dragStartBehavior: DragStartBehavior.down,
                onTap: _hide,
                onPanStart: (_) => _axis = null,
                onPanUpdate: _dragUpdate,
                onPanEnd: _dragEnd,
                child: CampusOverlayReveal(animation: _reveal, child: capsule),
              ),
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
