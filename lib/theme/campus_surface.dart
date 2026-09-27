import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';

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
    final opaque =
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final content = Stack(
      children: [
        Positioned.fill(child: FrostTexture(radius: radius)),
        Padding(padding: padding, child: child),
      ],
    );
    return Padding(
      padding: margin,
      child: Material(
        color: (selected ? CampusPalette.of(context).surfaceSelected : CampusPalette.of(context).surface)
            .withValues(alpha: opaque ? 1 : .91),
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            color: selected
                ? CampusPalette.of(context).primary.withValues(alpha: .5)
                : Colors.white.withValues(alpha: .72),
          ),
        ),
        child: onTap == null
            ? content
            : InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(radius),
                child: content,
              ),
      ),
    );
  }
}
