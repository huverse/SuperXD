import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_controller.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_models.dart';
import 'package:superxd/toolbox/chaoxing/chaoxing_sign_sheet.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

// 群聊里的签到：有些签到只发在班级群里，课表那边的活动列表看不到，这里按群翻出来签。
Future<void> showChaoxingGroupPage(
  BuildContext context, {
  required ChaoxingController controller,
  ToolboxQrScan? scanQrCode,
}) => Navigator.of(context).push<void>(
  CampusPageRoute(builder: (_) => ChaoxingGroupPage(controller: controller, scanQrCode: scanQrCode)),
);

class ChaoxingGroupPage extends StatefulWidget {
  const ChaoxingGroupPage({super.key, required this.controller, this.scanQrCode});
  final ChaoxingController controller;
  final ToolboxQrScan? scanQrCode;
  @override
  State<ChaoxingGroupPage> createState() => _ChaoxingGroupPageState();
}

class _ChaoxingGroupPageState extends State<ChaoxingGroupPage> {
  List<ChaoxingActivity>? _activities;
  String? _error;
  int? _signingActiveId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _activities = null;
      _error = null;
    });
    try {
      final activities = await widget.controller.loadGroupActivities();
      if (!mounted) return;
      setState(() => _activities = activities);
    } on ChaoxingFailure catch (failure) {
      if (mounted) setState(() => _error = failure.message);
    } catch (failure, stack) {
      campusLog('[Chaoxing] action=group errorType=${failure.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '群聊没读到，请稍后重试');
    }
  }

  Future<void> _sign(ChaoxingActivity activity) async {
    setState(() => _signingActiveId = activity.activeId);
    final result = await showChaoxingSignSheet(
      context,
      controller: widget.controller,
      activity: activity,
      scanQrCode: widget.scanQrCode,
    );
    if (!mounted) return;
    setState(() => _signingActiveId = null);
    if (result != null) {
      showCampusToast(context, result.late ? '签到成功，不过已经迟到' : '签到成功');
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
        actions: [
          IconButton(
            tooltip: '重新读取',
            onPressed: _activities == null && _error == null ? null : () => _load(),
            icon: const CampusIcon(CampusIcons.sync),
          ),
        ],
      ),
      body: switch ((_error, activities)) {
        (final String message, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: palette.danger)),
          ),
        ),
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
                  CampusSurface(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(
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
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _signingActiveId == null ? () => _sign(activity) : null,
                          child: CampusBusyContent(
                            busy: _signingActiveId == activity.activeId,
                            label: '去签到',
                            busyLabel: '签到中',
                          ),
                        ),
                      ],
                    ),
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
