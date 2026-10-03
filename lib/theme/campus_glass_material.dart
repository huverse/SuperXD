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
    platformViewFallbackColor: palette.glassFallback,
  );
}
