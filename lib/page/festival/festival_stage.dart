import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/festival.dart';
import 'reward_kit.dart';

// 一次节日的定制动画（人工决策见 domain/festival.dart）：每一次各写一个场景，登记在 festival_catalog.dart。
// builder 拿到 0→1 的进度（走完 length），自己决定每个时刻画什么；场景铺满全屏、背景透明，下面是用户正在看的页面。
// still 是减少动画时的静态画面，为空时用通用的问候（节日名字居中）。
// reward 是这一次节日抽中红包时奖品卡的主题（配色与卡面），为空时用默认的流光卡。
// 节日浮层（动画与拆红包）压暗了下面的页面，系统栏用浅色图标；导航栏透明（SystemUiOverlayStyle.light 会把它涂成不透明黑色，Android 11–14 底部一条黑条）。
const festivalSystemOverlay = SystemUiOverlayStyle(
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

class FestivalScene {
  const FestivalScene({required this.occasion, required this.length, required this.builder, this.still, this.reward});
  final FestivalOccasion occasion;
  final Duration length;
  final Widget Function(BuildContext context, Animation<double> progress) builder;
  final WidgetBuilder? still;
  final RewardTheme? reward;
}

// 减少动画时静态画面停留多久（点一下随时关）。
const festivalStillLength = Duration(milliseconds: 2400);

// 播一段节日动画：浮层路由推在根导航器上（不是页面路由，下面的页面不跟着做转场；不登记弹窗层数，顶栏底栏照常是玻璃），
// 放完自己淡出；点任意处或返回立即淡出。
Future<void> showFestivalCelebration(BuildContext context, FestivalScene scene) => Navigator.of(context, rootNavigator: true).push(_StageRoute(scene));

class _StageRoute extends PopupRoute<void> {
  _StageRoute(this.scene);
  final FestivalScene scene;

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => false;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => const Duration(milliseconds: 280);
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 360);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) => _Stage(scene: scene);

  // 场景自己不是玻璃，整层淡入淡出没有玻璃取不到背景的问题。
  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation, Widget child) =>
      FadeTransition(opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut, reverseCurve: Curves.easeIn), child: child);
}

class _Stage extends StatefulWidget {
  const _Stage({required this.scene});
  final FestivalScene scene;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> with SingleTickerProviderStateMixin {
  late final _progress = AnimationController(vsync: this, duration: widget.scene.length);
  Timer? _still;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.disableAnimationsOf(context)) {
        _still = Timer(festivalStillLength, _close);
      } else {
        _progress.forward().whenCompleteOrCancel(_close);
      }
    });
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _still?.cancel();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scene = widget.scene;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: festivalSystemOverlay,
      child: Semantics(
        liveRegion: true,
        label: scene.occasion.name,
        hint: '点一下关闭',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _close,
          // 浮层路由不在任何 Material 之下：垫一层透明的，场景里的文字照常取应用字体与样式（不然是带黄色双下划线的调试样式）。
          child: Material(type: MaterialType.transparency, child: reduced ? (scene.still ?? _greeting)(context) : scene.builder(context, _progress)),
        ),
      ),
    );
  }

  // 通用问候：压暗的底上写节日名字，深浅色模式都是白字（同相机取景页，衬底固定是暗的）。
  Widget _greeting(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: .78),
    child: Center(child: Text(widget.scene.occasion.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w600, color: Colors.white))),
  );
}
