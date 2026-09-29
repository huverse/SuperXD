import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_editor_page.dart';
import 'package:superxd/page/schedule_history_page.dart';
import 'package:superxd/domain/campus_log.dart';

class ScheduleEditorPage extends StatefulWidget {
  const ScheduleEditorPage({
    super.key,
    required this.gateway,
    required this.term,
    this.courseId,
    this.slot,
    this.selectedWeek,
  });
  final CampusGateway gateway;
  final TermRef term;
  final String? courseId;
  final CourseMeeting? slot;
  final int? selectedWeek;
  @override
  State<ScheduleEditorPage> createState() => _ScheduleEditorPageState();
}

class _ScheduleEditorPageState extends State<ScheduleEditorPage> {
  ScheduleView? _view;
  List<BellPeriod> _bells = [];
  bool _loading = true;
  bool _busy = false;
  bool _changed = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load(openCourse: true);
  }

  Future<void> _load({bool openCourse = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.gateway.readSchedule(
        ScheduleScope.term(widget.term),
      );
      final bells = await widget.gateway.readBells(widget.term);
      if (!mounted) return;
      setState(() {
        _view = result.data;
        _bells = bells.data?.periods ?? [];
        _loading = false;
        _error = result.ok ? null : result.error?.message;
      });
      if (openCourse && _view != null) {
        final course = _view!.courses
            .where((course) => courseKey(course) == widget.courseId)
            .firstOrNull;
        if (course != null || widget.courseId == null && widget.slot != null) {
          await _edit(course, widget.slot);
        }
      }
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=load error=$error\n$stack');
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '无法读取本地课表，请重试';
        });
      }
    }
  }

  Future<String?> _save(
    List<CourseRecord> courses,
    String summary,
    String? expected,
  ) async {
    final result = await widget.gateway.saveScheduleRevision(
      widget.term,
      courses,
      summary,
      expectedRevisionId: expected,
    );
    if (!result.ok) return result.error?.message ?? '保存失败，未更改课表';
    _changed = _changed || result.data!.id != expected;
    await _load();
    return null;
  }

  Future<void> _edit([CourseRecord? course, CourseMeeting? slot]) async {
    if (_busy || _view == null) return;
    final base = _view!;
    setState(() => _busy = true);
    try {
      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => CourseEditorPage(
            course: course,
            slot: slot,
            courses: base.courses,
            bells: _bells,
            selectedWeek: widget.selectedWeek,
            onSave: (edited) async {
              final courses = base.courses.map((item) => item.copy()).toList();
              final index = course == null
                  ? -1
                  : courses.indexWhere(
                      (item) => courseKey(item) == courseKey(course),
                    );
              final removing =
                  course != null &&
                  course.meetings.isNotEmpty &&
                  edited.meetings.isEmpty;
              if (removing) {
                courses.removeAt(index);
              } else if (index < 0) {
                courses.add(edited);
              } else {
                courses[index] = edited;
              }
              return _save(
                courses,
                '${removing
                    ? '删除'
                    : course == null
                    ? '新增'
                    : '修改'}课程：${edited.courseName}',
                base.revisionId,
              );
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(CourseRecord course) async {
    if (_busy || _view == null) return;
    final base = _view!;
    final scope = await showCampusDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('删除：${course.courseName}'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'course'),
            child: const Text('整门课程（所有时段和周次）'),
          ),
          if (course.meetings.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'meeting'),
              child: const Text('某个重复时段'),
            ),
          if (course.meetings.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'once'),
              child: const Text('某周的一次课程'),
            ),
        ],
      ),
    );
    if (!mounted || scope == null) return;
    CourseRecord? replacement;
    var label = '整门课程及所有上课时段';
    if (scope != 'course') {
      final index = await showCampusDialog<int>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('选择时段'),
          children: [
            for (var index = 0; index < course.meetings.length; index++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, index),
                child: Text(meetingLabel(course.meetings[index])),
              ),
          ],
        ),
      );
      if (!mounted || index == null) return;
      final meeting = course.meetings[index];
      final week = scope == 'once'
          ? await chooseMeetingWeek(
              context,
              meeting.weeks,
              preferred: widget.selectedWeek,
            )
          : null;
      if (!mounted || (scope == 'once' && week == null)) return;
      replacement = removeMeeting(course, index, week: week);
      label = week == null
          ? meetingLabel(meeting)
          : '第$week周 · 周${weekdayLabel(meeting.weekday)} 第${meeting.periodStart}–${meeting.periodEnd}节';
    }
    if (!await showCampusConfirm(
      context,
      title: '确认删除？',
      message: '${course.courseName}\n$label\n\n会保存新版本，可撤销或在历史版本中恢复。',
      action: '删除',
    )) {
      return;
    }
    if (!mounted) return;
    final courses = base.courses.map((item) => item.copy()).toList();
    final index = courses.indexWhere(
      (item) => courseKey(item) == courseKey(course),
    );
    if (replacement == null) {
      courses.removeAt(index);
    } else {
      courses[index] = replacement;
    }
    await _commitDeletion(base, courses, '删除：${course.courseName} · $label');
  }

  Future<void> _commitDeletion(
    ScheduleView base,
    List<CourseRecord> courses,
    String summary,
  ) async {
    setState(() => _busy = true);
    try {
      final result = await showCampusWaiting(context, label: '正在保存课程变更', operation: () => widget.gateway.saveScheduleRevision(
        widget.term,
        courses,
        summary,
        expectedRevisionId: base.revisionId,
      ));
      if (!mounted) return;
      if (!result.ok) {
        setState(() => _error = result.error?.message ?? '删除失败');
        return;
      }
      _changed = true;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已保存删除记录'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              try {
                final error = await showCampusWaiting(context, label: '正在撤销课程变更', operation: () => _save(
                  base.courses,
                  '撤销：$summary',
                  result.data!.id,
                ));
                if (mounted && error != null) setState(() => _error = error);
              } catch (error, stack) {
                campusLog('[ScheduleEditor] action=undo error=$error\n$stack');
                if (mounted) setState(() => _error = '撤销未完成，请在历史版本中预览恢复');
              }
            },
          ),
        ),
      );
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=delete error=$error\n$stack');
      if (mounted) setState(() => _error = '删除未完成，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    final base = _view!;
    if (!await showCampusConfirm(
      context,
      title: '清空本学期课程？',
      message: '将移除${base.courses.length}门课程并保存空课表版本。学期、成绩、开学日和作息不变，可在保留的历史版本内恢复。',
      action: '清空课程',
    )) {
      return;
    }
    if (mounted) await _commitDeletion(base, [], '清空本学期课程');
  }

  Future<void> _history() async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            ScheduleHistoryPage(gateway: widget.gateway, term: widget.term),
      ),
    );
    if (changed == true) _changed = true;
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) {},
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          icon: const CampusIcon(CampusIcons.back),
        ),
        title: const Text('管理课程'),
        actions: [
          IconButton(
            tooltip: '历史版本',
            onPressed: _busy || _loading ? null : _history,
            icon: const CampusIcon(CampusIcons.history),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && _view == null
            ? const Center(child: CampusLoading(label: '正在读取课程'))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_loading) const CampusLoading(label: '正在更新课程', inline: true),
                  Text(
                    widget.term.label.isEmpty
                        ? widget.term.key
                        : widget.term.label,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '每学期一张课表 · 最多保留100个版本',
                    style: TextStyle(fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : () => _load(),
                      child: const Text('重新读取'),
                    ),
                  ],
                  if (_view != null) ...[
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _edit(),
                      icon: const CampusIcon(CampusIcons.add),
                      label: const Text('新增课程'),
                    ),
                    if (_view!.courses.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Text(
                          _view!.revisionId == null
                              ? '尚未建立课表，可以直接手工添加课程。'
                              : '当前课表没有课程，可新增或从历史版本恢复。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    if (_view!.revisionId == null)
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  final error = await showCampusWaiting(context, label: '正在建立课表', operation: () => _save([], '建立空课表', null));
                                  if (mounted) setState(() => _error = error);
                                } catch (error, stack) {
                                  campusLog(
                                    '[ScheduleEditor] action=create error=$error\n$stack',
                                  );
                                  if (mounted) {
                                    setState(() => _error = '建立课表失败');
                                  }
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        child: const Text('建立空课表'),
                      ),
                    for (final course in _view!.courses)
                      CampusSurface(padding: EdgeInsets.zero, margin: const EdgeInsets.symmetric(vertical: 8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                course.courseName,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (course.teacherName.isNotEmpty)
                                Text(course.teacherName),
                              if (course.meetings.isEmpty) const Text('暂无上课时间'),
                              for (final meeting in course.meetings)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    meetingLabel(meeting),
                                    style: const TextStyle(
                                      fontSize: 14,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _edit(course),
                                    child: const Text('编辑'),
                                  ),
                                  TextButton(
                                    onPressed: _busy
                                        ? null
                                        : () => _delete(course),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_view!.courses.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: OutlinedButton(
                          onPressed: _busy ? null : _clear,
                          child: const Text('清空本学期课程'),
                        ),
                      ),
                  ],
                ],
              ),
      ),
    ),
  );
}
