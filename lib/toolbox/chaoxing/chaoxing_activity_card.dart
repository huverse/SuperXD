import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_sheet.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 打开签到弹层的统一入口：首页、往期、课程与群聊各页都从这里开，签完给同样的提示并刷新一次列表。
class ChaoxingSignLauncher {
  const ChaoxingSignLauncher({required this.controller, this.scanQrCode, this.watchQrCode, this.pickImage});
  final ChaoxingController controller;
  final ToolboxQrScan? scanQrCode;
  final ToolboxQrWatch? watchQrCode;
  final ToolboxImagePick? pickImage;

  Future<void> open(BuildContext context, ChaoxingActivity activity) async {
    final summary = await showChaoxingSignSheet(
      context,
      controller: controller,
      activity: activity,
      scanQrCode: scanQrCode,
      watchQrCode: watchQrCode,
      pickImage: pickImage,
    );
    if (!context.mounted || summary == null) return;
    showCampusToast(context, chaoxingSummaryText(summary));
    controller.refresh().catchError((Object error, StackTrace stack) {
      campusLog('[Chaoxing] action=refresh errorType=${error.runtimeType}\n$stack');
    });
  }
}

String chaoxingSummaryText(ChaoxingSignSummary summary) => summary.succeeded == 1
    ? chaoxingSignedText(late: summary.late)
    : '已为 ${summary.succeeded} 人签到${summary.late ? '，有人迟到' : ''}';

// 活动卡片：标题行是课程名，下面是活动名与类型、时间。进行中的写开始时间，已结束的写截止时间（都用两个字的前缀，完整时间在卡片里不折行）；
// 不知道开始时间的有截止就写截止，都没有就不显示时间行。
class ChaoxingActivityCard extends StatelessWidget {
  const ChaoxingActivityCard({super.key, required this.activity, required this.onSign, this.showCourse = true});
  final ChaoxingActivity activity;
  final VoidCallback onSign;
  final bool showCourse;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final startTime = activity.startTime;
    final endTime = activity.endTime;
    final time = startTime != null && (activity.ongoing || endTime == null)
        ? '开始 ${formatCampusTimestamp(startTime.toIso8601String())}'
        : endTime != null
        ? '截止 ${formatCampusTimestamp(endTime.toIso8601String())}'
        : null;
    // 十分钟内刚发起的签到给个橙点角标（对齐参考项目），一眼看出哪个是老师刚发的；不知道开始时间的不算。
    final fresh = activity.ongoing && startTime != null && DateTime.now().toUtc().difference(startTime) <= const Duration(minutes: 10);
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (showCourse)
                  Row(
                    children: [
                      Flexible(child: Text(activity.subtitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface))),
                      if (fresh) ...[
                        const SizedBox(width: 6),
                        _FreshBadge(),
                      ],
                    ],
                  )
                else
                  DotSeparatedText(activity.displayTitle, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                if (showCourse) ...[
                  const SizedBox(height: 4),
                  DotSeparatedText(activity.displayTitle, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                ],
                if (time != null) ...[
                  const SizedBox(height: 2),
                  Text(time, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                ],
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

// 二级页顶栏的刷新按钮：刷新中原地转，不清掉页面上的旧内容。
class ChaoxingRefreshButton extends StatelessWidget {
  const ChaoxingRefreshButton({super.key, required this.loading, required this.onRefresh});
  final bool loading;
  // 为空时按钮暂不可点（比如首次读取中）。
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: loading ? '正在刷新' : '刷新',
    onPressed: loading ? null : onRefresh,
    icon: loading ? const CampusLoader(size: 20, delay: Duration.zero) : const CampusIcon(CampusIcons.sync),
  );
}

// 一组签到的列表页（按课程查看点进一门课、群聊点进一个群）：进行中与已结束分两组，顶栏刷新；
// 刷新保留旧列表、只在顶栏按钮上原地转，首次读不到给原因与重试，已有内容时刷新失败只给提示条。
class ChaoxingActivitiesPage extends StatefulWidget {
  const ChaoxingActivitiesPage({super.key, required this.launcher, required this.title, required this.load, required this.notes});
  final ChaoxingSignLauncher launcher;
  final String title;

  // 读这一页的签到：failures 是没读到、被跳过的部分（几个班或几场），全读不到时由 load 自己报错。
  final Future<({List<ChaoxingActivity> activities, int failures})> Function() load;

  // 列表上方的说明（合并了几个班或群、几处没读到），并成一行；没什么要说时返回空列表，不占行。
  final List<String> Function(int failures) notes;

  @override
  State<ChaoxingActivitiesPage> createState() => _ChaoxingActivitiesPageState();
}

class _ChaoxingActivitiesPageState extends State<ChaoxingActivitiesPage> {
  List<ChaoxingActivity>? _activities;
  int _failures = 0;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.load();
      if (!mounted) return;
      setState(() {
        _activities = result.activities;
        _failures = result.failures;
      });
    } on ChaoxingFailure catch (failure) {
      _failed(failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=activities errorType=${failure.runtimeType}\n$stack');
      _failed('签到活动没读到，请稍后重试');
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

  Future<void> _sign(ChaoxingActivity activity) async {
    await widget.launcher.open(context, activity);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final activities = _activities;
    final ongoing = [for (final activity in activities ?? const <ChaoxingActivity>[]) if (activity.ongoing) activity];
    final ended = [for (final activity in activities ?? const <ChaoxingActivity>[]) if (!activity.ongoing) activity];
    final notes = widget.notes(_failures);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        // 首次读取时页面中间已经在转，顶栏按钮不再同时转（不让两段加载动画同时演），只是暂不可点。
        actions: [ChaoxingRefreshButton(loading: _loading && _activities != null, onRefresh: _loading ? null : () => _load())],
      ),
      body: switch ((_error, activities)) {
        (final String message, null) => CampusLoadError(message: message, onRetry: () => _load()),
        (_, null) => const CampusLoading(label: '正在读取签到活动…', network: true, remote: '学习通'),
        _ => _lazyList([
              if (notes.isNotEmpty)
                () => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(notes.join('；'), style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
                ),
              () => ChaoxingSectionTitle('进行中（${ongoing.length}）'),
              if (ongoing.isEmpty)
                () => Text('现在没有进行中的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
              else
                for (final activity in ongoing)
                  () => ChaoxingActivityCard(key: ValueKey(activity.activeId), activity: activity, showCourse: false, onSign: () => _sign(activity)),
              () => ChaoxingSectionTitle('已结束（${ended.length}）'),
              if (ended.isEmpty)
                () => Text('还没有已结束的签到', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant))
              else
                for (final activity in ended)
                  () => ChaoxingActivityCard(key: ValueKey(activity.activeId), activity: activity, showCourse: false, onSign: () => _sign(activity)),
            ]),
      },
    );
  }

  // 签到会越积越多：按需构建，只建屏幕上的那几行。
  Widget _lazyList(List<Widget Function()> rows) => CampusScrollFade(
    child: ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index](),
    ),
  );
}

// 刚发起的橙点：状态信息不用主色，橙色与主色区分开。
class _FreshBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: palette.attention, shape: BoxShape.circle, border: Border.all(color: palette.surface, width: 2)),
    );
  }
}
