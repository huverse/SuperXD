import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/local/developer_settings.dart';
import 'package:superxd/local/diagnostic_log.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 运行环境各项的显示名（键见组合根 app_diagnostics.dart 的 appEnvironment）。
const _environmentLabels = {'version': '版本', 'build': '构建号', 'flavor': '渠道', 'os': '系统', 'sdk': 'API 级别', 'device': '机型', 'abi': '处理器架构'};

// 开发者选项：只在开发者模式开着时从「关于」进来。日志的查看、导出与清除，性能浮层，运行环境；关掉开发者模式即删开发者模式日志。
class DeveloperPage extends StatefulWidget {
  const DeveloperPage({super.key, required this.developer, required this.logs});
  final DeveloperSettings developer;
  final DiagnosticLog logs;

  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  late Future<int> _size = widget.logs.totalBytes();
  bool _exporting = false;

  void _refreshSize() => setState(() {
    _size = widget.logs.totalBytes();
  });

  Future<void> _turnOff() async {
    final agreed = await showCampusConfirm(context, title: '关闭开发者模式', message: '停止记录并删除开发者模式日志，错误记录保留。要留着日志请先导出。', action: '关闭', destructive: true);
    if (!agreed || !mounted) return;
    await widget.developer.setEnabled(false);
    await widget.logs.clearDiagnostics();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    String? filename;
    try {
      filename = await widget.logs.export();
    } catch (error, stack) {
      campusLog('[Developer] action=export errorType=${error.runtimeType}\n$stack');
    }
    if (!mounted) return;
    setState(() => _exporting = false);
    showCampusToast(context, filename == null ? '导出没完成，请重试' : '已保存到 Download/SuperXD：$filename');
  }

  Future<void> _more(BuildContext anchor) async {
    final choice = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'clear', label: '清除日志', icon: CampusIcons.delete, destructive: true)]);
    if (choice != 'clear' || !mounted) return;
    final agreed = await showCampusConfirm(context, title: '清除日志', message: '删除本机的全部日志，包括错误记录。', action: '清除', destructive: true);
    if (!agreed || !mounted) return;
    await widget.logs.clear();
    if (!mounted) return;
    _refreshSize();
    showCampusToast(context, '已清除日志');
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    final command = 'adb pull ${widget.logs.directory.path}';
    final environment = [for (final MapEntry(:key, :value) in widget.logs.environment.entries) (_environmentLabels[key] ?? key, value)];
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('开发者选项'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListenableBuilder(
        listenable: widget.developer,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: CampusSwitchTile(
              title: const Text('开发者模式'),
              subtitle: const Text('记录运行日志与诊断信息，只存本机'),
              value: widget.developer.enabled,
              onChanged: (value) {
                if (!value) _turnOff();
              },
            )),
            const SizedBox(height: 16),
            CampusSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('日志', style: Theme.of(context).textTheme.titleMedium)),
                Builder(builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
              ]),
              FutureBuilder<int>(future: _size, builder: (context, snapshot) => Text(
                // 不到 1MB 按 KB 写，免得几 KB 的日志显示成「0.0 MB」像是没有。
                switch (snapshot.data) {
                  null => ' ',
                  final bytes when bytes < 1024 * 1024 => '本机共 ${(bytes / 1024).ceil()} KB',
                  final bytes => '本机共 ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB',
                },
                style: secondary,
              )),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    await Navigator.push(context, CampusPageRoute<void>(builder: (_) => DeveloperLogPage(logs: widget.logs)));
                    if (mounted) _refreshSize();
                  },
                  icon: const CampusIcon(CampusIcons.logs),
                  label: const Text('查看日志'),
                ),
                FilledButton(
                  style: campusProminent,
                  onPressed: _exporting ? null : _export,
                  child: CampusBusyContent(busy: _exporting, label: '导出日志', busyLabel: '导出中', icon: const CampusIcon(CampusIcons.exportLogs)),
                ),
              ]),
              const SizedBox(height: 16),
              // 连上电脑直接拷出整个日志目录（应用专属外部目录，不需要权限，也不用先在手机上导出）。
              Text('连电脑拷出', style: secondary),
              Row(children: [
                Expanded(child: SelectableText(command, style: TextStyle(fontSize: 14, fontFamily: 'monospace', color: colors.onSurface))),
                IconButton(
                  tooltip: '复制命令',
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (context.mounted) showCampusToast(context, '已复制');
                  },
                  icon: const CampusIcon(CampusIcons.copy),
                ),
              ]),
            ])),
            const SizedBox(height: 16),
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: CampusSwitchTile(
              title: const Text('性能浮层'),
              subtitle: const Text('屏幕上方显示每帧的构建与绘制耗时'),
              value: widget.developer.performanceOverlay,
              onChanged: (value) => widget.developer.setPerformanceOverlay(value),
            )),
            if (environment.isNotEmpty) ...[
              const SizedBox(height: 16),
              CampusSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('运行环境', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                CampusFieldTable(rows: environment),
              ])),
            ],
          ],
        ),
      ))))),
    );
  }
}

// 查看日志：最新的在上，可在「全部」（开发者模式日志）与「错误」（平时也记的错误记录）之间切换、按内容搜索；点一条展开全文，可复制。
class DeveloperLogPage extends StatefulWidget {
  const DeveloperLogPage({super.key, required this.logs});
  final DiagnosticLog logs;

  @override
  State<DeveloperLogPage> createState() => _DeveloperLogPageState();
}

class _DeveloperLogPageState extends State<DeveloperLogPage> {
  final _search = TextEditingController();
  bool _errorsOnly = false;
  late Future<List<DiagnosticRecord>> _records = widget.logs.recent(errorsOnly: _errorsOnly);
  final _expanded = <DiagnosticRecord>{};

  void _reload() => setState(() {
    _expanded.clear();
    _records = widget.logs.recent(errorsOnly: _errorsOnly);
  });

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _time(DateTime time) {
    final local = campusInstant(time);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.month}月${local.day}日 ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final query = _search.text.trim().toLowerCase();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('日志'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CampusGlassCircleButton(label: '刷新', size: 44, onPressed: _reload, icon: const CampusIcon(CampusIcons.sync)),
          ),
        ],
      ),
      body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: CampusSegmented<bool>(
            values: const [false, true],
            label: (errorsOnly) => errorsOnly ? '错误' : '全部',
            selected: _errorsOnly,
            onSelected: (errorsOnly) {
              _errorsOnly = errorsOnly;
              _reload();
            },
          ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: CampusSearchField(controller: _search, hint: '搜索模块或内容')),
        Expanded(child: FutureBuilder<List<DiagnosticRecord>>(
          future: _records,
          builder: (context, snapshot) {
            if (snapshot.hasError) return CampusLoadError(message: '日志读取没完成', onRetry: _reload);
            final records = snapshot.data;
            if (records == null) return const Center(child: CampusLoading(label: '正在读取'));
            final shown = query.isEmpty ? records : [for (final record in records) if (record.text.toLowerCase().contains(query)) record];
            if (shown.isEmpty) return Center(child: Text(records.isEmpty ? '还没有日志' : '没有匹配的日志', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)));
            return CampusScrollFade(child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: shown.length,
              itemBuilder: (context, index) {
                final record = shown[index];
                final open = _expanded.contains(record);
                return InkWell(
                  onTap: () => setState(() {
                    if (!_expanded.remove(record)) _expanded.add(record);
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_time(record.time), style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
                        open
                            ? SelectableText(record.text, style: TextStyle(fontSize: 14, fontFamily: 'monospace', color: colors.onSurface))
                            : Text(record.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, fontFamily: 'monospace', color: colors.onSurface)),
                      ])),
                      if (open)
                        IconButton(
                          tooltip: '复制这条',
                          onPressed: () async {
                            await Clipboard.setData(ClipboardData(text: '${record.time.toIso8601String()} ${record.text}'));
                            if (context.mounted) showCampusToast(context, '已复制');
                          },
                          icon: const CampusIcon(CampusIcons.copy),
                        )
                      else
                        Padding(padding: const EdgeInsets.all(12), child: CampusIcon(CampusIcons.expand, size: 20, color: colors.onSurfaceVariant)),
                    ]),
                  ),
                );
              },
            ));
          },
        )),
      ])))),
    );
  }
}
