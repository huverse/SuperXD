import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/toolbox/toolbox_catalog.dart';
import 'package:superxd/toolbox/toolbox_models.dart';
import 'package:superxd/toolbox/toolbox_module.dart';
import 'package:superxd/toolbox/toolbox_runtime.dart';
import 'package:superxd/domain/campus_log.dart';

class ToolboxPage extends StatefulWidget {
  const ToolboxPage({super.key, required this.runtime, this.modules});
  final ToolboxRuntime runtime;
  final List<ToolboxModule>? modules;
  @override
  State<ToolboxPage> createState() => _ToolboxPageState();
}

class _ToolboxPageState extends State<ToolboxPage> {
  late Future<void> _ready = widget.runtime.initialize();
  late final _modules = widget.modules ?? toolboxCatalog(widget.runtime);
  final _busy = <String>{};
  String? _error;

  Future<void> _operation(String id, Future<void> Function() action) async {
    if (_busy.contains(id)) return;
    setState(() {
      _busy.add(id);
      _error = null;
    });
    try {
      await action();
    } catch (error, stack) {
      campusLog(
        '[Toolbox] action=manage errorType=${error.runtimeType}\n$stack',
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

  Future<void> _uninstall(ToolboxModule module) async {
    final agreed = await showCampusDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('卸载${module.name}？'),
        content: const Text('将取消本工具任务并移除资源，已保存的视频保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (agreed == true && mounted) {
      await _operation(
        module.id,
        () => widget.runtime.downloads.uninstall(module.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: '返回',
        icon: const CampusIcon(CampusIcons.back),
        onPressed: () => context.pop(),
      ),
      title: const Text('百宝箱'),
    ),
    body: SafeArea(
      child: FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('百宝箱暂未就绪'),
                  TextButton(
                    onPressed: () => setState(() {
                      _ready = widget.runtime.initialize();
                    }),
                    child: const Text('重试'),
                  ),
                ],
              ),
            );
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CampusLoading(label: '正在准备百宝箱'));
          }
          return ListenableBuilder(
            listenable: widget.runtime.downloads,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(color: CampusPalette.of(context).danger),
                    ),
                  ),
                for (final module in _modules)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _tile(module),
                  ),
              ],
            ),
          );
        },
      ),
    ),
  );

  Widget _tile(ToolboxModule module) {
    final manager = widget.runtime.downloads;
    final installed =
        module.resource == null || manager.resources.installed(module.id);
    final task = manager
        .forTool(module.id)
        .where((download) => !download.terminal)
        .firstOrNull;
    final busy = _busy.contains(module.id);
    final colors = CampusPalette.of(context);
    final card = CampusSurface(
      padding: const EdgeInsets.all(16),
      onTap: installed && !busy
          ? () => context.push('/toolbox/${module.id}')
          : null,
      child: Row(
        children: [
          CampusIcon(module.icon, size: 28, color: colors.primary),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(module.name, style: const TextStyle(fontSize: 16)),
                if (task != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: task.totalBytes > 0 ? task.progress : null,
                  ),
                ],
                if (!installed && task == null)
                  Text(
                    '${(module.resource!.bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                    style: TextStyle(
                      fontSize: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (module.resource == null)
            const CampusIcon(CampusIcons.next)
          else if (installed)
            IconButton(
              tooltip: '管理资源',
              onPressed: busy ? null : () => _uninstall(module),
              icon: const CampusIcon(CampusIcons.manage),
            )
          else if (task != null)
            IconButton(
              tooltip: '取消下载',
              onPressed: busy
                  ? null
                  : () => _operation(module.id, () => manager.cancel(task.id)),
              icon: const CampusIcon(CampusIcons.close),
            )
          else
            IconButton(
              tooltip: '下载资源',
              onPressed: busy
                  ? null
                  : () => _operation(module.id, () async {
                      await manager.downloadResource(module.id);
                    }),
              icon: const CampusIcon(CampusIcons.download),
            ),
        ],
      ),
    );
    if (module.resource == null || !installed) return card;
    // [人工决策-2026-09-27 20:12:08] 保留右滑但仅揭示卸载按钮，必须点击确认；不以滑动距离直接删除。
    return Slidable(
      key: ValueKey(module.id),
      startActionPane: ActionPane(
        motion: const BehindMotion(),
        extentRatio: .28,
        children: [
          SlidableAction(
            onPressed: busy ? null : (_) => _uninstall(module),
            backgroundColor: colors.danger,
            foregroundColor: colors.onDanger,
            icon: CampusIcons.delete,
            label: '卸载',
          ),
        ],
      ),
      child: card,
    );
  }
}
