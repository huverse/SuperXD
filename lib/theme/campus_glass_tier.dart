import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/domain/campus_log.dart';

enum CampusGlassMode { auto, full, reduced }

// full 满档折射与色散；standard 轻量着色器；minimal 磨砂，不跑自定义着色器；solid 实色。
enum CampusGlassTier { full, standard, minimal, solid }

// [人工决策-2026-10-02 16:27:06] 玻璃效果默认自动：按实测光栅帧耗时在满档、标准、磨砂之间升降（GlassAdaptiveScope）；用户可在我的—界面固定完整或简化。高对比度、无障碍导航、减少动画一律实色。上次以满档运行后进程崩溃、原生崩溃或 ANR，本版本内上限降为标准档，升级后重试。
CampusGlassTier resolveCampusGlassTier({
  required CampusGlassMode mode,
  required liquid.GlassQuality? adaptive,
  required bool capped,
  required bool ready,
  required bool accessible,
}) {
  if (accessible) return CampusGlassTier.solid;
  if (!ready || mode == CampusGlassMode.reduced) return CampusGlassTier.minimal;
  final tier = mode == CampusGlassMode.full
      ? CampusGlassTier.full
      : switch (adaptive ?? liquid.GlassQuality.premium) {
          liquid.GlassQuality.premium => CampusGlassTier.full,
          liquid.GlassQuality.standard => CampusGlassTier.standard,
          liquid.GlassQuality.minimal => CampusGlassTier.minimal,
        };
  return capped && tier == CampusGlassTier.full
      ? CampusGlassTier.standard
      : tier;
}

class CampusGlassScope extends InheritedWidget {
  const CampusGlassScope({
    super.key,
    required this.mode,
    required this.capped,
    required super.child,
  });
  final CampusGlassMode mode;
  final bool capped;

  // 自动模式才挂 GlassAdaptiveScope 采样帧耗时；固定档位不额外监听。
  static Widget wrap({
    required CampusGlassMode mode,
    required bool capped,
    required Widget child,
  }) {
    final scope = CampusGlassScope(mode: mode, capped: capped, child: child);
    if (mode != CampusGlassMode.auto) return scope;
    return liquid.GlassAdaptiveScope(
      onQualityChanged: (from, to) => campusLog(
        '[CampusGlass] action=quality from=${from.name} to=${to.name}',
      ),
      child: scope,
    );
  }

  static CampusGlassTier tierOf(BuildContext context, {required bool ready}) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<CampusGlassScope>();
    final tier = resolveCampusGlassTier(
      mode: scope?.mode ?? CampusGlassMode.auto,
      adaptive: liquid.GlassAdaptiveScopeData.maybeOf(context)
          ?.effectiveQuality,
      capped: scope?.capped ?? false,
      ready: ready,
      accessible:
          MediaQuery.highContrastOf(context) ||
          MediaQuery.accessibleNavigationOf(context) ||
          MediaQuery.disableAnimationsOf(context),
    );
    if (tier == CampusGlassTier.full) CampusGlassGuard.markFull();
    return tier;
  }

  @override
  bool updateShouldNotify(CampusGlassScope oldWidget) =>
      mode != oldWidget.mode || capped != oldWidget.capped;
}

// 原生侧记录“本进程用过满档”，下次启动结合 ApplicationExitInfo 判断是否限档，见 MainActivity.kt。
class CampusGlassGuard {
  static const _channel = MethodChannel('superxd/glass');
  static bool _marked = false;

  static Future<bool> capped() async {
    try {
      final capped = await _channel.invokeMethod<bool>('guard') == true;
      if (capped) campusLog('[CampusGlass] action=guard capped=true');
      return capped;
    } catch (error, stack) {
      campusLog(
        '[CampusGlass] action=guard errorType=${error.runtimeType}\n$stack',
      );
      return false;
    }
  }

  static void markFull() {
    if (_marked) return;
    _marked = true;
    _channel.invokeMethod<void>('markFull').catchError((
      Object error,
      StackTrace stack,
    ) {
      campusLog(
        '[CampusGlass] action=mark errorType=${error.runtimeType}\n$stack',
      );
    });
  }
}
