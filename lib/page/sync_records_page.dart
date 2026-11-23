import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/sync_record.dart';
import 'package:superxd/page/sync_merge_page.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 同步记录（人工决策见 domain/sync_record.dart）：每轮同步一张卡，从新到旧，写自动还是手动、什么时候与一句概括；点开看这一轮改了什么。
// 系统通知「新出了 2 门成绩」点开也到这里。
class SyncRecordsPage extends StatefulWidget {
  const SyncRecordsPage({super.key, required this.gateway, this.autoSync, this.isAccountCurrent});
  final CampusGateway gateway;
  final AutoSync? autoSync;
  final bool Function()? isAccountCurrent;

  @override
  State<SyncRecordsPage> createState() => _SyncRecordsPageState();
}

class _SyncRecordsPageState extends State<SyncRecordsPage> {
  GatewayResult<List<SyncRecord>>? _records;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final records = await widget.gateway.readSyncRecords();
    if (mounted && (widget.isAccountCurrent?.call() ?? true)) setState(() => _records = records);
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final records = _records;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('同步记录'),
      ),
      body: CampusScrollFade(child: SafeArea(bottom: false, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: switch (records) {
        null => const CampusLoading(label: '正在读取'),
        GatewayResult(ok: false, :final error) => CampusLoadError(message: error?.message ?? '读取失败', onRetry: _load),
        GatewayResult(:final data) when data == null || data.isEmpty => Center(child: Text('还没有同步记录', style: secondary)),
        GatewayResult(:final data) => ListView(padding: campusScrollPadding(context, const EdgeInsets.all(16)), children: [
          for (final record in data!)
            CampusSurface(
              margin: const EdgeInsets.only(bottom: 12),
              onTap: () async {
                await Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => SyncRecordPage(gateway: widget.gateway, autoSync: widget.autoSync, record: record)));
                if (mounted) await _load();
              },
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DotSeparatedText('${record.trigger == SyncTrigger.auto ? '自动' : '手动'} · ${formatCampusRelative(record.at.toIso8601String())}', style: secondary),
                  const SizedBox(height: 4),
                  Text(syncRecordHeadline(record), style: TextStyle(fontSize: 16, color: palette.onSurface)),
                ])),
                const CampusIcon(CampusIcons.next),
              ]),
            ),
        ]),
      })))),
    );
  }
}

// 一轮同步的详情：每类变化一张卡，列出哪几门课；课表的变化可以撤回（恢复同步前那一版，存成新版本），等你来选的可以去处理，成绩可以去看。
class SyncRecordPage extends StatelessWidget {
  const SyncRecordPage({super.key, required this.gateway, required this.record, this.autoSync});
  final CampusGateway gateway;
  final SyncRecord record;
  final AutoSync? autoSync;

  static TermRef _term(SyncChange change) {
    final split = change.termKey.lastIndexOf('-');
    return TermRef(xn: change.termKey.substring(0, split), xq: change.termKey.substring(split + 1), label: change.termLabel);
  }

  Future<void> _undo(BuildContext context, ScheduleSyncChange change) async {
    final confirmed = await showCampusConfirm(context, title: '撤回这次的课表变化？', message: '课表恢复到这次同步前的样子，存成新版本，可在历史版本里再改回。', action: '撤回');
    if (!confirmed || !context.mounted) return;
    final term = _term(change);
    final restored = await showCampusWaiting(context, label: '正在撤回', operation: () async {
      final current = await gateway.readSchedule(ScheduleScope.term(term));
      return gateway.restoreScheduleRevision(term, change.before!, expectedRevisionId: current.data?.revisionId);
    });
    if (!context.mounted) return;
    if (!restored.ok) return showCampusNotice(context, restored.error?.message ?? '没有撤回，请重试');
    showCampusToast(context, '已撤回');
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final autoSync = this.autoSync;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text('${record.trigger == SyncTrigger.auto ? '自动' : '手动'}同步'),
      ),
      body: CampusScrollFade(child: SafeArea(bottom: false, child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListView(padding: campusScrollPadding(context, const EdgeInsets.all(16)), children: [
        Text(formatCampusRelative(record.at.toIso8601String()), style: secondary),
        const SizedBox(height: 12),
        if (record.changes.isEmpty && record.failures.isEmpty && record.same.isEmpty) Text(syncRecordHeadline(record), style: TextStyle(fontSize: CampusFontSize.body, color: palette.onSurface)),
        for (final change in record.changes)
          CampusSurface(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DotSeparatedText(syncChangeLine(change), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
              if (syncChangeNames(change) case final names when names.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final group in names.split('；')) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(group, style: TextStyle(fontSize: 14, color: palette.onSurface))),
              ],
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (change case ScheduleSyncChange(held: false, :final before?) when before.isNotEmpty)
                  OutlinedButton.icon(onPressed: () => _undo(context, change), icon: const CampusIcon(CampusIcons.undo), label: const Text('撤回这次的变化')),
                if (change case ScheduleSyncChange(held: true) when autoSync != null)
                  if (autoSync.held.where((held) => held.term.key == change.termKey).firstOrNull case final held?)
                    FilledButton.icon(onPressed: () => showHeldScheduleSync(context, autoSync: autoSync, gateway: gateway, held: held), icon: const CampusIcon(CampusIcons.pendingSync), label: const Text('去处理')),
                if (change is ScheduleSyncChange) OutlinedButton.icon(onPressed: () => context.push('/schedule'), icon: const CampusIcon(CampusIcons.todaySelected), label: const Text('查看课表')),
                if (change is GradeSyncChange) OutlinedButton.icon(onPressed: () => context.push('/grades'), icon: const CampusIcon(CampusIcons.grades), label: const Text('查看成绩')),
              ]),
            ]),
          ),
        // 比对过、和上次一样的几项逐项写出（11-19 用户：只写「没有变化」看不出查了什么）。
        if (record.same.isNotEmpty)
          CampusSurface(margin: const EdgeInsets.only(bottom: 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('和上次一样', style: TextStyle(fontSize: CampusFontSize.body, fontWeight: FontWeight.w600, color: palette.onSurface)),
            const SizedBox(height: CampusGap.small),
            for (final item in record.same) Padding(padding: const EdgeInsets.only(bottom: CampusGap.tight), child: DotSeparatedText(item, style: TextStyle(fontSize: CampusFontSize.secondary, color: palette.onSurface))),
          ])),
        if (record.failures.isNotEmpty)
          CampusSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('没有同步完', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
            const SizedBox(height: 8),
            for (final failure in record.failures) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(failure, style: TextStyle(fontSize: 14, color: palette.onSurface))),
          ])),
      ]))))),
    );
  }
}
