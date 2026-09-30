import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/theme/campus_icons.dart';

// 会话失效优先提示重新登录；中途离开或教务限流而提前结束时列出未处理项，返回true表示用户选择重新同步。
Future<bool> showCampusSyncReport(
  BuildContext context,
  CampusSyncReport report,
) async {
  final interrupted = !report.sessionExpired && report.unfinished.isNotEmpty;
  Widget row(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [CampusIcon(icon, size: 20), const SizedBox(width: 8), Expanded(child: Text(text, style: const TextStyle(fontSize: 14)))]),
  );
  return await showCampusDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(report.sessionExpired ? '同步中止，请重新登录' : interrupted ? '同步已中止' : '同步结果'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final item in report.items)
              row(switch (item.outcome) { SyncOutcome.completed => CampusIcons.success, SyncOutcome.failed => CampusIcons.warning, SyncOutcome.skipped => CampusIcons.info }, '${switch (item.outcome) {
                SyncOutcome.completed => '完成',
                SyncOutcome.skipped => '跳过',
                SyncOutcome.failed => '失败',
              }} · ${item.label}\n${item.message}'),
            for (final label in report.unfinished) row(CampusIcons.pause, '未处理 · $label'),
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
