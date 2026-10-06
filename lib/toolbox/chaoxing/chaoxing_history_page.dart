import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';

// 往期签到：只读回看本账号已经结束的活动。能签的那些在主列表里，这里不给操作
// （已结束的提交也只会被学习通退回）。数据来自主列表同一次拉取，不额外请求。
Future<void> showChaoxingHistoryPage(BuildContext context, {required ChaoxingController controller}) =>
    Navigator.of(context).push<void>(
      CampusPageRoute(builder: (_) => ChaoxingHistoryPage(controller: controller)),
    );

class ChaoxingHistoryPage extends StatelessWidget {
  const ChaoxingHistoryPage({super.key, required this.controller});
  final ChaoxingController controller;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
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
                  CampusSurface(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          activity.subtitle,
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          activity.displayTitle,
                          style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '已结束 ${formatCampusTimestamp((activity.endTime ?? activity.startTime).toIso8601String())}',
                          style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
