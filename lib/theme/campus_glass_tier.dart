import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/native_glass.dart';

enum CampusGlassMode { auto, full, reduced }

// full 满档折射与色散；standard 轻量着色器；minimal 磨砂，不跑自定义着色器；solid 实色。
enum CampusGlassTier { full, standard, minimal, solid }

// [人工决策-2026-10-02 16:27:06] 玻璃效果默认自动：按实测光栅帧耗时在满档、标准、磨砂之间升降（GlassAdaptiveScope）；用户可在我的—界面固定完整或简化。高对比度、无障碍导航、减少动画一律实色。上次以满档运行后进程崩溃、原生崩溃或 ANR，本版本内上限降为标准档，升级后重试。
// [人工决策-2026-10-14 13:34:56] 限档分不清崩溃是不是玻璃引起的（曾因地图闪退把「完整」限成标准档）：限档仍对自动与完整都生效（防启动即崩的死循环），
// 但用户在外观页点「完整」即解除本版本限档、当作重试，再异常退出照样限档；限档期间外观页说明一行（同 Chrome GPU 黑名单可手动覆盖）。
// 上两条只管安卓：iOS 用系统玻璃、跟随系统设置，没有档位与限档（[人工决策] 见 native_glass.dart）。
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

  // GlassAdaptiveScope 常挂、只在自动模式下被采用：按模式增减这一层会改变树结构，切换玻璃效果时整个应用
  // （背景相位、入场遮罩、路由页面的状态）都被重建；固定档位下它只多一个帧耗时回调。
  // iOS 用系统玻璃（见 native_glass.dart），不按帧耗时升降档。
  static Widget wrap({
    required CampusGlassMode mode,
    required bool capped,
    required Widget child,
  }) => campusNativeGlass ? CampusGlassScope(mode: mode, capped: capped, child: child) : liquid.GlassAdaptiveScope(
    onQualityChanged: (from, to) => campusLog(
      '[CampusGlass] action=quality from=${from.name} to=${to.name} mode=${mode.name}',
    ),
    child: CampusGlassScope(mode: mode, capped: capped, child: child),
  );

  static CampusGlassTier tierOf(BuildContext context, {required bool ready}) {
    // iOS 的玻璃跟随系统设置（清透或着色、降低透明度、增强对比度由系统处理），没有档位。
    if (campusNativeGlass) return CampusGlassTier.full;
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

// 本版本是否限档：启动时由 CampusGlassGuard.load 读出，外观页点「完整」重试时清掉。
final campusGlassCapped = ValueNotifier(false);

// 原生侧记录“本进程用过满档”，下次启动结合 ApplicationExitInfo 判断是否限档，见 GlassGuard.kt。
class CampusGlassGuard {
  static const _channel = MethodChannel('superxd/glass');
  static bool _marked = false;

  static Future<void> load() async {
    try {
      final capped = await _channel.invokeMethod<bool>('guard') == true;
      if (capped) campusLog('[CampusGlass] action=guard capped=true');
      campusGlassCapped.value = capped;
    } catch (error, stack) {
      campusLog(
        '[CampusGlass] action=guard errorType=${error.runtimeType}\n$stack',
      );
    }
  }

  // 用户要求重试满档：解除本版本限档，失败时保持限档。
  static Future<void> retry() async {
    try {
      await _channel.invokeMethod<void>('retry');
      campusLog('[CampusGlass] action=retry');
      campusGlassCapped.value = false;
    } catch (error, stack) {
      campusLog(
        '[CampusGlass] action=retry errorType=${error.runtimeType}\n$stack',
      );
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
