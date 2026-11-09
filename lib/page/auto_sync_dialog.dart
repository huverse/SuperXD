import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 自动同步设置（人工决策见 domain/auto_sync.dart）：开关、间隔、学年与内容同手动同步的范围，点了就生效、存好才算；
// 最下面只读写上次的结果。从「同步范围」弹窗里打开，样子同课前提醒设置。
Future<void> showAutoSyncSettings(BuildContext context, {required AutoSync autoSync, required CampusGateway gateway}) =>
    showCampusDialog<void>(context: context, builder: (context) => _AutoSyncDialog(autoSync: autoSync, gateway: gateway));

// 设置里摘要一行（「同步范围」弹窗的入口用）。
String autoSyncSummary(AutoSyncView? view) {
  final setting = view?.setting;
  if (setting == null || !setting.enabled) return '未开启';
  return '${_intervalLabel(setting.interval)} · ${setting.years == null ? '当前学年' : '${setting.years!.length} 个学年'}';
}

String _intervalLabel(Duration interval) => switch (interval.inDays) {
  0 => '每 ${interval.inHours} 小时',
  1 => '每天',
  7 => '每周',
  final days => '每 $days 天',
};

class _AutoSyncDialog extends StatefulWidget {
  const _AutoSyncDialog({required this.autoSync, required this.gateway});
  final AutoSync autoSync;
  final CampusGateway gateway;
  @override
  State<_AutoSyncDialog> createState() => _AutoSyncDialogState();
}

class _AutoSyncDialogState extends State<_AutoSyncDialog> {
  List<String> _years = const [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.autoSync.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    widget.autoSync.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  // 学年读本机的学期列表，不联网；设置在登录后已读好，没读到时读一次。
  Future<void> _load() async {
    try {
      if (widget.autoSync.view == null) await widget.autoSync.accountChanged(signedIn: true);
      final terms = await widget.gateway.listTerms();
      if (!mounted) return;
      setState(() {
        _years = {for (final term in terms.data ?? const <TermRef>[]) term.xn}.toList()..sort((a, b) => b.compareTo(a));
        _loading = false;
      });
    } catch (error, stack) {
      campusLog('[AutoSyncSettings] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() { _loading = false; _error = '读取设置失败，请重试'; });
    }
  }

  Future<void> _save(AutoSyncSetting setting) async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final failed = await widget.autoSync.save(setting);
      if (mounted) setState(() => _error = failed);
    } catch (error, stack) {
      campusLog('[AutoSyncSettings] action=save errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '设置没有保存，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = widget.autoSync.view;
    final palette = CampusPalette.of(context);
    final note = TextStyle(color: palette.onSurfaceVariant, fontSize: 14);
    final heading = Theme.of(context).textTheme.titleMedium;
    final setting = view?.setting;
    return CampusGlassDialog(
      title: const Text('自动同步'),
      scrollable: true,
      content: SizedBox(
        width: 400,
        child: _loading || setting == null
            ? (_error == null ? const CampusLoading(label: '读取中', inline: true) : Text(_error!, style: note))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CampusSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('到时间自动同步'),
                    subtitle: const Text('联网时在后台进行'),
                    value: setting.enabled,
                    onChanged: _busy ? (_) {} : (value) => _save(setting.copyWith(enabled: value)),
                  ),
                  if (setting.enabled) ...[
                    const SizedBox(height: 8),
                    Text('间隔', style: heading),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final interval in autoSyncIntervals)
                        CampusGlassChip(
                          label: _intervalLabel(interval),
                          selected: setting.interval == interval,
                          onSelected: _busy ? null : (_) => _save(setting.copyWith(interval: interval)),
                        ),
                    ]),
                    const SizedBox(height: 16),
                    Text('学年', style: heading),
                    const SizedBox(height: 8),
                    // 「当前学年」跟着本机记的当前学期走，跨学年时自动换；选了具体学年就不再跟着换。
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      CampusGlassChip(
                        label: '当前学年',
                        selected: setting.years == null,
                        onSelected: _busy ? null : (_) => _save(setting.copyWith(years: () => null)),
                      ),
                      for (final year in _years)
                        CampusGlassChip(
                          label: '$year–${int.parse(year) + 1}',
                          selected: setting.years?.contains(year) ?? false,
                          onSelected: _busy
                              ? null
                              : (selected) {
                                  final years = {...?setting.years};
                                  selected ? years.add(year) : years.remove(year);
                                  _save(setting.copyWith(years: () => years.isEmpty ? null : years));
                                },
                        ),
                    ]),
                    const SizedBox(height: 16),
                    Text('内容', style: heading),
                    for (final content in SyncContent.values)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: setting.contents.contains(content),
                        title: Text(switch (content) { SyncContent.schedule => '课表', SyncContent.bells => '作息', SyncContent.grades => '成绩' }),
                        // 至少留一项：最后一项不让取消。
                        onChanged: _busy || (setting.contents.length == 1 && setting.contents.contains(content))
                            ? null
                            : (value) => _save(setting.copyWith(contents: value == true ? {...setting.contents, content} : ({...setting.contents}..remove(content)))),
                      ),
                    const SizedBox(height: 8),
                    Text('和你改过的课表不一样时不覆盖，会在合适的时候问你。', style: note),
                    // 后台自动重登（用户 11-09 允许）在开关处说清楚，同隐私政策第一节。
                    Text('开着记住账号时，登录过期会自动重新登录一次。', style: note),
                    if (defaultTargetPlatform == TargetPlatform.iOS) Text('iOS 由系统决定后台什么时候运行，可能晚于设定的间隔，打开应用时会补上。', style: note),
                    ..._status(view!.status, note),
                  ],
                  if (_busy) const CampusLoading(label: '正在保存', inline: true),
                  if (_error != null) Text(_error!, style: TextStyle(color: palette.danger, fontSize: 14)),
                ],
              ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('完成'))],
    );
  }

  // 上次的结果只读、不用主色。
  List<Widget> _status(AutoSyncStatus status, TextStyle note) {
    final attempt = status.lastAttemptAt;
    if (attempt == null) return const [];
    final success = status.lastSuccessAt;
    final line = switch (status.state) {
      AutoSyncState.ok => '上次自动同步：${formatCampusRelative(attempt.toUtc().toIso8601String())}',
      null => success == null ? null : '上次自动同步：${formatCampusRelative(success.toUtc().toIso8601String())}',
      _ => status.message,
    };
    return [if (line != null && line.isNotEmpty) ...[const SizedBox(height: 8), Text(line, style: note)]];
  }
}
