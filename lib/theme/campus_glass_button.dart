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

// [人工决策-2026-10-04 15:29:32] 新增强调按钮（同 iOS 26 glassProminent、鸿蒙 EMPHASIZED）：每屏、每个弹窗只给一个主操作，
// 控件激活色 accent 为底、白字带图标；内容区是实底胶囊，导航层与浮层是 accent 染色玻璃（扩展上两条，其余按钮形态不变）。
// 禁用时整体变淡、形态不变，仍看得出是本页主操作。用法：FilledButton(style: campusProminent, ...)；弹窗操作区的 FilledButton 自动是强调。
final campusProminent = _tinted((palette) => palette.accent);

// 句中的链接（如“服务协议”“隐私政策”）：只有主色文字、不画胶囊，触区仍至少 48。
final campusLink = ButtonStyle(
  padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
  minimumSize: const WidgetStatePropertyAll(Size(0, 48)),
  backgroundBuilder: (context, states, child) => child!,
);

// 破坏性操作（删除、清空、退出、覆盖等）的确认按钮：同强调按钮，底色为警示红（同 iOS destructive、鸿蒙警示按钮）。
final campusDestructive = _tinted((palette) => palette.dangerFill);

ButtonStyle _tinted(Color Function(CampusPalette palette) color) {
  final foreground = WidgetStateProperty.resolveWith((states) => Colors.white.withValues(alpha: states.contains(WidgetState.disabled) ? .9 : 1));
  return ButtonStyle(
    foregroundColor: foreground,
    iconColor: foreground,
    backgroundBuilder: (context, states, child) => CampusGlassButtonSurface(states: states, tint: color(CampusPalette.of(context)), child: child!),
  );
}

class CampusGlassButtonSurface extends StatelessWidget {
  const CampusGlassButtonSurface({
    super.key,
    required this.states,
    required this.child,
    this.round = false,
    this.neutral = false,
    this.tint,
  });
  final Set<WidgetState> states;
  final Widget child;
  final bool round;
  // 选择标签：内容区未选时为中性底，不着主色，与操作按钮区分。
  final bool neutral;
  // 强调按钮的底色（accent 或 dangerFill），白字；为空是普通按钮。见 campusProminent、campusDestructive。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) && !disabled;
    if (GlassPanelScope.maybeOf(context) == null && !CampusChrome.of(context)) {
      final tint = this.tint;
      return tint != null ? CampusProminentSurface(states: states, color: tint, child: child) : CampusTonalSurface(states: states, neutral: neutral, child: child);
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
          tint: tint,
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

// 内容区的强调按钮：accent 实底胶囊；按下加深一档并轻缩到 97%（同色调胶囊），禁用时底色变淡、形态不变。减少动画时不缩放。
class CampusProminentSurface extends StatelessWidget {
  const CampusProminentSurface({super.key, required this.states, required this.color, required this.child});
  final Set<WidgetState> states;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) && !disabled;
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 120);
    return AnimatedScale(
      scale: pressed && duration > Duration.zero ? .97 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: duration,
        decoration: ShapeDecoration(
          color: campusProminentFill(color, pressed: pressed, disabled: disabled),
          shape: StadiumBorder(side: states.contains(WidgetState.focused) ? BorderSide(color: palette.onSurface, width: 2) : BorderSide.none),
        ),
        child: child,
      ),
    );
  }
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
