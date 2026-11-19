import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/sync_record.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/academic_catalog.dart';
import 'package:superxd/page/auto_sync_dialog.dart';
import 'package:superxd/page/campus_sync_dialogs.dart';
import 'package:superxd/page/sync_merge_page.dart';
import 'package:superxd/page/sync_selection_dialog.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/curve_geometry.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// [人工决策-2026-11-16 13:35:18] 学业（用户要求把服务页的课表、成绩合成一个教务模块，名字选推荐的「学业」，以后教务相关的都放这里；
// 取代 09-27「课表、成绩分开列」）：顶部写当前学期、第几周与上次同步；有等你来选的教务课表时一组「待处理」；
// 课表、成绩两个入口；同步（同今天页的同步范围，原地显示进度）、自动同步、同步记录（人工决策见 domain/sync_record.dart）。
class AcademicPage extends StatefulWidget {
  const AcademicPage({super.key, required this.gateway, this.autoSync, this.onSessionExpired, this.isAccountCurrent});
  final CampusGateway gateway;
  // 为空时没有自动同步与待处理。
  final AutoSync? autoSync;
  final Future<void> Function()? onSessionExpired;
  final bool Function()? isAccountCurrent;

  @override
  State<AcademicPage> createState() => _AcademicPageState();
}

class _AcademicPageState extends State<AcademicPage> {
  late final _sync = CampusSync(widget.gateway);
  TermRef? _term;
  int? _week;
  SyncRecord? _latest;
  bool _syncing = false;
  CampusSyncProgress? _progress;

  bool get _current => mounted && (widget.isAccountCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.autoSync?.addListener(_onAutoSync);
    unawaited(_load());
  }

  // 前台的自动同步记下结果时重读最近一条同步记录与当前学期（11-19 用户选定：同步完马上看得到）。
  void _onAutoSync() {
    if (_current && !_syncing) unawaited(_load());
  }

  @override
  void dispose() {
    widget.autoSync?.removeListener(_onAutoSync);
    super.dispose();
  }

  // 只读本机：当前学期（学期列表的第一项）、开学日算第几周、最近一条同步记录。
  Future<void> _load() async {
    final terms = await widget.gateway.listTerms();
    final term = terms.data?.firstOrNull;
    final start = term == null ? null : (await widget.gateway.readSchedule(ScheduleScope.term(term))).data?.termStartDate;
    final records = await widget.gateway.readSyncRecords();
    if (!_current) return;
    final week = start == null ? null : weekIndex(start, campusToday());
    setState(() {
      _term = term;
      _week = week != null && week >= 1 ? week : null;
      _latest = records.data?.firstOrNull;
    });
  }

  Future<void> _start() async {
    if (_syncing) return;
    final selection = await chooseSyncSelection(context, widget.gateway, autoSync: widget.autoSync);
    if (selection == null || !mounted) return;
    setState(() => _syncing = true);
    try {
      final report = await _sync.run(
        contents: selection.contents,
        years: selection.years,
        isActive: () => _current,
        // 和本地改过的课表冲突：同今天页，打开合并页逐项选，退出同保留本地；等合并页退出那一帧画完再交回，不被当成中途离开。
        resolveSchedule: (term, plan, courses) async {
          if (!mounted) return const KeepLocal(remember: true);
          final resolution = await resolveScheduleSync(context, gateway: widget.gateway, term: term, plan: plan, edu: courses);
          await WidgetsBinding.instance.endOfFrame;
          return resolution;
        },
        chooseBells: (target, source) async => mounted ? await chooseBellsSource(context, target, source) : BellsChoice.cancel,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (report.busy) {
        showCampusToast(context, '正在同步，稍后再试');
        return;
      }
      final again = await showCampusSyncReport(context, report);
      if (!mounted) return;
      if (report.sessionExpired) {
        await widget.onSessionExpired?.call();
      } else if (again) {
        await _start();
      }
    } catch (error, stack) {
      campusLog('[Academic] action=sync errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '同步中断，已保存的数据保留，请重试。');
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _open(String location) async {
    await context.push(location);
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    const rowPadding = EdgeInsets.symmetric(horizontal: 20);
    final autoSync = widget.autoSync;
    final latest = _latest;
    // 行尾的短状态最多占行宽的四成：ListTile 给行尾的宽度不设上限，长了会把标题挤成一字一行（11-18 用户截图）。
    Widget trailing(String text) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (text.isNotEmpty) Flexible(child: Text(text, style: secondary, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 4),
        const CampusIcon(CampusIcons.next),
      ]),
    );
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('学业'),
      ),
      body: CampusScrollFade(child: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: ListenableBuilder(
        listenable: Listenable.merge([?autoSync]),
        builder: (context, _) => ListView(padding: const EdgeInsets.all(16), children: [
          CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // 学期名在「学年」后切开换行（DotSeparatedText），窄屏大字号不折出孤字「期」。
            DotSeparatedText(_term == null ? '还没有学期' : _term!.label.isEmpty ? _term!.key : _term!.label, style: TextStyle(fontSize: CampusFontSize.title, fontWeight: FontWeight.w600, color: palette.onSurface)),
            const SizedBox(height: 4),
            DotSeparatedText([
              if (_week case final week?) '第 $week 周',
              if (latest != null) '${latest.trigger == SyncTrigger.auto ? '自动' : '手动'}同步于${formatCampusRelative(latest.at.toIso8601String())}' else '还没有同步记录',
            ].join(' · '), style: secondary),
          ])),
          // 等你来选的教务课表（自动同步留下的）：随时打开，同打扰时机里弹的那一个。
          if (autoSync != null && autoSync.held.isNotEmpty) ...[
            const SizedBox(height: 16),
            CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
              for (final held in autoSync.held)
                ListTile(
                  contentPadding: rowPadding,
                  leading: CampusIcon(CampusIcons.pendingSync, color: palette.primary),
                  // 「课表 · 学期」按项换行，学期名整项不拆，不折出孤字。
                  title: DotSeparatedText('课表 · ${held.term.label.isEmpty ? held.term.key : held.term.label}', style: TextStyle(fontSize: 16, color: palette.onSurface)),
                  subtitle: Text('教务有改动，和你改过的不一样', style: secondary),
                  trailing: const CampusIcon(CampusIcons.next),
                  onTap: () async {
                    await showHeldScheduleSync(context, autoSync: autoSync, gateway: widget.gateway, held: held);
                    if (mounted) await _load();
                  },
                ),
            ])),
          ],
          const SizedBox(height: 16),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            // 各项数据的入口来自学业功能登记（academic_catalog.dart）。
            for (final feature in academicFeatures)
              ListTile(contentPadding: rowPadding, leading: CampusIcon(feature.icon), title: Text(feature.title), trailing: const CampusIcon(CampusIcons.next), onTap: () => _open(feature.path)),
          ])),
          const SizedBox(height: 16),
          CampusSurface(padding: const EdgeInsets.symmetric(vertical: 8), child: Column(children: [
            // 同步：原地显示进行到哪一步，同步中不能再点。这是个动作、不推入新页，行尾不画「›」（同 iOS、鸿蒙设置里的动作行），
            // 同步中行尾是较长同步用的利萨茹曲线（设计语言第 8 节）。
            ListTile(
              contentPadding: rowPadding,
              leading: const CampusIcon(CampusIcons.sync),
              title: const Text('同步'),
              subtitle: _syncing ? Text(_progress?.label ?? '正在同步', style: secondary) : null,
              trailing: _syncing ? const CampusLoader(curve: CampusCurve.lissajous, size: 24) : null,
              onTap: _syncing ? null : _start,
            ),
            if (autoSync != null)
              ListTile(
                contentPadding: rowPadding,
                leading: const CampusIcon(CampusIcons.timer),
                title: const Text('自动同步'),
                trailing: trailing(autoSyncSummary(autoSync.view)),
                onTap: () async {
                  await showAutoSyncSettings(context, autoSync: autoSync, gateway: widget.gateway);
                  if (mounted) await _load();
                },
              ),
            ListTile(
              contentPadding: rowPadding,
              leading: const CampusIcon(CampusIcons.history),
              title: const Text('同步记录'),
              // 最近一次的概括可能很长（没同步完时带出错的原因），写在标题下面、最多两行，不放行尾。
              subtitle: latest == null ? null : Text(syncRecordHeadline(latest), maxLines: 2, overflow: TextOverflow.ellipsis, style: secondary),
              trailing: const CampusIcon(CampusIcons.next),
              onTap: () => _open('/academic/records'),
            ),
          ])),
        ]),
      ))))),
    );
  }
}
