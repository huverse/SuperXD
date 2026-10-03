import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_press.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

// [人工决策-2026-10-02 16:43:38] 主按钮紧凑玻璃胶囊、轻描边，视觉约38dp但触区至少48dp；按下液态鼓起、松手轻过冲回位（取代09-27的按压轻收缩），满档时手指处有高光；父玻璃内仍只做vibrancy，原生交互不变。
// [人工决策-2026-10-03 17:37:24] 上条的玻璃胶囊与鼓起只用于导航层和浮层（顶栏、底栏、悬浮按钮、弹窗、菜单、弹层、提示条）；
// 内容区（页面与卡片里）的按钮和选择标签改为不透明的色调胶囊，与苹果 HIG、鸿蒙 7 沉浸光感的使用范围一致：内容区不用液态玻璃。
Widget campusButtonBackground(
  BuildContext context,
  Set<WidgetState> states,
  Widget? child,
) => CampusGlassButtonSurface(states: states, child: child!);

class CampusGlassButtonSurface extends StatelessWidget {
  const CampusGlassButtonSurface({
    super.key,
    required this.states,
    required this.child,
    this.round = false,
    this.neutral = false,
  });
  final Set<WidgetState> states;
  final Widget child;
  final bool round;
  // 选择标签：内容区未选时为中性底，不着主色，与操作按钮区分。
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) && !disabled;
    if (GlassPanelScope.maybeOf(context) == null && !CampusChrome.of(context)) {
      return CampusTonalSurface(states: states, neutral: neutral, child: child);
    }
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) => CampusGlassPress(
        pressed: pressed,
        radius: 1000,
        glowColor: CampusGlassScope.tierOf(context, ready: ready) == CampusGlassTier.full
            ? Colors.white.withValues(alpha: CampusPalette.of(context).isDark ? .16 : .32)
            : null,
        // 选中的标签与按下时同样着 surfaceSelected 色，但不鼓起。
        builder: (context, contentScale) => CampusGlassSurface(
          round: true,
          softOutline: !round,
          disabled: disabled,
          pressed: pressed || states.contains(WidgetState.selected),
          focused: states.contains(WidgetState.focused),
          child: Transform.scale(scale: contentScale, child: child),
        ),
      ),
    );
  }
}

class CampusGlassCircleButton extends StatelessWidget {
  const CampusGlassCircleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.size = 52,
  });
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  // 顶栏操作用44，视觉更轻；触区仍由按钮主题的padded保证至少48。
  final double size;
  @override
  // 读屏标签由按钮内的 Semantics 提供，提示框不再重复生成一个同名节点，避免读两遍。
  // 圆形按钮只用于顶栏操作和悬浮按钮，属于导航层，始终画玻璃。
  Widget build(BuildContext context) => CampusChrome(child: Tooltip(
    message: label,
    excludeFromSemantics: true,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        shape: const CircleBorder(),
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
        backgroundBuilder: (context, states, child) => CampusGlassButtonSurface(
          states: states,
          round: true,
          child: child!,
        ),
      ),
      child: Semantics(label: label, excludeSemantics: true, child: icon),
    ),
  ));
}

// 内容区按钮与选择标签的色调胶囊：不透明、不取背景，不随背景变化；操作按钮着主色浅底配主色字，
// 选择标签未选为中性浅底、选中为 surfaceSelected 加主色细边和勾。按下底色加深并轻缩到 97%（鸿蒙按压缩放），减少动画时不缩放。
class CampusTonalSurface extends StatelessWidget {
  const CampusTonalSurface({super.key, required this.states, required this.child, this.neutral = false});
  final Set<WidgetState> states;
  final Widget child;
  final bool neutral;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) && !disabled;
    final selected = states.contains(WidgetState.selected);
    final focused = states.contains(WidgetState.focused);
    final dark = palette.isDark;
    final fill = disabled
        ? palette.onSurface.withValues(alpha: .05)
        : selected
        ? (pressed ? Color.alphaBlend(palette.onSurface.withValues(alpha: .08), palette.surfaceSelected) : palette.surfaceSelected)
        : neutral
        ? palette.onSurface.withValues(alpha: dark ? (pressed ? .18 : .10) : (pressed ? .13 : .07))
        : palette.primary.withValues(alpha: dark ? (pressed ? .22 : .14) : (pressed ? .14 : .08));
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 120);
    return AnimatedScale(
      scale: pressed && duration > Duration.zero ? .97 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: duration,
        decoration: ShapeDecoration(
          color: fill,
          shape: StadiumBorder(
            side: focused
                ? BorderSide(color: palette.primary, width: 2)
                : selected && !disabled
                ? BorderSide(color: palette.primary.withValues(alpha: .4))
                : BorderSide.none,
          ),
        ),
        child: child,
      ),
    );
  }
}
