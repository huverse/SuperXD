import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/domain/week.dart';

class DateRail extends StatefulWidget {
  // 横条高度：两行字（日期与星期）按当前字号、字体与粗体文本量，加日期格上下各 8 的内边距与 8 的外边距。
  // 10-31 用户要上下留白短一点、「跟当时侧边栏收窄一样」：以前是 80×字号，留白跟着字号一起放大（130% 时日期格上下各空约 18）；
  // 现在同课表左侧栏收窄的做法，只按内容量、留白固定。
  static double heightOf(BuildContext context) {
    final date = campusTextPainter(context, '12/31', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600));
    final weekday = campusTextPainter(context, '周三', style: const TextStyle(fontSize: 14));
    final height = date.height + 2 + weekday.height + 16 + 16;
    date.dispose();
    weekday.dispose();
    return height.ceilToDouble();
  }

  // 日期格宽：同样按内容量（最宽的「88/88」按选中时的加粗量，和星期取宽的），左右各 8 的内边距、格间 8；
  // 以前是 64×字号，字形宽的字体里日期会折成两行。
  static double extentOf(BuildContext context) => (math.max(
    campusTextWidth(context, '88/88', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
    campusTextWidth(context, '周三', style: const TextStyle(fontSize: 14)),
  ) + 16 + 8).ceilToDouble();
  const DateRail({super.key, required this.first, required this.last, required this.selected, required this.onSelect, this.recenterRequest = 0});
  final String first;
  final String last;
  final String selected;
  final int recenterRequest;
  final ValueChanged<String> onSelect;
  @override
  State<DateRail> createState() => _DateRailState();
}

class _DateRailState extends State<DateRail> {
  final _scroll = ScrollController();
  double _extent = 64;
  @override
  void didUpdateWidget(DateRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.recenterRequest != widget.recenterRequest) {
      _ensureVisible(center: true);
    } else if (oldWidget.selected != widget.selected || oldWidget.first != widget.first) {
      _ensureVisible();
    }
  }
  void _ensureVisible({bool center = false}) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || !_scroll.hasClients) return;
    final index = parseIsoDate(widget.selected).difference(parseIsoDate(widget.first)).inDays;
    final start = 8 + index * _extent;
    final viewport = _scroll.position.viewportDimension;
    if (!center && start >= _scroll.offset && start + _extent <= _scroll.offset + viewport) return;
    final offset = (start - (viewport - _extent) / 2).clamp(0.0, _scroll.position.maxScrollExtent);
    if (MediaQuery.disableAnimationsOf(context)) { _scroll.jumpTo(offset); }
    else { _scroll.animateTo(offset, duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic); }
  });
  @override
  void dispose() { _scroll.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final first = parseIsoDate(widget.first);
    final count = parseIsoDate(widget.last).difference(first).inDays + 1;
    final extent = DateRail.extentOf(context);
    if (_extent != extent) { _extent = extent; _ensureVisible(); }
    if (!_scroll.hasClients) _ensureVisible();
    return ColoredBox(color: CampusPalette.of(context).surface.withValues(alpha: .58), child: SizedBox(
      height: DateRail.heightOf(context),
      child: ListView.builder(
        key: const ValueKey('date-rail'), controller: _scroll, scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8), itemExtent: _extent, itemCount: count,
        itemBuilder: (context, index) {
          final date = first.add(Duration(days: index));
          final iso = formatIsoDate(date);
          final selected = iso == widget.selected;
          final weekday = const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][date.weekday - 1];
          // 读屏整项一句；excludeSemantics 会连里面 InkWell 的点按动作一起排除，所以点按要在这里再给一次，否则读屏下点不了。
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8), child: Semantics(selected: selected, button: true, label: '$iso $weekday', onTap: () => widget.onSelect(iso), excludeSemantics: true,
            child: Material(color: selected ? CampusPalette.of(context).surfaceSelected : CampusPalette.of(context).surface, borderRadius: BorderRadius.circular(12),
              child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => widget.onSelect(iso), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text('${date.month}/${date.day}', style: TextStyle(fontSize: 14, color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)), const SizedBox(height: 2), Text(weekday, style: TextStyle(fontSize: 14, color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant))]))),
            ),
          ));
        },
      ),
    ));
  }
}
