import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';

// 详情里的「标签 值」两列行（同 iOS 设置的 Value1 行）：左列标签次要色、按最宽的标签对齐，右列值正文色、长了在右列里换行；
// 值为空的行不画。课程详情与成绩详情共用，详情不再各写一套（以前成绩详情是「课程代码：D109」这种冒号行）。
class CampusFieldTable extends StatelessWidget {
  const CampusFieldTable({super.key, required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final secondary = TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant);
    return Table(
      columnWidths: const {0: IntrinsicColumnWidth(), 1: FlexColumnWidth()},
      defaultVerticalAlignment: TableCellVerticalAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        for (final (label, value) in rows)
          if (value.isNotEmpty) TableRow(children: [
            Padding(padding: const EdgeInsets.fromLTRB(0, 6, 16, 6), child: Text(label, style: secondary)),
            Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: SelectableText(value, style: TextStyle(fontSize: 16, color: CampusPalette.of(context).onSurface))),
          ]),
      ],
    );
  }
}
