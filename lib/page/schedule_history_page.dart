import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/campus_log.dart';

enum _Filter { all, mine, edu }

// [人工决策-2026-10-19 16:08:42] 历史版本按时间线排（用户选定，同 Google 文档、飞书的版本历史，另加类型筛选）：
// 按日期分组，每条用图标分「教务同步 / 我的修改 / 恢复」，恢复写「恢复到某时的样子」而不是版本序号，当前在用的标「当前」；
// 顶部分段「全部 / 我的修改 / 教务同步」，恢复算我的修改。点开写「恢复到这个版本，和现在相比」，按会加回、会删掉、会改回分组列出。
class ScheduleHistoryPage extends StatefulWidget {
  const ScheduleHistoryPage({
    super.key,
    required this.gateway,
    required this.term,
  });
  final CampusGateway gateway;
  final TermRef term;
  @override
  State<ScheduleHistoryPage> createState() => _ScheduleHistoryPageState();
}

class _ScheduleHistoryPageState extends State<ScheduleHistoryPage> {
  final List<RevisionView> _rows = [];
  var _filter = _Filter.all;
  bool _loading = false;
  bool _more = true;
  bool _changed = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.gateway.listScheduleRevisions(
        widget.term,
        beforeSequence: refresh ? null : _rows.lastOrNull?.sequence,
      );
      if (!mounted) return;
      setState(() {
        if (result.ok) {
          if (refresh) _rows.clear();
          final ids = _rows.map((row) => row.id).toSet();
          _rows.addAll(result.data!.where((row) => !ids.contains(row.id)));
          _more =
              result.data!.length == 20 && _rows.length < scheduleRevisionLimit;
        } else {
          _error = result.error?.message ?? '历史读取失败';
        }
      });
    } catch (error, stack) {
      campusLog('[ScheduleHistory] action=list errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '无法读取历史版本，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // 恢复写恢复到哪个时刻：旧版本存的说明是「恢复版本 #序号」，被恢复的那版还在列表里就换成它的时刻。
  String _title(RevisionView row) {
    if (row.operation != 'restore') return row.summary;
    final target = _rows.where((item) => item.id == row.restoredFromId).firstOrNull;
    if (target != null) return '恢复到 ${formatCampusMoment(target.createdAt)} 的样子';
    return row.summary.startsWith('恢复版本 #') ? '恢复到之前的一个版本' : row.summary;
  }

  Future<void> _preview(RevisionView row) async {
    final restored = await Navigator.push<bool>(
      context,
      CampusPageRoute(
        builder: (context) => _RevisionPreview(
          gateway: widget.gateway,
          term: widget.term,
          revision: row,
          title: _title(row),
        ),
      ),
    );
    if (restored == true) _changed = true;
    if (mounted) await _load(refresh: true);
    if (mounted && restored == true) showCampusToast(context, '已恢复，原来的课表也留在历史里');
  }

  String _dayLabel(String createdAt) {
    final day = formatCampusTimestamp(createdAt).substring(0, 10);
    if (day == campusToday()) return '今天';
    if (day == formatCampusDate(campusNow().subtract(const Duration(days: 1)))) return '昨天';
    final parts = day.split('-').map(int.parse).toList();
    return '${day.startsWith(campusToday().substring(0, 4)) ? '' : '${parts[0]}年'}${parts[1]}月${parts[2]}日';
  }

  Widget _row(RevisionView row, CampusPalette palette) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    onTap: _loading ? null : () => _preview(row),
    leading: CampusIcon(_revisionIcon(row), color: palette.onSurfaceVariant),
    title: Text(_title(row)),
    subtitle: Text(formatCampusTimestamp(row.createdAt).substring(11, 16), style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      if (row.current) Text('当前', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
      const SizedBox(width: 4),
      const CampusIcon(CampusIcons.next),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final rows = _rows.where((row) => switch (_filter) {
      _Filter.all => true,
      _Filter.mine => row.source == 'user',
      _Filter.edu => row.source == 'edu',
    }).toList();
    // 按校园日分组，同一天的放在一张卡里（同成绩页的分组列表）。
    final days = <String, List<RevisionView>>{};
    for (final row in rows) {
      days.putIfAbsent(_dayLabel(row.createdAt), () => []).add(row);
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回',
          onPressed: () => Navigator.pop(context, _changed),
          icon: const CampusIcon(CampusIcons.back),
        ),
        title: const Text('历史版本'),
      ),
      body: CampusScrollFade(child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            CampusSegmented<_Filter>(
              values: _Filter.values,
              selected: _filter,
              label: (filter) => switch (filter) {
                _Filter.all => '全部',
                _Filter.mine => '我的修改',
                _Filter.edu => '教务同步',
              },
              onSelected: (filter) => setState(() => _filter = filter),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              TextButton.icon(
                onPressed: _loading ? null : () => _load(refresh: true),
                icon: const CampusIcon(CampusIcons.sync),
                label: const Text('重试'),
              ),
            ],
            for (final MapEntry(key: day, value: dayRows) in days.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
                child: Text(day, style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ),
              CampusSurface(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(children: [for (final row in dayRows) _row(row, palette)]),
              ),
            ],
            if (rows.isEmpty && !_loading && _error == null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_rows.isEmpty ? '还没有历史版本' : '这一类还没有版本', textAlign: TextAlign.center),
              ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CampusLoading(label: '正在读取历史版本'))
            else if (_more && _rows.isNotEmpty)
              OutlinedButton.icon(onPressed: _load, icon: const CampusIcon(CampusIcons.expand), label: const Text('加载更早版本')),
          ],
        ),
      )),
    );
  }
}

IconData _revisionIcon(RevisionView row) => row.source == 'edu'
    ? CampusIcons.sync
    : row.operation == 'restore'
    ? CampusIcons.restore
    : CampusIcons.edit;

class _RevisionPreview extends StatefulWidget {
  const _RevisionPreview({
    required this.gateway,
    required this.term,
    required this.revision,
    required this.title,
  });
  final CampusGateway gateway;
  final TermRef term;
  final RevisionView revision;
  final String title;
  @override
  State<_RevisionPreview> createState() => _RevisionPreviewState();
}

class _RevisionPreviewState extends State<_RevisionPreview> {
  ScheduleRevision? _target;
  ScheduleView? _current;
  List<CourseChange> _changes = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final target = await widget.gateway.readScheduleRevision(
        widget.term,
        widget.revision.id,
      );
      final current = await widget.gateway.readSchedule(
        ScheduleScope.term(widget.term),
      );
      if (!mounted) return;
      setState(() {
        _target = target.data;
        _current = current.data;
        _error = !target.ok
            ? target.error?.message
            : !current.ok
            ? current.error?.message
            : null;
        _changes = _target == null || _current == null
            ? []
            : scheduleChanges(_current!.courses, _target!.courses);
      });
    } catch (error, stack) {
      campusLog('[ScheduleHistory] action=preview errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '无法读取版本详情');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _restore() async {
    if (_saving || _target == null || _current == null) return;
    if (!await showCampusConfirm(
      context,
      title: '恢复到这个版本？',
      message: '上面列出的变化会生效，并存成一个新版本；现在的课表也留在历史里，随时能再恢复。开学日和作息不变。',
      action: '恢复',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final result = await widget.gateway.restoreScheduleRevision(
        widget.term,
        _target!.id,
        expectedRevisionId: _current!.revisionId,
      );
      if (!mounted) return;
      if (result.ok) {
        Navigator.pop(context, true);
      } else {
        setState(() {
          _error = result.error?.message ?? '恢复未完成';
          _current = null;
        });
      }
    } catch (error, stack) {
      campusLog('[ScheduleHistory] action=restore errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '恢复未完成，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // 现在（before）恢复后变成什么（after）：改了的字段写「旧 → 新」，时段写会去掉、会加上的那几条。
  List<String> _changedLines(CourseRecord before, CourseRecord after) {
    String orEmpty(String value) => value.isEmpty ? '未填' : value;
    final beforeMeetings = before.meetings.map(meetingLabel).toSet();
    final afterMeetings = after.meetings.map(meetingLabel).toSet();
    return [
      if (before.courseName != after.courseName) '课程名称：${before.courseName} → ${after.courseName}',
      if (before.teacherName != after.teacherName) '教师：${orEmpty(before.teacherName)} → ${orEmpty(after.teacherName)}',
      if (before.credit != after.credit) '学分：${before.credit ?? '未填'} → ${after.credit ?? '未填'}',
      for (final label in beforeMeetings.difference(afterMeetings)) '去掉 $label',
      for (final label in afterMeetings.difference(beforeMeetings)) '加上 $label',
    ];
  }

  Widget _changeCard(CourseChange change, TextStyle secondary) {
    final course = (change.after ?? change.before)!;
    final lines = change.kind == '修改'
        ? _changedLines(change.before!, change.after!)
        : [if (course.teacherName.isNotEmpty) course.teacherName, for (final meeting in course.meetings) meetingLabel(meeting)];
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(change.before?.courseName ?? course.courseName, style: Theme.of(context).textTheme.titleMedium),
          for (final line in lines)
            Padding(padding: const EdgeInsets.only(top: 4), child: DotSeparatedText(line, style: secondary.copyWith(height: 1.5))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final revision = widget.revision;
    final kind = revision.source == 'edu' ? '教务同步' : revision.operation == 'restore' ? '恢复' : '我的修改';
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(leading: IconButton(tooltip: '返回', onPressed: _saving ? null : () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)), title: const Text('版本详情')),
        body: CampusScrollFade(child: SafeArea(
          child: _loading
              ? const Center(child: CampusLoading(label: '正在读取历史版本'))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Row(children: [
                      CampusIcon(_revisionIcon(revision), color: palette.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.titleLarge)),
                    ]),
                    const SizedBox(height: 4),
                    DotSeparatedText('${formatCampusMoment(revision.createdAt)} · $kind${revision.current ? ' · 当前' : ''}', style: secondary),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(
                        _error!,
                        style: TextStyle(
                          fontSize: 14,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _saving ? null : _load,
                        icon: const CampusIcon(CampusIcons.sync),
                        label: const Text('重试'),
                      ),
                    ],
                    if (_target != null && _current != null) ...[
                      if (_changes.isEmpty)
                        Text(revision.current ? '这就是现在在用的课表。' : '和现在的课表一样，不用恢复。', style: secondary)
                      else ...[
                        Text('恢复到这个版本，和现在相比：', style: Theme.of(context).textTheme.titleMedium),
                        for (final (kind, title) in const [('新增', '会加回'), ('删除', '会删掉'), ('修改', '会改回')])
                          if (_changes.where((change) => change.kind == kind).toList() case final changes when changes.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
                              child: Text('$title ${changes.length} 门', style: secondary),
                            ),
                            for (final change in changes) _changeCard(change, secondary),
                          ],
                        const SizedBox(height: 16),
                        FilledButton(
                          style: campusProminent,
                          onPressed: _saving ? null : _restore,
                          child: CampusBusyContent(busy: _saving, label: '恢复到这个版本', busyLabel: '恢复中', icon: const CampusIcon(CampusIcons.restore)),
                        ),
                      ],
                    ],
                  ],
                ),
        )),
      ),
    );
  }
}
