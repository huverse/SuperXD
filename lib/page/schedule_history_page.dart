import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/domain/campus_log.dart';

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

  Future<void> _preview(RevisionView row) async {
    final restored = await Navigator.push<bool>(
      context,
      CampusPageRoute(
        builder: (context) => _RevisionPreview(
          gateway: widget.gateway,
          term: widget.term,
          revision: row,
        ),
      ),
    );
    if (restored == true) _changed = true;
    if (mounted) await _load(refresh: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
          // 恢复的影响（新建本地版本、不改开学日与作息、最多 100 版）在恢复确认里说明，列表上方不重复。
          if (_error != null) ...[
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
          for (final row in _rows)
            CampusSurface(padding: EdgeInsets.zero, margin: const EdgeInsets.symmetric(vertical: 8),
              child: ListTile(
                onTap: _loading ? null : () => _preview(row),
                title: Text(row.summary),
                subtitle: Text(
                  '${row.current ? '当前使用 · ' : ''}${row.source == 'edu'
                      ? '教务同步'
                      : row.operation == 'restore'
                      ? '人工恢复'
                      : '本地编辑'}\n${formatCampusTimestamp(row.createdAt)}',
                ),
                isThreeLine: true,
                trailing: const CampusIcon(CampusIcons.next),
              ),
            ),
          if (_rows.isEmpty && !_loading && _error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('还没有历史版本', textAlign: TextAlign.center),
            ),
          if (_loading)
            const Center(child: CampusLoading(label: '正在读取历史版本'))
          else if (_more && _rows.isNotEmpty)
            OutlinedButton.icon(onPressed: _load, icon: const CampusIcon(CampusIcons.expand), label: const Text('加载更早版本')),
        ],
      ),
    )),
  );
}

class _RevisionPreview extends StatefulWidget {
  const _RevisionPreview({
    required this.gateway,
    required this.term,
    required this.revision,
  });
  final CampusGateway gateway;
  final TermRef term;
  final RevisionView revision;
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
      title: '恢复这个版本？',
      message: '将应用下方预览的${_changes.length}项课程变化并新建本地版本，不改变开学日和作息。每学期最多保留100版。',
      action: '确认恢复',
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

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Scaffold(
      appBar: AppBar(leading: IconButton(tooltip: '返回', onPressed: _saving ? null : () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)), title: const Text('版本预览')),
      body: CampusScrollFade(child: SafeArea(
        child: _loading
            ? const Center(child: CampusLoading(label: '正在读取历史版本'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    widget.revision.summary,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(formatCampusTimestamp(widget.revision.createdAt)),
                  const SizedBox(height: 16),
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
                    Text(
                      '恢复后 ${_target!.courses.length} 门课程 · ${_changes.length} 项变化',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    if (_changes.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('此版本与当前课程内容相同，无需恢复。'),
                      ),
                    for (final change in _changes)
                      CampusSurface(padding: EdgeInsets.zero, margin: const EdgeInsets.symmetric(vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${change.kind} · ${(change.after ?? change.before)!.courseName}',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (change.fields.isNotEmpty)
                                Text('变化：${change.fields.join('、')}'),
                              if (change.before != null)
                                _courseDetails('当前', change.before!),
                              if (change.after != null)
                                _courseDetails('恢复后', change.after!),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    FilledButton(
                      style: campusProminent,
                      onPressed: _saving || _changes.isEmpty ? null : _restore,
                      child: CampusBusyContent(busy: _saving, label: '恢复此版本', busyLabel: '恢复中', icon: const CampusIcon(CampusIcons.restore)),
                    ),
                  ],
                ],
              ),
      )),
    ),
  );
  Widget _courseDetails(String title, CourseRecord course) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$title：${course.courseName} · ${course.teacherName.isEmpty ? '未填教师' : course.teacherName} · 学分${course.credit ?? '—'}',
          style: const TextStyle(fontSize: 14),
        ),
        for (final meeting in course.meetings)
          Text(
            meetingLabel(meeting),
            style: const TextStyle(fontSize: 14, height: 1.5),
          ),
      ],
    ),
  );
}
