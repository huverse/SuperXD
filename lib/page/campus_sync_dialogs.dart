import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 会话失效优先提示重新登录；中途离开或教务限流而提前结束时列出未处理项，返回true表示用户选择重新同步。
Future<bool> showCampusSyncReport(
  BuildContext context,
  CampusSyncReport report,
) async {
  final interrupted = !report.sessionExpired && report.unfinished.isNotEmpty;
  // 每项两层：“完成 · 课表 · 2026-2027学年第一学期”按“ · ”分项换行（学期名整项不拆），说明降为次要色；读屏读整句。
  // 颜色取弹窗自己的 context，弹窗开着时切深浅色也跟随。
  // 有说明时整行读“标题\n说明”；没有说明时由 DotSeparatedText 自己读整句，不重复包一层。
  Widget row(BuildContext context, IconData icon, String head, [String? detail]) {
    final line = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CampusIcon(icon, size: 20),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DotSeparatedText(head, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: CampusPalette.of(context).onSurface)),
        if (detail != null && detail.isNotEmpty) Text(detail, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant)),
      ])),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: detail == null || detail.isEmpty ? line : Semantics(label: '$head\n$detail', excludeSemantics: true, child: line),
    );
  }
  return await showCampusDialog<bool>(
    context: context,
    builder: (context) => CampusGlassDialog(
      title: Text(report.sessionExpired ? '同步中止，请重新登录' : interrupted ? '同步已中止' : '同步结果'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in report.items)
              row(context, switch (item.outcome) { SyncOutcome.completed => CampusIcons.success, SyncOutcome.failed => CampusIcons.warning, SyncOutcome.skipped => CampusIcons.info }, '${switch (item.outcome) {
                SyncOutcome.completed => '完成',
                SyncOutcome.skipped => '跳过',
                SyncOutcome.failed => '失败',
              }} · ${item.label}', item.message),
            for (final label in report.unfinished) row(context, CampusIcons.pause, '未处理 · $label'),
            if (interrupted) Text(report.rateLimited ? '教务提示请求太过频繁，已停止剩余项；已完成的内容已保存，约1分钟后可重新同步。' : '离开今天页后已停止，已完成的内容已保存。', style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(report.sessionExpired ? '重新登录' : '知道了'),
        ),
        // 限流后应先等一会儿，不提供立即重新同步。
        if (interrupted && !report.rateLimited) FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('重新同步')),
      ],
    ),
  ) == true;
}
