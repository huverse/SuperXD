import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_activity_card.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';

// 群聊里的签到：有些签到只发在班级群里，课表那边的活动列表看不到，这里按群翻出来签。
Future<void> showChaoxingGroupPage(BuildContext context, {required ChaoxingSignLauncher launcher}) =>
    Navigator.of(context).push<void>(CampusPageRoute(builder: (_) => ChaoxingGroupPage(launcher: launcher)));

class ChaoxingGroupPage extends StatefulWidget {
  const ChaoxingGroupPage({super.key, required this.launcher});
  final ChaoxingSignLauncher launcher;
  @override
  State<ChaoxingGroupPage> createState() => _ChaoxingGroupPageState();
}

class _ChaoxingGroupPageState extends State<ChaoxingGroupPage> {
  List<ChaoxingActivity>? _activities;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // 刷新保留旧列表（局部刷新不清空、不丢滚动位置），只在顶栏按钮上原地转。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final activities = await widget.launcher.controller.loadGroupActivities();
      if (!mounted) return;
      setState(() => _activities = activities);
    } on ChaoxingFailure catch (failure) {
      _failed(failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=group errorType=${failure.runtimeType}\n$stack');
      _failed('群聊没读到，请稍后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 还没有内容时整页显示原因与重试；已有内容时只给提示条，旧列表留着。
  void _failed(String message) {
    if (!mounted) return;
    if (_activities == null) {
      setState(() => _error = message);
    } else {
      showCampusToast(context, message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final activities = _activities;
    return Scaffold(
      appBar: AppBar(
        title: const Text('群聊里的签到'),
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context),
          icon: const CampusIcon(CampusIcons.back),
        ),
        actions: [ChaoxingRefreshButton(loading: _loading, onRefresh: () => _load())],
      ),
      body: switch ((_error, activities)) {
        (final String message, null) => ChaoxingLoadError(message: message, onRetry: () => _load()),
        (_, null) => const CampusLoading(label: '正在翻群聊…', network: true),
        (_, final List<ChaoxingActivity> items) => CampusScrollFade(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    '群里现在没有能签到的活动',
                    style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                  ),
                )
              else
                for (final activity in items)
                  ChaoxingActivityCard(
                    key: ValueKey(activity.activeId),
                    activity: activity,
                    onSign: () => widget.launcher.open(context, activity),
                  ),
              if (items.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '这里只列群聊里发过的签到，和课表活动列表可能重复',
                    style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
                  ),
                ),
            ],
          ),
        ),
      },
    );
  }
}
