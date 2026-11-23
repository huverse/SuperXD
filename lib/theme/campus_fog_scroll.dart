import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/glass_panel.dart';

// 浮在云雾上的顶部（同 Claude 侧栏顶上的标题）：内容滚到顶部下面时越往上越淡、融进背景的柔雾，标题与按钮浮在最上面。
// 完整玻璃档另叠渐进模糊（越往上越糊，六段共用一次背景采样 BackdropGroup）；简化、关闭档与减少动画时只淡出。
// 只在内容真的滚到顶部下面时才模糊，没滚动时不花这份开销。滚动区自己在顶部留出状态栏加 headerHeight；
// 滚动区里不能放玻璃（整块包了渐隐遮罩，玻璃在遮罩下取不到背景）。
class CampusFogScroll extends StatefulWidget {
  const CampusFogScroll({super.key, required this.header, required this.headerHeight, required this.child, this.blur = true});
  // 浮在顶上的一行（不含状态栏，组件自己让出）。
  final Widget header;
  final double headerHeight;
  final Widget child;
  // 为假时只淡出不模糊（调用方整块在做半透明过渡时：模糊在半透明图层里取不到下面的内容）。
  final bool blur;

  @override
  State<CampusFogScroll> createState() => _CampusFogScrollState();
}

// 雾带各段的模糊半径，从上往下（段高按雾带高度的比例 _bands）：半径一段段往下减到几乎为零，相邻两段差得小，下沿看不出接缝（模拟器上三段 14、7、3 时下沿一道硬边）。
const _sigmas = [12.0, 8.0, 5.0, 3.0, 1.5, .6];
const _bands = [.36, .2, .15, .12, .1, .07];

class _CampusFogScrollState extends State<CampusFogScroll> {
  bool _covered = false;

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    final covered = notification.metrics.pixels > .5;
    if (covered != _covered) setState(() => _covered = covered);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final band = padding.top + widget.headerHeight;
    return Stack(children: [
      Positioned.fill(child: NotificationListener<ScrollNotification>(
        onNotification: _scrolled,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) {
            final height = rect.height <= 0 ? 1.0 : rect.height;
            // 顶上：状态栏处全透，到标题一半处还剩三成（像 Claude 标题后面隐约的字），出了雾带才完全不透明。
            // 区域很矮时各点可能倒序，按从上往下不回退取。
            var last = 0.0;
            double at(double y) => last = (y / height).clamp(last, 1.0);
            return LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: [at(padding.top * .5), at(padding.top + widget.headerHeight * .5), at(band + 16)],
              colors: [Colors.transparent, Colors.black.withValues(alpha: .3), Colors.black],
            ).createShader(rect);
          },
          child: widget.child,
        ),
      )),
      if (_covered && widget.blur) Positioned(left: 0, top: 0, right: 0, height: band + 16, child: _FogBlur(height: band + 16)),
      Positioned(left: 0, top: padding.top, right: 0, height: widget.headerHeight, child: widget.header),
    ]);
  }
}

class _FogBlur extends StatelessWidget {
  const _FogBlur({required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: campusGlassReady,
    builder: (context, ready, _) {
      if (CampusGlassScope.tierOf(context, ready: ready) != CampusGlassTier.full) return const SizedBox.shrink();
      return IgnorePointer(child: BackdropGroup(child: Column(children: [
        for (final (index, sigma) in _sigmas.indexed)
          SizedBox(height: height * _bands[index], child: ClipRect(child: BackdropFilter.grouped(
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror),
            child: const SizedBox.expand(),
          ))),
      ])));
    },
  );
}
