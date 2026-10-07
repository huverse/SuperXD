import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_sheet.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 打开签到弹层的统一入口：首页、往期、课程与群聊各页都从这里开，签完给同样的提示并刷新一次列表。
class ChaoxingSignLauncher {
  const ChaoxingSignLauncher({required this.controller, this.scanQrCode, this.watchQrCode});
  final ChaoxingController controller;
  final ToolboxQrScan? scanQrCode;
  final ToolboxQrWatch? watchQrCode;

  Future<void> open(BuildContext context, ChaoxingActivity activity) async {
    final summary = await showChaoxingSignSheet(
      context,
      controller: controller,
      activity: activity,
      scanQrCode: scanQrCode,
      watchQrCode: watchQrCode,
    );
    if (!context.mounted || summary == null) return;
    showCampusToast(context, chaoxingSummaryText(summary));
    controller.refresh().catchError((Object error, StackTrace stack) {
      campusLog('[Chaoxing] action=refresh errorType=${error.runtimeType}\n$stack');
    });
  }
}

String chaoxingSummaryText(ChaoxingSignSummary summary) => summary.succeeded == 1
    ? (summary.late ? '签到成功，不过已经迟到' : '签到成功')
    : '已为 ${summary.succeeded} 人签到${summary.late ? '，有人迟到' : ''}';

// 活动卡片：标题行是课程名，下面是活动名与类型、时间。进行中的写开始时间，已结束的写截止时间（都用两个字的前缀，完整时间在卡片里不折行）。
class ChaoxingActivityCard extends StatelessWidget {
  const ChaoxingActivityCard({super.key, required this.activity, required this.onSign, this.showCourse = true});
  final ChaoxingActivity activity;
  final VoidCallback onSign;
  final bool showCourse;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final endTime = activity.endTime;
    final time = activity.ongoing || endTime == null
        ? '开始 ${formatCampusTimestamp(activity.startTime.toIso8601String())}'
        : '截止 ${formatCampusTimestamp(endTime.toIso8601String())}';
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showCourse)
                  Text(activity.subtitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface))
                else
                  ChaoxingDotText(activity.displayTitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                if (showCourse) ...[
                  const SizedBox(height: 4),
                  ChaoxingDotText(activity.displayTitle, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                ],
                const SizedBox(height: 2),
                Text(time, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            onPressed: onSign,
            child: const CampusBusyContent(busy: false, label: '去签到', busyLabel: '签到中', icon: CampusIcon(CampusIcons.check)),
          ),
        ],
      ),
    );
  }
}

// 分组标题：组名加条数，标题是只读信息，不用主色。
class ChaoxingSectionTitle extends StatelessWidget {
  const ChaoxingSectionTitle(this.title, {super.key, this.trailing = const []});
  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface))),
          ...trailing,
        ],
      ),
    );
  }
}
