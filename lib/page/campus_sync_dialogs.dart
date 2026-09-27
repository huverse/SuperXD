import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/theme/campus_icons.dart';

Future<void> showCampusSyncReport(
  BuildContext context,
  CampusSyncReport report,
) => showCampusDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(report.sessionExpired ? '同步中止，请重新登录' : '同步结果'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in report.items)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [CampusIcon(switch (item.outcome) { SyncOutcome.completed => CampusIcons.success, SyncOutcome.failed => CampusIcons.warning, SyncOutcome.skipped => CampusIcons.info }, size: 20), const SizedBox(width: 8), Expanded(child: Text(
                '${switch (item.outcome) {
                  SyncOutcome.completed => '完成',
                  SyncOutcome.skipped => '跳过',
                  SyncOutcome.failed => '失败',
                }} · ${item.label}\n${item.message}',
                style: const TextStyle(fontSize: 14),
              ))]),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(report.sessionExpired ? '重新登录' : '知道了'),
      ),
    ],
  ),
);
