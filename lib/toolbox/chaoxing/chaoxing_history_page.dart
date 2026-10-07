import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity_card.dart';

// 往期签到：本账号已结束的活动（活动列表 status 不为 1 的）。照样能签，签到页会提示可能记为迟到；
// 数据来自主列表同一次拉取，不额外请求。
Future<void> showChaoxingHistoryPage(BuildContext context, {required ChaoxingSignLauncher launcher}) =>
    Navigator.of(context).push<void>(
      CampusPageRoute(builder: (_) => ChaoxingHistoryPage(launcher: launcher)),
    );

class ChaoxingHistoryPage extends StatelessWidget {
  const ChaoxingHistoryPage({super.key, required this.launcher});
  final ChaoxingSignLauncher launcher;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final controller = launcher.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('往期签到'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
      ),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final activities = controller.pastActivities;
          if (activities.isEmpty) {
            return Center(
              child: Text('还没有已结束的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            );
          }
          return CampusScrollFade(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                for (final activity in activities)
                  ChaoxingActivityCard(
                    key: ValueKey(activity.activeId),
                    activity: activity,
                    onSign: () => launcher.open(context, activity),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
