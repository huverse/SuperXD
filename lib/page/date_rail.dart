import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/local/week.dart';

class DateRail extends StatefulWidget {
  static double heightOf(BuildContext context) => 80 * MediaQuery.textScalerOf(context).scale(14) / 14;
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
    final extent = 64 * MediaQuery.textScalerOf(context).scale(14) / 14;
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
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8), child: Semantics(selected: selected, button: true, label: '$iso $weekday', excludeSemantics: true,
            child: Material(color: selected ? CampusPalette.of(context).surfaceSelected : CampusPalette.of(context).surface, borderRadius: BorderRadius.circular(12),
              child: InkWell(borderRadius: BorderRadius.circular(12), onTap: () => widget.onSelect(iso), child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Text('${date.month}/${date.day}', style: TextStyle(fontSize: 14, color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)), const SizedBox(height: 2), Text(weekday, style: TextStyle(fontSize: 14, color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant))]))),
            ),
          ));
        },
      ),
    ));
  }
}
