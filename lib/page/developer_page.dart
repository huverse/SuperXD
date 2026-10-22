import 'package:flutter/gestures.dart';
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
import 'package:superxd/theme/campus_theme.dart';
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

  // 诊断摘要（运行环境加最近的几种错误，已掩码）复制成纯文字，粘贴进聊天或 Issue，不用传整个日志包。
  Future<void> _copySummary() async {
    final text = await widget.logs.summary();
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showCampusToast(context, '已复制诊断摘要');
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
                OutlinedButton.icon(onPressed: _copySummary, icon: const CampusIcon(CampusIcons.copy), label: const Text('复制摘要')),
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

// 查看页的一行：时刻、全文与出现次数（「错误」按种类汇总时大于 1）。
typedef _LogEntry = ({DateTime time, String text, int count});

// 查看日志：最新的在上，可在「全部」（开发者模式日志）与「错误」（平时也记的错误记录，按种类汇总、写出现几次）之间切换、按内容搜索；点一条展开全文，可复制。
class DeveloperLogPage extends StatefulWidget {
  const DeveloperLogPage({super.key, required this.logs});
  final DiagnosticLog logs;

  @override
  State<DeveloperLogPage> createState() => _DeveloperLogPageState();
}

class _DeveloperLogPageState extends State<DeveloperLogPage> {
  final _search = TextEditingController();
  bool _errorsOnly = false;
  late Future<List<_LogEntry>> _records = _load();
  final _expanded = <_LogEntry>{};

  Future<List<_LogEntry>> _load() async => _errorsOnly
      ? [for (final kind in await widget.logs.errorKinds()) (time: kind.last, text: kind.text, count: kind.count)]
      : [for (final record in await widget.logs.recent(errorsOnly: false)) (time: record.time, text: record.text, count: 1)];

  void _reload() => setState(() {
    _expanded.clear();
    _records = _load();
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
    final query = _search.text.trim();
    // 不分大小写的正则直接找：每按一个键都要把上千条（不少带堆栈）过一遍，比逐条转小写再找快一倍以上，没找到时快得更多。
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
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
        Expanded(child: FutureBuilder<List<_LogEntry>>(
          future: _records,
          builder: (context, snapshot) {
            if (snapshot.hasError) return CampusLoadError(message: '日志读取没完成', onRetry: _reload);
            final records = snapshot.data;
            if (records == null) return const Center(child: CampusLoading(label: '正在读取'));
            final shown = query.isEmpty ? records : [for (final record in records) if (pattern.hasMatch(record.text)) record];
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
                        Text(record.count > 1 ? '共 ${record.count} 次 · 最近 ${_time(record.time)}' : _time(record.time), style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
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

// [人工决策-2026-10-21 23:48:00] 悬浮按钮打标记（用户选定，同 DoKit、vConsole 的悬浮入口）：开发者模式下浮在所有页面上的小按钮，
// 可拖到屏幕任一处、松手贴到最近的左右边（让开系统的边缘返回手势区）；点开是开发者工具：在日志里标记「这里出问题了」（记当前页面路径与可选的一句说明），
// 以及查看日志、导出、开发者选项。只在开发者模式开着时出现，关掉即消失。
class DeveloperOverlay extends StatefulWidget {
  const DeveloperOverlay({super.key, required this.developer, required this.logs, required this.navigator, required this.location, required this.child});
  final DeveloperSettings developer;
  final DiagnosticLog logs;
  // 弹工具面板、推页面用的根导航器（悬浮按钮在导航器之外）。
  final GlobalKey<NavigatorState> navigator;
  // 当前路由路径（标记时记下）。
  final String Function() location;
  final Widget child;

  @override
  State<DeveloperOverlay> createState() => _DeveloperOverlayState();
}

class _DeveloperOverlayState extends State<DeveloperOverlay> {
  // 圆钮看着 44，触区按规范至少 48：贴边与拖动的范围按 48 的实际占位算。
  static const _size = 48.0;
  Offset? _position;
  // 按钮在导航器之外，自带一层 Overlay（圆钮的 Tooltip 要它）；这层与外面的 Stack 一直在，开关开发者模式只重画按钮，
  // 不改页面的父级结构，否则整个导航器会被重建、页面状态全丢。没开时这层什么都不画，点按穿透到下面的页面。
  late final _entry = OverlayEntry(builder: _button);

  @override
  void initState() {
    super.initState();
    widget.developer.addListener(_entry.markNeedsBuild);
  }

  @override
  void dispose() {
    widget.developer.removeListener(_entry.markNeedsBuild);
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  void _open() {
    final context = widget.navigator.currentContext;
    if (context == null) return;
    showCampusSheet<void>(context: context, builder: (_) => CampusSheetPanel(child: _DeveloperTools(developer: widget.developer, logs: widget.logs, navigator: widget.navigator, path: widget.location())));
  }

  Widget _button(BuildContext context) => !widget.developer.enabled ? const SizedBox.shrink() : LayoutBuilder(builder: (context, constraints) {
    final padding = MediaQuery.paddingOf(context);
    // 左右让开系统手势区：全面屏的边缘返回手势在这一窄条里优先，按钮贴太近时一拖就成了返回（模拟器上拖它把应用退出了）。
    final gestures = MediaQuery.systemGestureInsetsOf(context);
    final leftEdge = 8 + gestures.left, rightEdge = constraints.maxWidth - _size - 8 - gestures.right;
    double clampX(double x) => x.clamp(leftEdge, rightEdge);
    double clampY(double y) => y.clamp(padding.top + 8, constraints.maxHeight - padding.bottom - _size - 8);
    // 默认贴右边、在屏幕高度六成处，避开顶栏操作与底栏。
    final position = _position ?? Offset(rightEdge, constraints.maxHeight * .6);
    // 位移累加在最新的位置上：一帧里会来好几个移动事件，拿这一帧开始时的位置去加，按钮只跟上手指的几分之一（模拟器上拖不动）。
    void move(Offset Function(Offset current) next) {
      _position = next(_position ?? position);
      _entry.markNeedsBuild();
    }

    return Stack(children: [
      // 性能浮层也画在这层里，不用 MaterialApp 的 showPerformanceOverlay：那个开关会在整个页面外面加一层 Stack，
      // 页面换了父级要整个重建（入场淡入重放一次、悬浮按钮回到默认位置）。浮层不接点按，点按照样落到下面的页面。
      if (widget.developer.performanceOverlay) Positioned(top: 0, left: 0, right: 0, child: PerformanceOverlay.allEnabled()),
      Positioned(
        left: clampX(position.dx),
        top: clampY(position.dy),
        child: GestureDetector(
          // 从按下处算位移（默认从认出拖动时算，会丢掉开头那一小段），按钮一直跟在手指下面。
          dragStartBehavior: DragStartBehavior.down,
          onPanUpdate: (details) => move((current) => Offset(clampX(current.dx + details.delta.dx), clampY(current.dy + details.delta.dy))),
          onPanEnd: (_) => move((current) => Offset(current.dx + _size / 2 < constraints.maxWidth / 2 ? leftEdge : rightEdge, clampY(current.dy))),
          child: CampusGlassCircleButton(label: '开发者工具', size: 44, onPressed: _open, icon: const CampusIcon(CampusIcons.developer)),
        ),
      ),
    ]);
  });

  @override
  Widget build(BuildContext context) => Stack(children: [
    widget.child,
    Positioned.fill(child: Overlay(initialEntries: [_entry])),
  ]);
}

class _DeveloperTools extends StatefulWidget {
  const _DeveloperTools({required this.developer, required this.logs, required this.navigator, required this.path});
  final DeveloperSettings developer;
  final DiagnosticLog logs;
  final GlobalKey<NavigatorState> navigator;
  final String path;

  @override
  State<_DeveloperTools> createState() => _DeveloperToolsState();
}

class _DeveloperToolsState extends State<_DeveloperTools> {
  final _note = TextEditingController();
  bool _exporting = false;
  bool _marking = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  // 标记写成一条 [Mark] 日志并立即落盘，事后按它定位出问题的那一段；说明是本人写的，落盘时同样掩码。
  // 落盘要几十毫秒，弹层退场时还算挂着：连点两下会走两遍、第二遍把底下的页面也关掉，所以标记中不再响应。
  Future<void> _mark() async {
    if (_marking) return;
    _marking = true;
    final note = _note.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    campusLog('[Mark] action=mark path=${widget.path}${note.isEmpty ? '' : ' note=$note'}');
    await widget.logs.flush();
    if (!mounted) return;
    Navigator.pop(context);
    final root = widget.navigator.currentContext;
    if (root != null && root.mounted) showCampusToast(root, '已标记');
  }

  void _push(Widget page) {
    Navigator.pop(context);
    widget.navigator.currentState?.push(CampusPageRoute<void>(builder: (_) => page));
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

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('开发者工具', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('当前页面 ${widget.path}', style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant)),
        SizedBox(height: campusFieldGap(context)),
        TextField(controller: _note, maxLength: 100, style: const TextStyle(fontSize: 16), decoration: const InputDecoration(labelText: '说明（可不填）', counterText: '')),
        const SizedBox(height: 12),
        FilledButton.icon(style: campusProminent, onPressed: _mark, icon: const CampusIcon(CampusIcons.pin), label: const Text('标记这里')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(onPressed: () => _push(DeveloperLogPage(logs: widget.logs)), icon: const CampusIcon(CampusIcons.logs), label: const Text('查看日志')),
          OutlinedButton(
            onPressed: _exporting ? null : _export,
            child: CampusBusyContent(busy: _exporting, label: '导出日志', busyLabel: '导出中', icon: const CampusIcon(CampusIcons.exportLogs)),
          ),
          OutlinedButton.icon(onPressed: () => _push(DeveloperPage(developer: widget.developer, logs: widget.logs)), icon: const CampusIcon(CampusIcons.developer), label: const Text('开发者选项')),
        ]),
      ]),
    );
  }
}
