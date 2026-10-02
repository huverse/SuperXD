import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_press.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

// [人工决策-2026-10-02 16:43:38] 主按钮紧凑玻璃胶囊、轻描边，视觉约38dp但触区至少48dp；按下液态鼓起、松手轻过冲回位（取代09-27的按压轻收缩），满档时手指处有高光；父玻璃内仍只做vibrancy，原生交互不变。
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
  });
  final Set<WidgetState> states;
  final Widget child;
  final bool round;

  @override
  Widget build(BuildContext context) {
    final disabled = states.contains(WidgetState.disabled);
    final pressed = states.contains(WidgetState.pressed) && !disabled;
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
  Widget build(BuildContext context) => Tooltip(
    message: label,
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
  );
}
