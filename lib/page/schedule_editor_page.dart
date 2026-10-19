import 'package:flutter/material.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_editor_page.dart';
import 'package:superxd/page/schedule_history_page.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/dot_separated_text.dart';

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
          // 从课表页进来：打开这个教学班所在的整门课，预填的时段带上这个教学班的老师。
          await _edit(
            course == null ? const [] : courseGroups(_view!.courses).firstWhere((group) => group.contains(course)),
            widget.slot == null ? null : CourseSlot(meeting: widget.slot!, teacher: course?.teacherName ?? '', origin: course == null ? null : courseKey(course)),
          );
        }
      }
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=load errorType=${error.runtimeType}\n$stack');
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

  // 一门课（同名的几个教学班）保存后的记录换掉原来那几条，放在原来第一条的位置，新增的放最后。
  List<CourseRecord> _replaceGroup(List<CourseRecord> courses, List<CourseRecord> group, List<CourseRecord> records) {
    final keys = {for (final course in group) courseKey(course)};
    final at = courses.indexWhere((course) => keys.contains(courseKey(course)));
    final rest = [for (final course in courses) if (!keys.contains(courseKey(course))) course.copy()];
    return rest..insertAll(at < 0 ? rest.length : at, records);
  }

  Future<void> _edit([List<CourseRecord> group = const [], CourseSlot? slot]) async {
    if (_busy || _view == null) return;
    final base = _view!;
    setState(() => _busy = true);
    try {
      await Navigator.push<bool>(
        context,
        CampusPageRoute(
          builder: (context) => CourseEditorPage(
            group: group,
            slot: slot,
            courses: base.courses,
            bells: _bells,
            selectedWeek: widget.selectedWeek,
            onSave: (records) => _save(
              _replaceGroup(base.courses, group, records),
              '${records.isEmpty
                  ? '删除'
                  : group.isEmpty
                  ? '新增'
                  : '修改'}课程：${records.firstOrNull?.courseName ?? group.first.courseName}',
              base.revisionId,
            ),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _courseMenu(BuildContext anchor, List<CourseRecord> group) async {
    final action = await showCampusMenu<String>(anchor, items: const [
      CampusMenuItem(value: 'delete', label: '删除', icon: CampusIcons.delete, destructive: true),
    ]);
    if (mounted && action == 'delete') await _delete(group);
  }

  Future<void> _delete(List<CourseRecord> group) async {
    if (_busy || _view == null) return;
    final base = _view!;
    final name = group.first.courseName;
    final slots = courseSlots(group);
    final scope = await showCampusDialog<String>(
      context: context,
      builder: (context) => CampusGlassDialog(
        title: Text('删除：$name'),
        options: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'course'),
            child: const Text('整门课程（所有时段和周次）'),
          ),
          if (slots.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'meeting'),
              child: const Text('某个重复时段'),
            ),
          if (slots.isNotEmpty)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'once'),
              child: const Text('某周的一次课程'),
            ),
        ],
      ),
    );
    if (!mounted || scope == null) return;
    var records = <CourseRecord>[];
    var label = '整门课程及所有上课时段';
    if (scope != 'course') {
      final index = await showCampusDialog<int>(
        context: context,
        builder: (context) => CampusGlassDialog(
          title: const Text('选择时段'),
          options: [
            for (var index = 0; index < slots.length; index++)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, index),
                child: Text(slotLabel(slots[index])),
              ),
          ],
        ),
      );
      if (!mounted || index == null) return;
      final meeting = slots[index].meeting;
      final week = scope == 'once'
          ? await chooseMeetingWeek(
              context,
              meeting.weeks,
              preferred: widget.selectedWeek,
            )
          : null;
      if (!mounted || (scope == 'once' && week == null)) return;
      // 只删时段不换老师，分回教学班时不会新建课程。
      records = regroupCourse(group, name: name, slots: removeSlot(slots, index, week: week), newLocalId: () => throw StateError('删除时段不新建课程'));
      label = week == null
          ? meetingLabel(meeting)
          : '第$week周 · 周${weekdayLabel(meeting.weekday)} 第${meeting.periodStart}–${meeting.periodEnd}节';
    }
    if (!await showCampusConfirm(
      context,
      title: '确认删除？',
      message: '$name\n$label\n\n会保存新版本，可撤销或在历史版本中恢复。',
      action: '删除', destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    await _commitDeletion(base, _replaceGroup(base.courses, group, records), '删除：$name · $label');
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
      showCampusToast(
        context,
        '已保存删除记录',
        action: '撤销',
        onAction: () async {
          try {
            final error = await showCampusWaiting(context, label: '正在撤销课程变更', operation: () => _save(
              base.courses,
              '撤销：$summary',
              result.data!.id,
            ));
            if (mounted && error != null) setState(() => _error = error);
          } catch (error, stack) {
            campusLog('[ScheduleEditor] action=undo errorType=${error.runtimeType}\n$stack');
            if (mounted) setState(() => _error = '撤销未完成，请在历史版本中预览恢复');
          }
        },
      );
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=delete errorType=${error.runtimeType}\n$stack');
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
      action: '清空课程', destructive: true,
    )) {
      return;
    }
    if (mounted) await _commitDeletion(base, [], '清空本学期课程');
  }

  Future<void> _history() async {
    final changed = await Navigator.push<bool>(
      context,
      CampusPageRoute(
        builder: (context) =>
            ScheduleHistoryPage(gateway: widget.gateway, term: widget.term),
      ),
    );
    if (changed == true) _changed = true;
    if (mounted) await _load();
  }

  // 整门课只有一位老师时写在课名下面一次，几位老师时写在各自的时段后面。
  Widget _courseCard(List<CourseRecord> group) {
    final slots = courseSlots(group);
    final teachers = slots.isEmpty ? {for (final course in group) course.teacherName} : {for (final slot in slots) slot.teacher};
    final sharedTeacher = teachers.length == 1 ? teachers.single : null;
    return CampusSurface(
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 12),
      margin: const EdgeInsets.symmetric(vertical: 8),
      onTap: _busy ? null : () => _edit(group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            Expanded(child: Text(group.first.courseName, style: Theme.of(context).textTheme.titleMedium)),
            Builder(builder: (anchor) => IconButton(
              tooltip: '课程操作',
              onPressed: _busy ? null : () => _courseMenu(anchor, group),
              icon: const CampusIcon(CampusIcons.manage),
            )),
          ]),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (sharedTeacher != null && sharedTeacher.isNotEmpty) Text(sharedTeacher),
                if (slots.isEmpty) const Text('暂无上课时间'),
                for (final slot in slots)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: DotSeparatedText(sharedTeacher == null ? slotLabel(slot) : meetingLabel(slot.meeting), style: const TextStyle(fontSize: 14, height: 1.5)),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) {},
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回',
          onPressed: _busy ? null : () => Navigator.pop(context, _changed),
          icon: const CampusIcon(CampusIcons.back),
        ),
        title: const Text('管理课程'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: CampusGlassCircleButton(
              label: '历史版本',
              size: 44,
              onPressed: _busy || _loading ? null : _history,
              icon: const CampusIcon(CampusIcons.history),
            ),
          ),
        ],
      ),
      body: CampusScrollFade(child: SafeArea(
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
                      onPressed: _busy ? null : () => _load(),
                      icon: const CampusIcon(CampusIcons.sync),
                      label: const Text('重试'),
                    ),
                  ],
                  if (_view != null) ...[
                    FilledButton.icon(
                      style: campusProminent,
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
                      OutlinedButton.icon(
                        icon: const CampusIcon(CampusIcons.add),
                        onPressed: _busy
                            ? null
                            : () async {
                                setState(() => _busy = true);
                                try {
                                  final error = await showCampusWaiting(context, label: '正在建立课表', operation: () => _save([], '建立空课表', null));
                                  if (mounted) setState(() => _error = error);
                                } catch (error, stack) {
                                  campusLog(
                                    '[ScheduleEditor] action=create errorType=${error.runtimeType}\n$stack',
                                  );
                                  if (mounted) {
                                    setState(() => _error = '建立课表失败');
                                  }
                                } finally {
                                  if (mounted) setState(() => _busy = false);
                                }
                              },
                        label: const Text('建立空课表'),
                      ),
                    // [人工决策-2026-10-19 16:08:42] 取代 10-06 的「整卡点进编辑（右侧箭头），编辑与删除收进右上⋯」（用户选定，同学习通账号管理、收藏位置）：
                    // 点卡片就是编辑，⋯里只留删除（警示色、仍要确认、可撤销），去掉右侧箭头；⋯与课名同一行，时段文字占满卡片宽度，卡片高度随内容
                    // （以前右侧一列放⋯、箭头和占位，把只有一个时段的卡撑出一大块空白）。同名的教学班合成一张卡（见 courseGroups）。
                    for (final group in courseGroups(_view!.courses)) _courseCard(group),
                    if (_view!.courses.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : _clear,
                          icon: const CampusIcon(CampusIcons.delete),
                          label: const Text('清空本学期课程'),
                        ),
                      ),
                  ],
                ],
              ),
      )),
    ),
  );
}
