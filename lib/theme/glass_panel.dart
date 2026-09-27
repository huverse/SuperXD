import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';

final campusGlassReady = ValueNotifier(false);

Future<void> initializeCampusGlass() async {
  try {
    await liquid.LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    campusGlassReady.value = true;
    debugPrint(
      '[CampusGlass] ready=true shaderFilter=${ui.ImageFilter.isShaderFilterSupported}',
    );
  } catch (error, stack) {
    debugPrint('[CampusGlass] fallback=frosted error=$error\n$stack');
  }
}

enum GlassEdge { top, bottom }

class GlassPanelScope extends InheritedWidget {
  const GlassPanelScope({super.key, required this.opaque, required super.child});
  final bool opaque;
  static GlassPanelScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlassPanelScope>();
  @override
  bool updateShouldNotify(GlassPanelScope oldWidget) => opaque != oldWidget.opaque;
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.edge,
    required this.child,
    this.solid = false,
    this.floating = false,
  });
  final GlassEdge edge;
  final Widget child;
  final bool solid;
  final bool floating;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final opaque =
        solid ||
        media.highContrast ||
        media.accessibleNavigation ||
        media.disableAnimations;
    final radius = floating ? 32.0 : 0.0;
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final content = Stack(
          children: [
            Positioned.fill(child: FrostTexture(radius: radius)),
            GlassPanelScope(opaque: opaque || !ready, child: child),
          ],
        );
        if (opaque) {
          return DecoratedBox(
            decoration: BoxDecoration(
              color: CampusPalette.of(context).glassFallback,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: content,
          );
        }
        if (!ready) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: ColoredBox(
                color: CampusPalette.of(context).glassTint.withValues(alpha: .86),
                child: content,
              ),
            ),
          );
        }
        return liquid.AdaptiveGlass(
          shape: liquid.LiquidRoundedSuperellipse(borderRadius: radius),
          quality: floating
              ? liquid.GlassQuality.premium
              : liquid.GlassQuality.standard,
          allowElevation: false,
          settings: liquid.LiquidGlassSettings(
            glassColor: CampusPalette.of(context).glassTint.withValues(alpha: .62),
            thickness: floating ? 16 : 8,
            blur: 8,
            saturation: .9,
            refractiveIndex: 1.10,
            lightIntensity: .25,
            ambientStrength: .12,
            chromaticAberration: 0,
            glowIntensity: 0,
            shadowElevation: floating ? 1 : 0,
            platformViewFallbackColor: CampusPalette.of(context).glassFallback,
          ),
          child: content,
        );
      },
    );
  }
}
