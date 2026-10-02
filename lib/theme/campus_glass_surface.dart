import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

// 按钮和手势反馈共用材质；不提供点击行为或按钮语义。
class CampusGlassSurface extends StatelessWidget {
  const CampusGlassSurface({
    super.key,
    required this.child,
    this.round = false,
    this.disabled = false,
    this.pressed = false,
    this.focused = false,
    this.softOutline = false,
  });
  final Widget child;
  final bool round;
  final bool disabled;
  final bool pressed;
  final bool focused;
  final bool softOutline;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final nested = GlassPanelScope.maybeOf(context);
    final radius = round ? 1000.0 : 12.0;
    final shape = round
        ? const liquid.LiquidRoundedSuperellipse(borderRadius: 1000)
        : const liquid.LiquidRoundedSuperellipse(borderRadius: 12);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      child: child,
      builder: (context, ready, content) {
        final tier = disabled
            ? CampusGlassTier.solid
            : CampusGlassScope.tierOf(context, ready: ready);
        final settings = campusGlassSettings(
          palette,
          CampusGlassRole.control,
          tier,
          pressed: pressed,
        );
        final surface =
            tier == CampusGlassTier.solid || !ready || nested?.opaque == true
            // 实色档里选中、按下同样着 surfaceSelected，高对比度下选中态不只靠勾号区分。
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: disabled || pressed
                      ? palette.surfaceSelected
                      : palette.glassFallback,
                  borderRadius: BorderRadius.circular(radius),
                ),
                child: content,
              )
            : nested != null
            ? liquid.AdaptiveGlass.vibrancy(
                shape: shape,
                settings: settings,
                child: content!,
              )
            : liquid.AdaptiveGlass(
                shape: shape,
                settings: settings,
                quality: campusGlassQuality(tier),
                allowElevation: false,
                isInteractive: true,
                child: content!,
              );
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: focused
                  ? palette.primary
                  : disabled
                  ? palette.outlineSubtle
                  : palette.primary.withValues(alpha: softOutline ? .12 : .24),
              width: focused ? 2 : 1,
            ),
          ),
          child: surface,
        );
      },
    );
  }
}

// 浮层面板（弹窗、提示条）共用的 overlay 玻璃；实色档和未就绪时用 surface，与升级前的弹窗底色一致。
class CampusOverlayGlass extends StatelessWidget {
  const CampusOverlayGlass({
    super.key,
    required this.radius,
    required this.child,
    this.solid = false,
  });
  final double radius;
  final Widget child;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final tier = solid
            ? CampusGlassTier.solid
            : CampusGlassScope.tierOf(context, ready: ready);
        final opaque = tier == CampusGlassTier.solid || !ready;
        // 面板内的按钮、开关按父玻璃处理（只做 vibrancy 或随面板实色），不再叠一层玻璃；
        // 墨水画在最近的 Material 上，内容外包透明 Material，点按涟漪才不被面板背景盖住。
        final content = GlassPanelScope(
          opaque: opaque,
          child: Material(type: MaterialType.transparency, child: child),
        );
        if (opaque) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surface,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: content,
          );
        }
        return liquid.AdaptiveGlass(
          shape: liquid.LiquidRoundedSuperellipse(borderRadius: radius),
          quality: campusGlassQuality(tier),
          allowElevation: false,
          settings: campusGlassSettings(palette, CampusGlassRole.overlay, tier),
          child: content,
        );
      },
    );
  }
}
