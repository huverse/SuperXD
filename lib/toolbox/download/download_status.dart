import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/toolbox/download/toolbox_download_manager.dart';
import 'package:superxd/toolbox/toolbox_models.dart';

String downloadStateLabel(ToolboxDownloadState state) => switch (state) {
  ToolboxDownloadState.queued => '等待下载',
  ToolboxDownloadState.downloading => '下载中',
  ToolboxDownloadState.pausing => '正在暂停',
  ToolboxDownloadState.paused => '已暂停',
  ToolboxDownloadState.cancelling => '正在停止',
  ToolboxDownloadState.verifying => '校验中',
  ToolboxDownloadState.awaitingSave => '待保存',
  ToolboxDownloadState.saving => '保存中',
  ToolboxDownloadState.saved => '已保存到本地',
  ToolboxDownloadState.installed => '资源已就绪',
  ToolboxDownloadState.cancelled => '已取消',
  ToolboxDownloadState.failed => '未完成',
};

// 结果页与下载管理页共用：状态行只读不可点，进度条随传输实时刷新，未知大小时显示不定进度。
class DownloadProgress extends StatelessWidget {
  const DownloadProgress({super.key, required this.item, this.label});
  final ToolboxDownload item;
  final String? label;
  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final state = item.state;
    final color = switch (state) {
      ToolboxDownloadState.saved ||
      ToolboxDownloadState.installed => palette.primary,
      ToolboxDownloadState.failed ||
      ToolboxDownloadState.awaitingSave => palette.danger,
      _ => palette.onSurfaceVariant,
    };
    final icon = switch (state) {
      ToolboxDownloadState.saved ||
      ToolboxDownloadState.installed => CampusIcons.success,
      ToolboxDownloadState.failed ||
      ToolboxDownloadState.awaitingSave => CampusIcons.warning,
      ToolboxDownloadState.cancelled => CampusIcons.close,
      ToolboxDownloadState.paused ||
      ToolboxDownloadState.pausing => CampusIcons.pause,
      _ => CampusIcons.download,
    };
    final measured =
        item.totalBytes > 0 &&
        (item.transferring ||
            state == ToolboxDownloadState.paused ||
            state == ToolboxDownloadState.pausing);
    final (bar, value) = switch (state) {
      ToolboxDownloadState.queued ||
      ToolboxDownloadState.pausing ||
      ToolboxDownloadState.paused => (true, item.progress),
      ToolboxDownloadState.downloading => (
        true,
        item.totalBytes > 0 ? item.progress : null,
      ),
      ToolboxDownloadState.verifying ||
      ToolboxDownloadState.saving ||
      ToolboxDownloadState.cancelling => (true, null),
      _ => (false, null),
    };
    // 主色只留给可点按钮：成功态文字用次要色、仅图标着主色，避免与"打开"混淆；异常态文字保留警示色。
    final status = Text(
      downloadStateLabel(state),
      style: TextStyle(
        color: color == palette.danger ? color : palette.onSurfaceVariant,
        fontWeight: FontWeight.w600,
      ),
    );
    final bodySmall = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (label case final label?)
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            CampusIcon(icon, size: 18, color: color),
            const SizedBox(width: 6),
            label == null ? Expanded(child: status) : Flexible(child: status),
            if (measured) ...[
              const SizedBox(width: 8),
              Text('${(item.progress * 100).floor()}%', style: bodySmall),
            ],
          ],
        ),
        if (bar) ...[
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: value,
            borderRadius: BorderRadius.circular(4),
          ),
        ],
        if (measured)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '${(item.progress * item.totalBytes / 1048576).toStringAsFixed(1)} / ${(item.totalBytes / 1048576).toStringAsFixed(1)} MB',
              style: bodySmall,
            ),
          ),
        if (item.error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(error, style: TextStyle(color: palette.danger)),
          ),
      ],
    );
  }
}

// 按状态只给当下可做的操作：主操作玻璃按钮在前，次操作带图标文字按钮在后，校验与保存等过渡态不给按钮。
List<Widget> downloadActions({
  required ToolboxDownload item,
  required ToolboxDownloadManager manager,
  required bool busy,
  required Future<void> Function(String id, Future<void> Function() action)
  operate,
}) {
  VoidCallback? run(Future<void> Function() action) =>
      busy ? null : () => operate(item.id, action);
  return [
    if (item.state == ToolboxDownloadState.saved)
      FilledButton.icon(
        onPressed: run(() => manager.open(item.id)),
        icon: const CampusIcon(CampusIcons.open),
        label: const Text('打开'),
      ),
    if (item.state == ToolboxDownloadState.paused)
      FilledButton.icon(
        onPressed: run(() => manager.resumeTask(item.id)),
        icon: const CampusIcon(CampusIcons.resume),
        label: const Text('继续'),
      ),
    if (item.state == ToolboxDownloadState.awaitingSave)
      FilledButton.icon(
        onPressed: run(() => manager.save(item.id)),
        icon: const CampusIcon(CampusIcons.download),
        label: const Text('重试保存'),
      ),
    if (item.transferring)
      TextButton.icon(
        onPressed: run(() => manager.pauseTask(item.id)),
        icon: const CampusIcon(CampusIcons.pause),
        label: const Text('暂停'),
      ),
    if (item.canCancel || item.state == ToolboxDownloadState.cancelling)
      TextButton.icon(
        onPressed: run(() => manager.cancel(item.id)),
        icon: const CampusIcon(CampusIcons.close),
        label: const Text('取消下载'),
      ),
  ];
}
