import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_background.dart';
import 'package:superxd/theme/campus_glass_blend.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/domain/campus_log.dart';

final campusGlassReady = ValueNotifier(false);

// 正在显示的弹窗层数；大于0时顶栏和底栏改实色，不让弹窗玻璃叠在栏玻璃上，也省下弹窗背后的玻璃渲染。
final campusOverlayDepth = ValueNotifier(0);

// 路由增删可能发生在构建期，此时延到帧末再通知，避免构建中触发重建；其余时刻立即生效。
void shiftCampusOverlayDepth(int delta) {
  final binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
    binding.addPostFrameCallback((_) => campusOverlayDepth.value += delta);
  } else {
    campusOverlayDepth.value += delta;
  }
}

// 浮层路由（弹窗、弹层、菜单）的层数登记：装入时加一；开始关闭（didPop）就减一，栏和遮罩一起恢复玻璃，
// 不等关闭动画结束、遮罩已消失才突然换回；没经过 pop 被直接移除时在 dispose 补减，只减一次。
mixin CampusOverlayDepthRoute<T> on Route<T> {
  bool _counted = false;

  @override
  void install() {
    super.install();
    _counted = true;
    shiftCampusOverlayDepth(1);
  }

  @override
  bool didPop(T? result) {
    _release();
    return super.didPop(result);
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  void _release() {
    if (!_counted) return;
    _counted = false;
    shiftCampusOverlayDepth(-1);
  }
}

Future<void> initializeCampusGlass() async {
  try {
    await liquid.LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
    campusGlassReady.value = true;
    campusLog(
      '[CampusGlass] ready=true shaderFilter=${ui.ImageFilter.isShaderFilterSupported}',
    );
  } catch (error, stack) {
    campusLog('[CampusGlass] fallback=frosted errorType=${error.runtimeType}\n$stack');
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
    final fallback = CampusPalette.of(context).glassFallback;
    return ListenableBuilder(
      listenable: Listenable.merge([campusGlassReady, campusOverlayDepth]),
      builder: (context, _) {
        final ready = campusGlassReady.value;
        // 弹窗打开时改实色、换档时都经盖板过渡；弹窗从开始关闭就恢复玻璃（见 campus_transitions.dart），和遮罩一起淡出。
        return CampusGlassBlend<(bool, CampusGlassTier)>(
          look: (
            ready,
            solid || campusOverlayDepth.value > 0 ? CampusGlassTier.solid : CampusGlassScope.tierOf(context, ready: ready),
          ),
          opaque: (look) => look.$2 == CampusGlassTier.solid,
          builder: (context, look, cover) => _surface(context, look.$1, look.$2, cover, fallback),
        );
      },
    );
  }

  Widget _surface(BuildContext context, bool ready, CampusGlassTier tier, double cover, Color fallback) {
    final radius = floating ? 32.0 : 0.0;
    final opaque = tier == CampusGlassTier.solid;
    final content = Stack(
      children: [
        if (!opaque && cover > 0)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: fallback.withValues(alpha: cover), borderRadius: BorderRadius.circular(radius)),
            ),
          ),
        Positioned.fill(child: FrostTexture(radius: radius)),
        GlassPanelScope(opaque: opaque || !ready, child: child),
      ],
    );
    if (opaque) {
      return DecoratedBox(
        decoration: BoxDecoration(color: fallback, borderRadius: BorderRadius.circular(radius)),
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
  }
}

// 导航层标记：顶栏、悬浮按钮这类浮在内容之上的控件层，其中的按钮画玻璃。
// 不在导航层、也不在玻璃面板或浮层（GlassPanelScope）里的按钮属于内容区，画色调胶囊，见 campus_glass_button.dart。
class CampusChrome extends InheritedWidget {
  const CampusChrome({super.key, required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<CampusChrome>() != null;

  @override
  bool updateShouldNotify(CampusChrome oldWidget) => false;
}

// [人工决策-2026-10-03 17:37:24] 顶栏保留整条，静止时透明、与主体同一背景，无底板和分割线；内容滚到栏下时由内容自身渐隐露出真实背景
// （鸿蒙 GRADIENT_BLUR、iOS 滚动边缘的轻量做法），不额外模糊背景；栏内按钮仍是玻璃胶囊。取代整宽玻璃顶栏（与主体割裂）。
class CampusTopBar extends StatelessWidget {
  const CampusTopBar({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CampusChrome(child: SafeArea(bottom: false, child: child));
}
