import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/domain/campus_log.dart';

final campusGlassReady = ValueNotifier(false);

Future<void> initializeCampusGlass() async {
  try {
    await liquid.LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    campusGlassReady.value = true;
    campusLog(
      '[CampusGlass] ready=true shaderFilter=${ui.ImageFilter.isShaderFilterSupported}',
    );
  } catch (error, stack) {
    campusLog('[CampusGlass] fallback=frosted error=$error\n$stack');
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
    final radius = floating ? 32.0 : 0.0;
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final tier = solid
            ? CampusGlassTier.solid
            : CampusGlassScope.tierOf(context, ready: ready);
        final opaque = tier == CampusGlassTier.solid;
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
        // 浮动栏下有内容穿过：减淡着色透出内容，加大模糊保标签可读，边缘高光与折射体现液态透镜。
        return liquid.AdaptiveGlass(
          shape: liquid.LiquidRoundedSuperellipse(borderRadius: radius),
          quality: campusGlassQuality(tier),
          allowElevation: false,
          settings: campusGlassSettings(
            CampusPalette.of(context),
            CampusGlassRole.navigation,
            tier,
            floating: floating,
          ),
          child: content,
        );
      },
    );
  }
}
