import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.runtime});
  final ToolboxRuntime runtime;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  int _filter = 0;
  final _busy = <String>{};
  String? _error;
  Future<void> _operate(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      await action();
    } catch (error, stack) {
      debugPrint(
        '[DownloadsPage] action=manage errorType=${error.runtimeType}\n$stack',
      );
      if (mounted) {
        setState(
          () =>
              _error = error is ToolboxException ? error.message : '操作未完成，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _delete(String id) async {
    final confirmed = await showCampusDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除下载记录？'),
        content: const Text('只移除记录，已保存到本地的文件保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除记录'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _operate(id, () => widget.runtime.downloads.deleteJob(id));
    }
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
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final value in [(0, '全部'), (1, '进行中'), (2, '已结束')])
                          ChoiceChip(
                            label: Text(value.$2),
                            selected: _filter == value.$1,
                            onSelected: (_) =>
                                setState(() => _filter = value.$1),
                          ),
                      ],
                    ),
                  ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: CampusPalette.of(context).danger,
                        ),
                      ),
                    ),
                  Expanded(
                    child: jobs.isEmpty
                        ? const Center(child: Text('暂无下载任务'))
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
  Widget _job(String id, List<ToolboxDownload> items) {
    final done = items
        .where((item) => item.state == ToolboxDownloadState.saved)
        .length;
    final failed = items
        .where(
          (item) =>
              item.state == ToolboxDownloadState.failed ||
              item.state == ToolboxDownloadState.cancelled,
        )
        .length;
    final total = items.first.groupTotal;
    final terminal = items.every((item) => item.terminal);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: CampusSurface(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              items.first.title.isEmpty ? '媒体下载' : items.first.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (total > 1)
              Text('已保存 $done / $total${failed > 0 ? ' · 未完成 $failed' : ''}'),
            Wrap(
              spacing: 8,
              children: [
                if (!terminal)
                  TextButton(
                    onPressed: _busy.contains(id)
                        ? null
                        : () => _operate(
                            id,
                            () => widget.runtime.downloads.cancelJob(id),
                          ),
                    child: const Text('取消整组'),
                  ),
                if (terminal)
                  TextButton(
                    onPressed: _busy.contains(id) ? null : () => _delete(id),
                    child: const Text('删除记录'),
                  ),
                if (failed > 0 && items.first.sourceUrl != null)
                  TextButton(
                    onPressed: () => Navigator.pop(context, items.first),
                    child: const Text('重新解析未完成项'),
                  ),
              ],
            ),
            for (final item in items) _item(item),
          ],
        ),
      ),
    );
  }

  Widget _item(ToolboxDownload item) {
    final manager = widget.runtime.downloads;
    final busy = _busy.contains(item.id) || _busy.contains(item.jobId);
    final label = switch (item.state) {
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
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${switch (item.kind) {
              ToolboxDownloadKind.image => '图片',
              ToolboxDownloadKind.audio => '音频',
              ToolboxDownloadKind.resource => '资源',
              _ => '视频',
            }} · $label',
          ),
          if (item.transferring) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: item.totalBytes > 0 ? item.progress : null,
            ),
            if (item.totalBytes > 0)
              Text(
                '${(item.progress * item.totalBytes / 1048576).toStringAsFixed(1)} / ${(item.totalBytes / 1048576).toStringAsFixed(1)} MB',
              ),
          ],
          if (item.error != null)
            Text(
              item.error!,
              style: TextStyle(color: CampusPalette.of(context).danger),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (item.transferring)
                TextButton(
                  onPressed: busy
                      ? null
                      : () =>
                            _operate(item.id, () => manager.pauseTask(item.id)),
                  child: const Text('暂停'),
                ),
              if (item.state == ToolboxDownloadState.paused)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _operate(
                          item.id,
                          () => manager.resumeTask(item.id),
                        ),
                  child: const Text('继续'),
                ),
              if (item.canCancel ||
                  item.state == ToolboxDownloadState.cancelling)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _operate(item.id, () => manager.cancel(item.id)),
                  child: const Text('取消'),
                ),
              if (item.state == ToolboxDownloadState.awaitingSave)
                FilledButton(
                  onPressed: busy
                      ? null
                      : () => _operate(item.id, () => manager.save(item.id)),
                  child: const Text('重试保存'),
                ),
              if (item.state == ToolboxDownloadState.saved)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _operate(item.id, () => manager.open(item.id)),
                  child: const Text('打开文件'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
