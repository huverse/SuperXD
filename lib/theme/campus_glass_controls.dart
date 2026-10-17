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
    this.leading,
  });
  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  // 没选中时显示在名字前的小图标（如带颜色的标签图标）；选中时换成勾。
  final Widget? leading;

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
    // 选中前后是同一个按钮，只在按钮里给勾号让位：图标位宽度平滑展开、图标淡入，文字跟着滑开，胶囊两端始终是圆的。
    // 以前整个按钮换成带图标的那种、外面包一层 AnimatedSize：勾号和文字一下子到位，胶囊右端在展开途中被裁成直边。
    final icon = selected ? const CampusIcon(CampusIcons.check, size: 18) : leading;
    // 图标与文字的间距同 FilledButton.icon：大字号时从 8 收到 4。
    final gap = 8 - 4 * ((MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0) - 1);
    final slot = icon == null ? const SizedBox.shrink() : Padding(key: ValueKey(selected), padding: EdgeInsetsDirectional.only(end: gap), child: icon);
    return Semantics(
      selected: selected,
      child: FilledButton(
        style: style,
        onPressed: onPressed,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 减少动画时直接到位，不包动画（AnimatedSize 时长为 0 会在自己的布局里改自己，框架直接报错）。
            if (MediaQuery.disableAnimationsOf(context))
              slot
            else
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                alignment: AlignmentDirectional.centerStart,
                child: AnimatedSwitcher(duration: const Duration(milliseconds: 160), child: slot),
              ),
            Flexible(child: Text(label)),
          ],
        ),
      ),
    );
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
                    ? Switch(value: value, onChanged: onChanged, activeTrackColor: palette.accent, activeThumbColor: Colors.white)
                    : liquid.GlassSwitch(
                        value: value,
                        onChanged: onChanged,
                        activeColor: palette.accent,
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

// 滑杆：同 iOS 26 滑杆，细轨道、白色滑块，拖动时滑块化为玻璃透镜，已选段着主色；实色档沿用系统 Slider。
// 值域 0–1。onChanged 在拖动中连续回调；onChangeEnd 只在正常松手时回调，系统取消与读屏增减不回调，调用方要自行兜底保存。
class CampusSlider extends StatelessWidget {
  const CampusSlider({super.key, required this.value, required this.label, required this.onChanged, this.onChangeEnd});
  final double value;
  final String label;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final tier = CampusGlassScope.tierOf(context, ready: ready);
        return SizedBox(
          height: 48,
          child: Center(
            child: tier == CampusGlassTier.solid || !ready
                ? MergeSemantics(child: Semantics(label: label, child: Slider(value: value, onChanged: onChanged, onChangeEnd: onChangeEnd, activeColor: palette.accent)))
                : liquid.GlassSlider(
                    value: value,
                    onChanged: onChanged,
                    onChangeEnd: onChangeEnd,
                    label: label,
                    activeColor: palette.accent,
                    inactiveColor: palette.onSurfaceVariant.withValues(alpha: .28),
                    quality: campusGlassQuality(tier),
                    settings: campusGlassSettings(palette, CampusGlassRole.control, tier),
                  ),
          ),
        );
      },
    );
  }
}
