import 'package:flutter/material.dart';

// 内容层在浮动玻璃栏下的柔和滚动边缘：只渐隐内容本身，露出真实动态背景，不叠纯色遮罩。
// 遮罩把子树放进离屏层，子树内不能再有玻璃，否则玻璃取不到外层背景；高对比度时不渐隐。
class ScrollEdgeFade extends StatelessWidget {
  const ScrollEdgeFade({super.key, this.top = 0, required this.bottom, required this.child});
  // 内容已滚过上缘时的淡出高度，0表示未滚动不淡出；调用方须保证遮罩层有无不随滚动切换。
  final double top;
  // 子树底部被玻璃栏覆盖的高度，0表示没有浮动栏。
  final double bottom;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if ((top <= 0 && bottom <= 0) || MediaQuery.highContrastOf(context)) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final height = bounds.height;
        const solid = Colors.white;
        final colors = <Color>[];
        final stops = <double>[];
        final entered = (top / height).clamp(0.0, 1.0);
        if (top > 0) {
          colors.addAll([solid.withValues(alpha: 0), solid]);
          stops.addAll([0, entered]);
        } else {
          colors.add(solid);
          stops.add(0);
        }
        if (bottom > 0) {
          // 进入玻璃前开始淡出，玻璃上部仍透出内容，下缘前完全透明，避免残字和列表裁切线。
          final start = ((height - bottom - 16) / height).clamp(entered, 1.0);
          final under = ((height - bottom * .6) / height).clamp(start, 1.0);
          final clear = ((height - bottom * .2) / height).clamp(under, 1.0);
          colors.addAll([solid, solid.withValues(alpha: .55), solid.withValues(alpha: 0), solid.withValues(alpha: 0)]);
          stops.addAll([start, under, clear, 1]);
        } else {
          colors.add(solid);
          stops.add(1);
        }
        return LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors, stops: stops).createShader(bounds);
      },
      // 完全透明段直接不画：遮罩边缘落在非整数像素时最后一行会漏出内容细线。
      child: ClipRect(clipper: _VisibleClip(bottom * .2), child: child),
    );
  }
}

class _VisibleClip extends CustomClipper<Rect> {
  const _VisibleClip(this.hidden);
  final double hidden;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, size.width, size.height - hidden);
  @override
  bool shouldReclip(_VisibleClip oldClipper) => oldClipper.hidden != hidden;
}
