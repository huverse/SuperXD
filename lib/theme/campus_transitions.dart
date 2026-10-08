import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

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
  return _CampusPageSlide(animation: animation, secondaryAnimation: secondaryAnimation, child: child);
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
class CampusPageRoute<T> extends MaterialPageRoute<T> {
  CampusPageRoute({required super.builder, super.settings});
  @override
  AnimationController createAnimationController() => _firstFrameController(this);
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

class _CampusPageBasedRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T> {
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
  AnimationController createAnimationController() => _firstFrameController(this);
}

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
  ) => _CampusBackGesture(route: route, child: campusPageTransition(context, animation, secondaryAnimation, child));
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
      final sigma = media.highContrast || media.accessibleNavigation ? 0.0 : 5 * progress;
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
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                    child: FilledButtonTheme(
                      data: FilledButtonThemeData(style: campusProminent.merge(Theme.of(context).filledButtonTheme.style)),
                      child: actions.length <= 2
                          ? Row(children: [
                              for (var index = 0; index < actions.length; index++) ...[
                                if (index > 0) const SizedBox(width: 12),
                                Expanded(child: actions[index]),
                              ],
                            ])
                          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              // 竖排时主操作在最上、取消在最下（同 iOS、鸿蒙），调用处仍按“取消在前”书写。
                              for (final (index, action) in actions.reversed.indexed) ...[
                                if (index > 0) const SizedBox(height: 8),
                                action,
                              ],
                            ]),
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
void showCampusToast(BuildContext context, String message, {String? action, VoidCallback? onAction}) {
  final messenger = ScaffoldMessenger.of(context);
  final palette = CampusPalette.of(context);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      behavior: SnackBarBehavior.fixed,
      hitTestBehavior: HitTestBehavior.deferToChild,
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      duration: Duration(seconds: action == null ? 4 : 6),
      content: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: CampusOverlayGlass(
          radius: 18,
          floating: true,
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, action == null ? 14 : 0, action == null ? 16 : 4, action == null ? 14 : 0),
            child: Row(children: [
              Expanded(child: Text(message, style: TextStyle(color: palette.onSurface, fontSize: 14))),
              if (action != null)
                TextButton(
                  onPressed: () {
                    messenger.hideCurrentSnackBar();
                    onAction!();
                  },
                  child: Text(action),
                ),
            ]),
          ),
        ),
      ),
    ));
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

Future<T?> showCampusSheet<T>({required BuildContext context, required WidgetBuilder builder}) {
  final navigator = Navigator.of(context);
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

// 只读提示：长文本可滚动，唯一按钮“知道了”。
Future<void> showCampusNotice(BuildContext context, String message, {String? title}) => showCampusDialog<void>(
  context: context,
  builder: (context) => CampusGlassDialog(
    title: title == null ? null : Text(title),
    content: SingleChildScrollView(child: Text(message)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
  ),
);

// 二次确认：仅点确认按钮返回true，取消、点遮罩或系统返回都视为不确认。
// destructive 为真时主按钮是警示红（删除、清空、退出、覆盖、放弃修改等不可撤销的操作）。
Future<bool> showCampusConfirm(BuildContext context, {required String title, required String message, required String action, String cancel = '取消', bool barrierDismissible = true, bool destructive = false}) async => await showCampusDialog<bool>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => CampusGlassDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(message)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancel)),
      FilledButton(style: destructive ? campusDestructive : null, onPressed: () => Navigator.pop(context, true), child: Text(action)),
    ],
  ),
) == true;
