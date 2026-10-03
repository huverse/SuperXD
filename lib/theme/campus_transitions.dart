import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_surface.dart';
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

// glassPanel 为真表示内容是 CampusGlassDialog 这类 overlay 玻璃面板，由面板按路由进度自己显隐；
// 日期选择器等系统弹窗传 false，仍整体改不透明度。
class CampusDialogRoute<T> extends DialogRoute<T> {
  CampusDialogRoute({required super.context, required super.builder, super.barrierDismissible = true, this.glassPanel = true})
      : super(themes: InheritedTheme.capture(from: context, to: Navigator.of(context, rootNavigator: true).context),
          animationStyle: MediaQuery.disableAnimationsOf(context) ? AnimationStyle.noAnimation : campusOverlay);
  final bool glassPanel;
  late final Animation<double> _reveal = animation!.drive(CurveTween(curve: Curves.easeInOutCubic));
  @override
  Curve get barrierCurve => Curves.easeInOutCubic;
  @override
  void install() {
    super.install();
    shiftCampusOverlayDepth(1);
  }

  @override
  void dispose() {
    shiftCampusOverlayDepth(-1);
    super.dispose();
  }
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
                if (actions.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: OverflowBar(
                      alignment: MainAxisAlignment.end,
                      overflowAlignment: OverflowBarAlignment.end,
                      spacing: 8,
                      overflowSpacing: 8,
                      children: actions,
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
class CampusSheetRoute<T> extends ModalBottomSheetRoute<T> {
  CampusSheetRoute({
    required super.builder,
    required super.capturedThemes,
    required super.barrierLabel,
    required super.barrierOnTapHint,
    required super.sheetAnimationStyle,
  }) : super(isScrollControlled: true, useSafeArea: true, backgroundColor: Colors.transparent, elevation: 0);

  @override
  void install() {
    super.install();
    shiftCampusOverlayDepth(1);
  }

  @override
  void dispose() {
    shiftCampusOverlayDepth(-1);
    super.dispose();
  }
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

// 弹层面板：与 iOS 26 一致，四周留 8 悬浮、圆角 24 的 overlay 玻璃，底部让出系统手势条。
class CampusSheetPanel extends StatelessWidget {
  const CampusSheetPanel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + MediaQuery.paddingOf(context).bottom),
    child: CampusOverlayGlass(radius: 24, child: child),
  );
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
Future<bool> showCampusConfirm(BuildContext context, {required String title, required String message, required String action, String cancel = '取消', bool barrierDismissible = true}) async => await showCampusDialog<bool>(
  context: context,
  barrierDismissible: barrierDismissible,
  builder: (context) => CampusGlassDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(message)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
    ],
  ),
) == true;
