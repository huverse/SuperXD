import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'package:superxd/theme/campus_palette.dart';

// 侧栏 CampusSideDrawer（同 Claude、ChatGPT 的侧栏）：点按钮或在页面上从左往右滑拉出，手指拖多少走多少，松手按速度与位置决定开合，
// 弹簧接着手指的速度收尾（临界阻尼、不回弹，同页面转场）。拉出时整个页面（含底栏）往右推，侧栏从左边露出：
// 页面透明、共用一份背景，两层不能叠着画，所以侧栏只画在页面左边让出来的那一段里（裁剪），并带一点视差。
// 页面压暗留在右边一条，点它、往左滑或按返回关上。展开成整屏（expand）给侧栏里的搜索用，返回先收回整屏。
// 被推入的页面完全盖住时，dismissWhenCovered 之后的那次悄悄合上，返回时回到原页面。减少动画时直接到位，拖动照样跟手。
class CampusSideDrawer extends StatefulWidget {
  const CampusSideDrawer({super.key, required this.drawer, required this.child, this.enabled = true});
  final Widget drawer;
  final Widget child;
  // 这一页能不能拉出侧栏（关着时滑动不响应，开着的照样能关）。
  final bool enabled;

  static CampusSideDrawerState? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_DrawerScope>()?.state;

  @override
  State<CampusSideDrawer> createState() => CampusSideDrawerState();
}

// 侧栏平时的宽度：屏宽的 82%，最宽 360（同 Claude 约八成）。
double campusDrawerWidth(double screen) => math.min(screen * .82, 360.0);

// 开合的弹簧：临界阻尼，约 0.3 秒到位，接得住松手时的速度。
final _spring = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 1);
// 收尾的容差：差侧栏宽的千分之五（不到 2 个像素）、速度很小就算到了，不拖着看不出的长尾。
const _tolerance = Tolerance(distance: .005, velocity: .05);
// 松手时超过这个速度（每秒几个侧栏宽）按方向开合，否则看过没过一半。
const _flingVelocity = 1.2;
// 侧栏露出时的视差：从左边缩进去的这一段跟着拉出来。
const _parallax = .14;

class CampusSideDrawerState extends State<CampusSideDrawer> with TickerProviderStateMixin {
  late final _open = AnimationController(vsync: this);
  late final _expand = AnimationController(vsync: this);
  // 页面此刻往右推了多少（逻辑像素），给挂在页面外面、要跟着走的东西（iOS 的系统底栏）。
  final shift = ValueNotifier<double>(0);
  // 是否展开成整屏（侧栏里的搜索）。
  final expanded = ValueNotifier<bool>(false);
  // 侧栏有没有露出来（开着、拖着或在收尾）：返回键据此先关侧栏。
  final _engaged = ValueNotifier<bool>(false);
  double _base = 0;
  double _full = 0;
  bool _dismissOnCover = false;
  Animation<double>? _covering;

  Animation<double> get progress => _open;
  Animation<double> get expansion => _expand;
  bool get isOpen => _open.value > 0 || _open.isAnimating;

  @override
  void initState() {
    super.initState();
    _open.addListener(_shift);
    _expand.addListener(_shift);
    _open.addStatusListener((status) => _engaged.value = !status.isDismissed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final covering = ModalRoute.of(context)?.secondaryAnimation;
    if (covering == _covering) return;
    _covering?.removeStatusListener(_covered);
    _covering = covering?..addStatusListener(_covered);
  }

  @override
  void didUpdateWidget(CampusSideDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled && isOpen) close();
  }

  @override
  void dispose() {
    _covering?.removeStatusListener(_covered);
    _open.dispose();
    _expand.dispose();
    shift.dispose();
    expanded.dispose();
    _engaged.dispose();
    super.dispose();
  }

  void _shift() => shift.value = _open.value * (lerpDouble(_base, _full, _expand.value) ?? 0);

  void _covered(AnimationStatus status) {
    if (status != AnimationStatus.completed || !_dismissOnCover) return;
    _dismissOnCover = false;
    _open.value = 0;
    _expand.value = 0;
    expanded.value = false;
  }

  bool get _instant => MediaQuery.disableAnimationsOf(context);

  void _settle(AnimationController controller, double target, [double velocity = 0]) {
    if (_instant) {
      controller.value = target;
      return;
    }
    // 弹簧按容差收尾，停下时离目标还差一点点（0.0003 这种）：正常走完就吸到目标，不然「合上」判不成、透明的压暗层一直挡着页面。
    // 中途被手指打断不吸（TickerFuture 被取消时不会完成）。
    controller.animateWith(SpringSimulation(_spring, controller.value, target, velocity, tolerance: _tolerance)).then((_) => controller.value = target);
  }

  void open() => _settle(_open, 1);

  void close() {
    _settle(_open, 0);
    if (expanded.value) expand(false);
  }

  // 展开成整屏或收回。
  void expand(bool value) {
    expanded.value = value;
    _settle(_expand, value ? 1 : 0);
  }

  // 接下来推入的页面完全盖住时合上侧栏（从侧栏打开一个页面，返回时回到原页面）。
  void dismissWhenCovered() => _dismissOnCover = true;

  void _dragStart(DragStartDetails details) => _open.stop();

  void _dragUpdate(DragUpdateDetails details) {
    final width = lerpDouble(_base, _full, _expand.value)!;
    if (width > 0) _open.value = (_open.value + details.primaryDelta! / width).clamp(0.0, 1.0);
  }

  void _dragEnd(DragEndDetails details) {
    final width = lerpDouble(_base, _full, _expand.value)!;
    final velocity = width > 0 ? (details.primaryVelocity ?? 0) / width : 0.0;
    final target = velocity.abs() > _flingVelocity ? (velocity > 0 ? 1.0 : 0.0) : (_open.value >= .5 ? 1.0 : 0.0);
    _settle(_open, target, velocity);
    if (target == 0 && expanded.value) expand(false);
  }

  void _dragCancel() => _settle(_open, _open.value >= .5 ? 1 : 0);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    _full = constraints.maxWidth;
    _base = campusDrawerWidth(_full);
    final dark = CampusPalette.of(context).isDark;
    return _DrawerScope(
      state: this,
      enabled: widget.enabled,
      child: ListenableBuilder(
        listenable: Listenable.merge([_engaged, expanded]),
        // 开着时按返回：先收回整屏，再关上侧栏。
        builder: (context, child) => PopScope(
          canPop: !_engaged.value,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            expanded.value ? expand(false) : close();
          },
          child: child!,
        ),
        child: AnimatedBuilder(
          animation: Listenable.merge([_open, _expand]),
          builder: (context, _) {
            final width = lerpDouble(_base, _full, _expand.value)!;
            final shown = _open.value * width;
            final closed = _open.value == 0 && !_open.isAnimating;
            // 快合上时（收尾的最后一点）压暗层就不再接点按：刚滑着合上、马上点左上角的按钮要能点到，不被几乎透明的压暗层吞掉。
            final dimming = _open.value > .02;
            final drawerLeft = -(1 - _open.value) * width * _parallax;
            return RawGestureDetector(
              gestures: {
                // 展开成整屏（搜索）时不跟手，免得和输入框的拖动抢；关着且这一页不让拉出时不响应。
                if ((widget.enabled || !closed) && !expanded.value)
                  HorizontalDragGestureRecognizer: GestureRecognizerFactoryWithHandlers<HorizontalDragGestureRecognizer>(
                    () => HorizontalDragGestureRecognizer(debugOwner: this),
                    (recognizer) => recognizer
                      ..dragStartBehavior = DragStartBehavior.down
                      ..onStart = _dragStart
                      ..onUpdate = _dragUpdate
                      ..onEnd = _dragEnd
                      ..onCancel = _dragCancel,
                  ),
              },
              child: Stack(children: [
                Positioned.fill(child: Transform.translate(
                  offset: Offset(shown, 0),
                  child: ExcludeSemantics(excluding: !closed, child: widget.child),
                )),
                if (!closed)
                  Positioned(left: shown, top: 0, bottom: 0, width: _full, child: IgnorePointer(ignoring: !dimming, child: Semantics(
                    button: true,
                    label: '关闭侧栏',
                    onTap: close,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: close,
                      child: ColoredBox(color: Colors.black.withValues(alpha: (dark ? .42 : .16) * _open.value)),
                    ),
                  ))),
                Positioned.fill(child: Offstage(
                  offstage: closed,
                  child: TickerMode(
                    enabled: !closed,
                    child: ClipRect(clipper: _LeftClip(shown), child: Stack(children: [
                      Positioned(left: drawerLeft, top: 0, bottom: 0, width: width, child: Semantics(
                        scopesRoute: true,
                        namesRoute: true,
                        explicitChildNodes: true,
                        label: '侧栏',
                        child: widget.drawer,
                      )),
                    ])),
                  ),
                )),
              ]),
            );
          },
        ),
      ),
    );
  });
}

class _DrawerScope extends InheritedWidget {
  const _DrawerScope({required this.state, required this.enabled, required super.child});
  final CampusSideDrawerState state;
  final bool enabled;

  @override
  bool updateShouldNotify(_DrawerScope oldWidget) => state != oldWidget.state || enabled != oldWidget.enabled;
}

class _LeftClip extends CustomClipper<Rect> {
  const _LeftClip(this.width);
  final double width;

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, width, size.height);

  @override
  bool shouldReclip(_LeftClip oldClipper) => oldClipper.width != width;
}
