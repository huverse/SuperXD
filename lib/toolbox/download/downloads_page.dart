import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/toolbox/download/download_status.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  int _filter = 0;
  final _busy = <String>{};
  final _expanded = <String>{};
  Future<void> _operate(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await action();
    } catch (error, stack) {
      campusLog(
        '[DownloadsPage] action=manage errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) {
        showCampusToast(
          context,
          error is ToolboxException ? error.message : '操作未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _delete(String id) async {
    final confirmed = await showCampusConfirm(
      context,
      title: '删除下载记录？',
      message: '只移除记录，已保存到本地的文件保留。',
      action: '删除记录',
    );
    if (confirmed && mounted) {
      await _operate(id, () => widget.runtime.downloads.deleteJob(id));
    }
  }

  static String _kindLabel(ToolboxDownloadKind kind) => switch (kind) {
    ToolboxDownloadKind.image => '图片',
    ToolboxDownloadKind.audio => '音频',
    ToolboxDownloadKind.resource => '资源',
    ToolboxDownloadKind.video => '视频',
  };
  // 同组按类型与资源序号自然排序，状态变化时条目位置不跳动。
  static int _order(ToolboxDownload a, ToolboxDownload b) {
    final pattern = RegExp(r'^(.*?)(\d*)$');
    final left = pattern.firstMatch(a.resourceId ?? a.id)!;
    final right = pattern.firstMatch(b.resourceId ?? b.id)!;
    if (a.kind != b.kind) return a.kind.index.compareTo(b.kind.index);
    if (left[1] != right[1]) return left[1]!.compareTo(right[1]!);
    return (int.tryParse(left[2]!) ?? -1).compareTo(
      int.tryParse(right[2]!) ?? -1,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('下载管理'),
      leading: IconButton(
        tooltip: '返回',
        onPressed: () => Navigator.pop(context),
        icon: const CampusIcon(CampusIcons.back),
      ),
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListenableBuilder(
            listenable: widget.runtime.downloads,
            builder: (context, _) {
              final groups = <String, List<ToolboxDownload>>{};
              for (final item in widget.runtime.downloads.forTool(
                'short_video',
              )) {
                groups.putIfAbsent(item.jobId, () => []).add(item);
              }
              final running = groups.values
                  .where((items) => items.any((item) => !item.terminal))
                  .length;
              final jobs = groups.entries
                  .where(
                    (entry) =>
                        _filter == 0 ||
                        (_filter == 1
                            ? entry.value.any((item) => !item.terminal)
                            : entry.value.every((item) => item.terminal)),
                  )
                  .toList();
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final value in [
                            (0, '全部 ${groups.length}'),
                            (1, '进行中 $running'),
                            (2, '已结束 ${groups.length - running}'),
                          ])
                            CampusGlassChip(
                              label: value.$2,
                              selected: _filter == value.$1,
                              onSelected: (_) =>
                                  setState(() => _filter = value.$1),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: jobs.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CampusIcon(
                                  CampusIcons.download,
                                  size: 40,
                                  color: CampusPalette.of(context)
                                      .onSurfaceVariant,
                                ),
                                const SizedBox(height: 12),
                                Text(switch (_filter) {
                                  1 => '没有进行中的任务',
                                  2 => '没有已结束的任务',
                                  _ => '暂无下载任务',
                                }),
                              ],
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: jobs.length,
                            itemBuilder: (context, index) =>
                                _job(jobs[index].key, jobs[index].value),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );

  // 层级：标题区只读说明，⋯菜单放整组操作，条目状态文字不可点，可点的都是带图标按钮。
  Widget _job(String id, List<ToolboxDownload> items) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    items.sort(_order);
    final first = items.first;
    final saved = items
        .where((item) => item.state == ToolboxDownloadState.saved)
        .length;
    final failed = items
        .where(
          (item) =>
              item.state == ToolboxDownloadState.failed ||
              item.state == ToolboxDownloadState.cancelled,
        )
        .length;
    // [人工决策-2026-10-01 22:31:55] 组内“进行中”含排队项，不拆成“下载中/排队”；与结果页图集汇总同口径。
    final active = items.where((item) => !item.terminal).length;
    final single = items.length == 1;
    final expanded = items.length <= 3 || _expanded.contains(id);
    final menu = [
      if (!single && active > 0) ('cancel', '取消全部', CampusIcons.close),
      if (active == 0) ('delete', '删除记录', CampusIcons.delete),
    ];
    final progress =
        items.fold<double>(
          0,
          (sum, item) =>
              sum +
              switch (item.state) {
                ToolboxDownloadState.saved => 1,
                ToolboxDownloadState.failed ||
                ToolboxDownloadState.cancelled => 0,
                _ => item.progress,
              },
        ) /
        items.length;
    final ordinals = <ToolboxDownloadKind, int>{};
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CampusSurface(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: palette.surfaceSelected,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: CampusIcon(
                    switch (first.kind) {
                      _ when !single => CampusIcons.images,
                      ToolboxDownloadKind.image => CampusIcons.image,
                      ToolboxDownloadKind.audio => CampusIcons.audio,
                      _ => CampusIcons.video,
                    },
                    size: 20,
                    color: palette.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        first.title.isEmpty ? '媒体下载' : first.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${single ? _kindLabel(first.kind) : '${items.length} 项'} · ${formatCampusTimestamp(first.createdAt.toIso8601String())}',
                        style: textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (menu.isNotEmpty)
                  Builder(
                    builder: (anchor) => IconButton(
                      tooltip: '更多操作',
                      icon: const CampusIcon(CampusIcons.manage),
                      onPressed: _busy.contains(id)
                          ? null
                          : () async {
                              final value = await showCampusMenu<String>(
                                anchor,
                                items: [
                                  for (final entry in menu)
                                    CampusMenuItem(
                                      value: entry.$1,
                                      label: entry.$2,
                                      icon: entry.$3,
                                    ),
                                ],
                              );
                              if (value == null || !mounted) return;
                              await (value == 'delete'
                                  ? _delete(id)
                                  : _operate(
                                      id,
                                      () => widget.runtime.downloads.cancelJob(id),
                                    ));
                            },
                    ),
                  )
                else
                  const SizedBox(width: 8),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!single) ...[
                    const SizedBox(height: 12),
                    Text(
                      [
                        '已保存 $saved/${items.length}',
                        if (active > 0) '进行中 $active',
                        if (failed > 0) '未完成 $failed',
                      ].join(' · '),
                    ),
                    if (active > 0) ...[
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: progress,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ],
                  for (final item in items)
                    if (single || expanded)
                      _item(
                        item,
                        single
                            ? null
                            : '${_kindLabel(item.kind)} ${ordinals.update(item.kind, (count) => count + 1, ifAbsent: () => 1)}',
                      ),
                  if (!single && items.length > 3)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () => setState(
                          () => expanded
                              ? _expanded.remove(id)
                              : _expanded.add(id),
                        ),
                        icon: CampusIcon(
                          expanded ? CampusIcons.collapse : CampusIcons.expand,
                        ),
                        label: Text(expanded ? '收起' : '查看全部 ${items.length} 项'),
                      ),
                    ),
                  if (failed > 0 && first.sourceUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(context, first),
                          icon: const CampusIcon(CampusIcons.sync),
                          label: Text(single ? '重新解析' : '重新解析未完成项'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _item(ToolboxDownload item, String? label) {
    final actions = downloadActions(
      item: item,
      manager: widget.runtime.downloads,
      busy: _busy.contains(item.id) || _busy.contains(item.jobId),
      operate: _operate,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DownloadProgress(item: item, label: label),
          if (actions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(spacing: 8, runSpacing: 4, children: actions),
            ),
        ],
      ),
    );
  }
}
