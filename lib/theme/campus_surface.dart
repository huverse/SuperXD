import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';

// 卡片底色：配色的 surface（选中时 surfaceSelected），平时 91% 不透明、透出一点背景，高对比度或读屏导航时完全不透明；
// solid 另要求不透明（如输入框聚焦时微亮）。卡片、搜索框与快递登录的胶囊框共用这一条（以前三处各写一遍）。
Color campusSurfaceFill(BuildContext context, {bool selected = false, bool solid = false}) {
  final palette = CampusPalette.of(context);
  final opaque = solid || MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
  return (selected ? palette.surfaceSelected : palette.surface).withValues(alpha: opaque ? 1 : .91);
}

class CampusSurface extends StatelessWidget {
  const CampusSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.selected = false,
    this.onTap,
    this.margin = EdgeInsets.zero,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool selected;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;
  @override
  Widget build(BuildContext context) {
    final content = Stack(
      children: [
        Positioned.fill(child: FrostTexture(radius: radius)),
        Padding(padding: padding, child: child),
      ],
    );
    return Padding(
      padding: margin,
      child: Material(
        color: campusSurfaceFill(context, selected: selected),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: selected
                ? CampusPalette.of(context).primary.withValues(alpha: .5)
                : CampusPalette.of(context).surfaceBorder,
          ),
        ),
        // 可点的卡片读屏报“按钮”（同系统列表项），不只是一段能双击的文字。
        child: onTap == null
            ? content
            : Semantics(
                button: true,
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(radius),
                  child: content,
                ),
              ),
      ),
    );
  }
}
