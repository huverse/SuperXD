import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 发布超过这么久还没截止的签到，提醒确认没选错（与学习通客户端同一口径）。
const chaoxingStaleActivityAge = Duration(hours: 6);

// 签到弹层里的时间提示：已结束的活动照样能签，但可能记为迟到；发布太久的提醒确认没选错。
// [人工决策-2026-10-07 17:00:58] 测试阶段以参考项目为准：往期活动维持「照样能签、可能记为迟到」的提示，失败后仍给「重试」。
// 实测老师已结束的活动强制提交会被学习通拒绝（原样返回「签到已结束」），用户选定不为此改文案或收紧按钮（方案 A）。
class ChaoxingTimeNotice extends StatelessWidget {
  const ChaoxingTimeNotice({super.key, required this.activity});
  final ChaoxingActivity activity;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final now = DateTime.now().toUtc();
    final end = activity.endTime;
    final String? message;
    if (!activity.ongoing) {
      message = end == null
          ? '这场签到已经结束或还没开始，现在签到可能会记为迟到'
          : '这场签到已在 ${formatCampusTimestamp(end.toIso8601String())} 截止，现在签到可能会记为迟到';
    } else if (now.difference(activity.startTime) > chaoxingStaleActivityAge) {
      message = '这场签到发布于 ${formatCampusTimestamp(activity.startTime.toIso8601String())}，'
          '已经过去 ${now.difference(activity.startTime).inHours} 小时，确认没有选错';
    } else {
      message = null;
    }
    if (message == null) return const SizedBox.shrink();
    return _NoticeCard(
      children: [
        CampusIcon(CampusIcons.warning, color: palette.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
      ],
    );
  }
}

// 这个活动本身是签退活动，或它发布了签退活动时，给一条跳过去的入口。
class ChaoxingSignOutNotice extends StatelessWidget {
  const ChaoxingSignOutNotice({super.key, required this.info, required this.onOpenRelated});
  final ChaoxingActiveInfo info;

  // 跳到关联活动；为空表示现在不能跳（弹层忙着）。
  final void Function(int activeId)? onOpenRelated;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final state = info.signOutState;
    if (state == ChaoxingSignOutState.none) return const SizedBox.shrink();
    final relatedActiveId = info.relatedActiveId;
    final open = onOpenRelated;
    final (message, action) = switch (state) {
      ChaoxingSignOutState.signOutActivity => ('这是签退活动，先确认主签到已经完成', '去主签到'),
      ChaoxingSignOutState.signOutPublished => ('这次签到还发布了签退活动', '去签退'),
      _ => ('签退活动将在 ${info.signOutPublishTime == null ? '稍后' : formatCampusTimestamp(info.signOutPublishTime!.toIso8601String())} 发布，到时候再来签退', null),
    };
    return _NoticeCard(
      children: [
        Expanded(child: Text(message, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))),
        if (action != null && relatedActiveId != null) ...[
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: open == null ? null : () => open(relatedActiveId),
            icon: const CampusIcon(CampusIcons.next),
            label: Text(action),
          ),
        ],
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: CampusSurface(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      radius: 16,
      child: Row(children: children),
    ),
  );
}
