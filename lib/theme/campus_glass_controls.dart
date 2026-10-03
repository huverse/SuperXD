import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/glass_panel.dart';

// 选择标签：复用主按钮的背景（导航层与浮层里是玻璃，内容区是中性色调胶囊）；选中时着 surfaceSelected 色并带勾。
// 未选、选中都用可读深色文字，禁用为 onSurfaceVariant，不用 primary，避免和按钮混淆。
class CampusGlassChip extends StatelessWidget {
  const CampusGlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final onSelected = this.onSelected;
    final onPressed = onSelected == null ? null : () => onSelected(!selected);
    final style = FilledButton.styleFrom(
      foregroundColor: palette.onSurface,
      iconColor: palette.primary,
      textStyle: TextStyle(
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      backgroundBuilder: (context, states, child) => CampusGlassButtonSurface(
        states: {...states, if (selected) WidgetState.selected},
        neutral: true,
        child: child!,
      ),
    );
    // 选中时多出勾号，宽度平滑展开而不是瞬间跳变；减少动画时直接到位。
    return AnimatedSize(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
      selected: selected,
      child: selected
          ? FilledButton.icon(
              style: style,
              onPressed: onPressed,
              icon: const CampusIcon(CampusIcons.check, size: 18),
              label: Text(label),
            )
          : FilledButton(style: style, onPressed: onPressed, child: Text(label)),
    ));
  }
}

// 开关行：整行可点、触区足够；玻璃档位下开关为 GlassSwitch，实色档沿用系统 Switch。
class CampusSwitchTile extends StatelessWidget {
  const CampusSwitchTile({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.contentPadding,
  });
  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final tier = CampusGlassScope.tierOf(context, ready: ready);
        return MergeSemantics(
          child: Semantics(
            toggled: value,
            child: ListTile(
              contentPadding: contentPadding,
              title: title,
              subtitle: subtitle,
              onTap: () => onChanged(!value),
              trailing: ExcludeSemantics(
                child: tier == CampusGlassTier.solid || !ready
                    ? Switch(value: value, onChanged: onChanged)
                    : liquid.GlassSwitch(
                        value: value,
                        onChanged: onChanged,
                        activeColor: palette.primary,
                        // 浅色下库默认的 iOS 浅灰轨道与白色滑块只有约1.7:1，关闭态看不清；
                        // 改为按配色压暗的不透明灰，滑块对轨道不低于3:1。深色默认值已足够。
                        inactiveColor: palette.isDark
                            ? null
                            : Color.alphaBlend(
                                palette.onSurfaceVariant.withValues(alpha: .7),
                                palette.surface,
                              ),
                        quality: campusGlassQuality(tier),
                        settings: campusGlassSettings(
                          palette,
                          CampusGlassRole.control,
                          tier,
                        ),
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
