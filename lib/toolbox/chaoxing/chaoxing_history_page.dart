import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
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
          // 列表还没读到（刚打开、切了账号、改了单位或客户端、上次没读成）时为空不等于没有往期签到：加载中就转，没读成给原因与重试。
          if (activities.isEmpty && !controller.activitiesLoaded) {
            return controller.loadingActivities
                ? const CampusLoading(label: '正在读取签到活动…', network: true, remote: '学习通')
                : CampusLoadError(
                    message: controller.error ?? '签到活动没读到，请稍后重试',
                    onRetry: () => controller.refresh().catchError((Object error, StackTrace stack) {
                      campusLog('[Chaoxing] action=history_retry errorType=${error.runtimeType}\n$stack');
                    }),
                  );
          }
          if (activities.isEmpty) {
            return Center(
              child: Text('还没有已结束的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
            );
          }
          // 已结束的活动会越积越多，按需构建，只建屏幕上的那几张。
          return CampusScrollFade(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              itemCount: activities.length,
              itemBuilder: (context, index) => ChaoxingActivityCard(
                key: ValueKey(activities[index].activeId),
                activity: activities[index],
                onSign: () => launcher.open(context, activities[index]),
              ),
            ),
          );
        },
      ),
    );
  }
}
