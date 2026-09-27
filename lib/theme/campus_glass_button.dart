import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_surface.dart';

// [人工决策-2026-09-27 16:30:11] 主按钮紧凑玻璃胶囊、轻描边与按压反馈，视觉约38dp但触区至少48dp；父玻璃内仍只做vibrancy，原生交互不变。
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
  Widget build(BuildContext context) => AnimatedScale(
    scale:
        states.contains(WidgetState.pressed) &&
            !states.contains(WidgetState.disabled)
        ? .98
        : 1,
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 120),
    curve: Curves.easeOutCubic,
    child: CampusGlassSurface(
      round: true,
      softOutline: !round,
      disabled: states.contains(WidgetState.disabled),
      pressed: states.contains(WidgetState.pressed),
      focused: states.contains(WidgetState.focused),
      child: child,
    ),
  );
}

class CampusGlassCircleButton extends StatelessWidget {
  const CampusGlassCircleButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        shape: const CircleBorder(),
        fixedSize: const Size.square(52),
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
