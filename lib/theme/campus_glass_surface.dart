import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

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
    final opaque =
        disabled ||
        MediaQuery.highContrastOf(context) ||
        MediaQuery.accessibleNavigationOf(context) ||
        MediaQuery.disableAnimationsOf(context);
    final nested = GlassPanelScope.maybeOf(context);
    final radius = round ? 1000.0 : 12.0;
    final tint = pressed ? palette.surfaceSelected : palette.glassTint;
    final settings = liquid.LiquidGlassSettings(
      glassColor: tint.withValues(alpha: .74),
      thickness: 8,
      blur: 6,
      saturation: .9,
      refractiveIndex: 1.10,
      lightIntensity: .35,
      ambientStrength: .16,
      chromaticAberration: 0,
      glowIntensity: 0,
      shadowElevation: 0,
      platformViewFallbackColor: palette.glassFallback,
    );
    final shape = round
        ? const liquid.LiquidRoundedSuperellipse(borderRadius: 1000)
        : const liquid.LiquidRoundedSuperellipse(borderRadius: 12);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      child: child,
      builder: (context, ready, content) {
        final surface = opaque || !ready || nested?.opaque == true
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: disabled
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
                quality: liquid.GlassQuality.standard,
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
