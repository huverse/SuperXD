import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/glass_panel.dart';

// 浮在云雾上的顶部（同 Claude 侧栏顶上的标题）：内容滚到顶部下面时越往上越淡、融进背景的柔雾，标题与按钮浮在最上面。
// 完整玻璃档另叠渐进模糊：玻璃库的 ProgressiveBlur，一次背景采样、着色器按位置连续减小半径，越往上越糊、到下沿正好清晰
// （11-23 用户真机深色截图：原来分六段各自裁剪模糊，段界在滚上来的字上切出一道道硬边；段分得再细也只是硬边变细，所以换成连续的）。
// 简化、关闭档、减少动画与不支持着色器滤镜时只淡出（库在不支持时退回一整块均匀模糊，下沿又是一道硬边）。
// 只在内容滚到顶部下面时才模糊，滚开头一段里半径从零长到满（不一下子糊上），没滚动时不花这份开销；滚动只重建模糊这一层。
// 滚动区自己在顶部留出状态栏加 headerHeight；
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

// 雾带顶上的模糊半径（往下按位置线性减到下沿为零，同原来分段的走势）与滚多远模糊才长满。
const _fogSigma = 14.0;
const _fogRamp = 24.0;

class _CampusFogScrollState extends State<CampusFogScroll> {
  // 内容滚到顶部下面的程度：0 是没滚（或在顶上回弹），滚过 _fogRamp 为 1。
  final _cover = ValueNotifier<double>(0);

  bool _scrolled(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) return false;
    _cover.value = ((notification.metrics.pixels - notification.metrics.minScrollExtent) / _fogRamp).clamp(0.0, 1.0);
    return false;
  }

  @override
  void dispose() {
    _cover.dispose();
    super.dispose();
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
      if (widget.blur) Positioned(left: 0, top: 0, right: 0, height: band + 16, child: _FogBlur(cover: _cover)),
      Positioned(left: 0, top: padding.top, right: 0, height: widget.headerHeight, child: widget.header),
    ]);
  }
}

class _FogBlur extends StatelessWidget {
  const _FogBlur({required this.cover});
  final ValueNotifier<double> cover;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: campusGlassReady,
    builder: (context, ready, _) {
      // 着色器由组合根初始化玻璃时预热（LiquidGlassWidgets.initialize），完整档要等它就绪，所以第一次滚上来时已经编译好。
      if (CampusGlassScope.tierOf(context, ready: ready) != CampusGlassTier.full || !ui.ImageFilter.isShaderFilterSupported) return const SizedBox.shrink();
      return IgnorePointer(child: ValueListenableBuilder<double>(
        valueListenable: cover,
        builder: (context, cover, _) => cover <= 0 ? const SizedBox.shrink() : liquid.ProgressiveBlur(maxSigma: _fogSigma * cover, falloff: 1),
      ));
    },
  );
}
