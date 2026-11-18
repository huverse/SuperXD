import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';

// 卡片底色：配色的 surface（选中时 surfaceSelected），平时 91% 不透明、透出一点背景，高对比度或读屏导航时完全不透明；
// solid 另要求不透明（如输入框聚焦时微亮）。卡片、搜索框与快递登录的胶囊框共用这一条（以前三处各写一遍）。
Color campusSurfaceFill(BuildContext context, {bool selected = false, bool solid = false}) {
  final palette = CampusPalette.of(context);
  final opaque = solid || MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
  // 选中的卡片铺选中着色（见 CampusPalette.selectedFill）。
  return (selected ? Color.alphaBlend(palette.selectedFill, palette.surface) : palette.surface).withValues(alpha: opaque ? 1 : .91);
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
          // 选中：激活色实线描边（画在里沿，卡片尺寸不变）。
          side: selected
              ? BorderSide(color: CampusPalette.of(context).accentText, width: 2)
              : BorderSide(color: CampusPalette.of(context).surfaceBorder),
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

// 按需建的长列表做成一张卡片（11-18 性能审查 P2-4，好友列表）：底色与描边同 CampusSurface（campusSurfaceFill、surfaceBorder、圆角 radius），
// 画在整段 sliver 后面（DecoratedSliver 按整段的高画，圆角始终在真正的首尾）；上下留 inset。没有颗粒纹理（FrostTexture 要按整张卡的大小画，
// 按需建的列表没有这张整卡；颗粒只有 1.6% 的不透明度，看不出来）。里面每一行包 CampusCardRow。
class CampusSliverCard extends StatelessWidget {
  const CampusSliverCard({super.key, required this.sliver, this.radius = 24, this.inset = 8});
  final Widget sliver;
  final double radius;
  final double inset;

  @override
  Widget build(BuildContext context) => DecoratedSliver(
    decoration: ShapeDecoration(
      color: campusSurfaceFill(context),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: CampusPalette.of(context).surfaceBorder)),
    ),
    sliver: SliverPadding(padding: EdgeInsets.symmetric(vertical: inset), sliver: sliver),
  );
}

// CampusSliverCard 里的一行：自带一层透明 Material 接按下变暗（卡片背后没有 Material，不包的话按压反馈画在卡片底色下面看不见），
// 首尾两行按整张卡的圆角裁掉伸出卡外的那一角（同 CampusSurface 的 Material 裁剪）；中间的行不裁剪、不多一层。
class CampusCardRow extends StatelessWidget {
  const CampusCardRow({super.key, required this.first, required this.last, required this.child, this.radius = 24, this.inset = 8});
  final bool first;
  final bool last;
  final Widget child;
  final double radius;
  final double inset;

  @override
  Widget build(BuildContext context) => ClipPath(
    clipper: _CardSliceClipper(first: first, last: last, radius: radius, inset: inset),
    clipBehavior: first || last ? Clip.antiAlias : Clip.none,
    child: Material(type: MaterialType.transparency, child: child),
  );
}

class _CardSliceClipper extends CustomClipper<Path> {
  const _CardSliceClipper({required this.first, required this.last, required this.radius, required this.inset});
  final bool first;
  final bool last;
  final double radius;
  final double inset;

  // 整张卡在这一行的坐标里：首行往上多 inset 是卡顶，尾行往下多 inset 是卡底；不是首尾的那一边伸到圆角够不着的地方。
  @override
  Path getClip(Size size) => Path()..addRRect(RRect.fromLTRBR(0, first ? -inset : -2 * radius, size.width, last ? size.height + inset : size.height + 2 * radius, Radius.circular(radius)));

  @override
  bool shouldReclip(_CardSliceClipper oldClipper) => oldClipper.first != first || oldClipper.last != last || oldClipper.radius != radius || oldClipper.inset != inset;
}
