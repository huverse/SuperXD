import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' as liquid;

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_material.dart';
import 'package:superxd/theme/campus_glass_tier.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/native_glass.dart';

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
    // iOS 点选标签有系统的选择触感（同系统分段控件）。
    final onPressed = onSelected == null
        ? null
        : () {
            if (campusIos) HapticFeedback.selectionClick();
            onSelected(!selected);
          };
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
    // 按钮自成读屏节点，外层的选中状态不合并就落到祖先节点上，读屏听不到“已选中”。
    return MergeSemantics(child: Semantics(
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
                // iOS 是 Flutter 的 iOS 样式开关（[人工决策] 见 native_glass.dart）；读屏由整行的 toggled 报。
                child: campusIos
                    ? CupertinoSwitch(value: value, onChanged: onChanged, activeTrackColor: palette.accent)
                    : tier == CampusGlassTier.solid || !ready
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
// marks 画在滑杆下方（推荐范围的色条与带名字的刻度），按这一种滑杆的拇指行程对齐：玻璃滑杆离两端 15（拇指半径），
// iOS 样式 22（内边距 8 加拇指半径 14），实色档的系统滑杆 24（按压光圈半径）。
class CampusSlider extends StatelessWidget {
  const CampusSlider({super.key, required this.value, required this.label, required this.onChanged, this.onChangeEnd, this.marks});
  final double value;
  final String label;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  final CampusSliderMarks? marks;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: campusGlassReady,
      builder: (context, ready, _) {
        final tier = CampusGlassScope.tierOf(context, ready: ready);
        final solid = tier == CampusGlassTier.solid || !ready;
        final slider = SizedBox(
          height: 48,
          child: Center(
            // iOS 是 Flutter 的 iOS 样式滑杆（[人工决策] 见 native_glass.dart）。
            // iOS 样式滑杆在宽松约束下只取自己的最小宽度（约 176），要撑满整行。
            child: campusIos
                ? SizedBox(width: double.infinity, child: MergeSemantics(child: Semantics(label: label, child: CupertinoSlider(value: value, onChanged: onChanged, onChangeEnd: onChangeEnd, activeColor: palette.accent))))
                : solid
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
        final marks = this.marks;
        if (marks == null) return slider;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          slider,
          Padding(padding: EdgeInsets.symmetric(horizontal: campusIos ? 22 : solid ? 24 : 15), child: _SliderMarks(marks)),
        ]);
      },
    );
  }
}

// 滑杆下方的刻度：band 是一段色条（如推荐范围）、bandLabel 是它的名字，ticks 是带名字的刻度（如系统字号），位置都是 0–1 的比例。
// 名字互相挤时刻度优先，色条的名字依次试居中、靠起点、靠终点，都和刻度的名字挤就放到下一行居中。只画给眼睛看，读屏由调用方的说明文字讲。
class CampusSliderMarks {
  const CampusSliderMarks({this.band, this.bandLabel, this.ticks = const []});
  final (double, double)? band;
  final String? bandLabel;
  final List<(double, String)> ticks;
}

class _SliderMarks extends StatelessWidget {
  const _SliderMarks(this.marks);
  final CampusSliderMarks marks;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final style = TextStyle(fontSize: 14, height: 1.3, color: palette.onSurfaceVariant);
    final line = campusTextPainter(context, '国', style: style);
    final labelHeight = line.height;
    line.dispose();
    final band = marks.band;
    final bandColor = palette.accent.withValues(alpha: palette.isDark ? .55 : .4);
    return ExcludeSemantics(child: LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      // 名字的左缘：以 x 为中心，靠边时收在滑杆范围里不出界。
      double centered(double x, double labelWidth) => (x - labelWidth / 2).clamp(0.0, (width - labelWidth).clamp(0.0, double.infinity));
      final placed = <(double, double)>[];
      bool free(double left, double labelWidth) => placed.every((range) => left + labelWidth + 8 <= range.$1 || left >= range.$2 + 8);
      final labels = <Widget>[];
      for (final (position, label) in marks.ticks) {
        final labelWidth = campusTextWidth(context, label, style: style);
        final left = centered(position * width, labelWidth);
        placed.add((left, left + labelWidth));
        labels.add(Positioned(top: 10, left: left, child: Text(label, maxLines: 1, softWrap: false, style: style)));
      }
      final bandLabel = marks.bandLabel;
      var rows = 1;
      if (band != null && bandLabel != null) {
        final labelWidth = campusTextWidth(context, bandLabel, style: style);
        final start = band.$1 * width, end = band.$2 * width;
        final left = [centered((start + end) / 2, labelWidth), start, end - labelWidth].where((left) => left >= start - .5 && left + labelWidth <= end + .5 && free(left, labelWidth)).firstOrNull;
        if (left == null) rows = 2;
        labels.add(Positioned(top: 10 + (rows - 1) * labelHeight, left: left ?? centered((start + end) / 2, labelWidth), child: Text(bandLabel, maxLines: 1, softWrap: false, style: style.copyWith(color: palette.accentText))));
      }
      return SizedBox(height: 10 + labelHeight * rows, child: Stack(clipBehavior: Clip.none, children: [
        if (band != null) Positioned(
          left: band.$1 * width, width: (band.$2 - band.$1) * width, top: 1, height: 4,
          child: DecoratedBox(decoration: BoxDecoration(color: bandColor, borderRadius: BorderRadius.circular(2))),
        ),
        for (final (position, _) in marks.ticks)
          Positioned(left: position * width - 1, top: 0, width: 2, height: 7, child: DecoratedBox(decoration: BoxDecoration(color: palette.onSurfaceVariant, borderRadius: BorderRadius.circular(1)))),
        ...labels,
      ]));
    }));
  }
}
