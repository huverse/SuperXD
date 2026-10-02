import 'package:flutter/painting.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_palette.dart';

// navigation 顶栏与底栏；control 按钮、开关、标签；overlay 菜单、弹层、弹窗、提示条。
// [人工决策-2026-10-02 16:27:06] 液态玻璃覆盖整个导航与控件层，弹窗也改为玻璃；课程卡、列表等内容保持高遮色磨砂实卡，不叠玻璃。
enum CampusGlassRole { navigation, control, overlay }

liquid.GlassQuality campusGlassQuality(CampusGlassTier tier) => switch (tier) {
  CampusGlassTier.full => liquid.GlassQuality.premium,
  CampusGlassTier.standard => liquid.GlassQuality.standard,
  CampusGlassTier.minimal ||
  CampusGlassTier.solid => liquid.GlassQuality.minimal,
};

// 满档以 iOS 27 常规材质为底（frost 雾化、rimShade 轮廓、rimLight 高光），再按当前配色着色；
// 色散只给控件与浮层，导航栏标签区不出色边。标准与磨砂档保持升级前参数，观感不变。
liquid.LiquidGlassSettings campusGlassSettings(
  CampusPalette palette,
  CampusGlassRole role,
  CampusGlassTier tier, {
  bool floating = false,
  bool pressed = false,
}) {
  final navigation = role == CampusGlassRole.navigation;
  final tint = (pressed ? palette.surfaceSelected : palette.glassTint)
      .withValues(
        alpha: switch (role) {
          CampusGlassRole.navigation => floating ? .48 : .62,
          CampusGlassRole.control => .74,
          CampusGlassRole.overlay => .82,
        },
      );
  // 浅色浮层压在弹窗遮罩上会发灰，整块均匀提亮（不按明度门控，否则暗底上不起作用），
  // 让次要文字和文字按钮在实际合成背景上不低于 4.5:1；数值按模拟器实测取。
  final whiten = role == CampusGlassRole.overlay && !palette.isDark ? .65 : 0.0;
  // 没有遮罩的浮层（菜单、提示条，floating）压在同色内容上，靠柔和投影分层；有遮罩的弹窗、弹层不加。
  final shadow = role == CampusGlassRole.overlay && floating ? campusFloatingShadow : null;
  if (tier == CampusGlassTier.full) {
    return (palette.isDark
            ? liquid.LiquidGlassSettings.ios27Dark
            : liquid.LiquidGlassSettings.ios27Light)
        .copyWith(
          glassColor: tint,
          thickness: switch (role) {
            CampusGlassRole.navigation => floating ? 32 : 20,
            CampusGlassRole.control => 16,
            CampusGlassRole.overlay => 24,
          },
          chromaticAberration: navigation ? 0 : .2,
          // 浮层承载整段文字，雾化完全盖住底层清晰副本，只透出模糊色块，避免底下的字和浮层文字叠影。
          frostOpacity: role == CampusGlassRole.overlay ? 1 : null,
          whitenStrength: whiten,
          whitenGated: false,
          shadow: shadow,
          platformViewFallbackColor: palette.glassFallback,
        );
  }
  return liquid.LiquidGlassSettings(
    glassColor: tint,
    thickness: navigation && floating ? 16 : 8,
    blur: navigation ? (floating ? 10 : 8) : 6,
    saturation: .9,
    refractiveIndex: navigation && floating ? 1.15 : 1.10,
    lightIntensity: navigation ? (floating ? .40 : .25) : .35,
    ambientStrength: navigation ? .12 : .16,
    chromaticAberration: 0,
    glowIntensity: 0,
    shadowElevation: navigation && floating ? 1 : 0,
    whitenStrength: whiten,
    whitenGated: false,
    shadow: shadow,
    platformViewFallbackColor: palette.glassFallback,
  );
}

const campusFloatingShadow = [BoxShadow(color: Color(0x24000000), blurRadius: 32, offset: Offset(0, 8))];
