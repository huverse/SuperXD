import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/domain/campus_log.dart';

class CourseEditorPage extends StatefulWidget {
  const CourseEditorPage({
    super.key,
    this.course,
    this.slot,
    required this.courses,
    required this.bells,
    required this.onSave,
    this.selectedWeek,
  });
  final CourseRecord? course;
  final CourseMeeting? slot;
  final List<CourseRecord> courses;
  final List<BellPeriod> bells;
  final int? selectedWeek;
  final Future<String?> Function(CourseRecord course) onSave;
  @override
  State<CourseEditorPage> createState() => _CourseEditorPageState();
}

class _CourseEditorPageState extends State<CourseEditorPage> {
  late final CourseRecord _original =
      widget.course ??
      CourseRecord(
        courseCode: '',
        courseName: '',
        sectionId: '',
        credit: null,
        teacherName: '',
        meetings: [],
        localId: const Uuid().v4(),
      );
  late final _name = TextEditingController(text: _original.courseName);
  late final _teacher = TextEditingController(text: _original.teacherName);
  late final _credit = TextEditingController(
    text: _original.credit?.toString() ?? '',
  );
  late List<CourseMeeting> _meetings = [
    ..._original.meetings.map((meeting) => meeting.copy()),
    if (widget.slot != null) widget.slot!.copy(),
  ];
  // 预填时段属于打开时的初始草稿：未改动返回不提示放弃，但仍须保存才生效。
  late final _initialMeetings = fingerprint([
    replaceCourse(
      _original,
      meetings: [..._original.meetings, if (widget.slot != null) widget.slot!],
    ),
  ]);
  bool _saving = false;
  bool _leaving = false;
  String? _error;
  bool get _dirty =>
      _name.text != _original.courseName ||
      _teacher.text != _original.teacherName ||
      _credit.text != (_original.credit?.toString() ?? '') ||
      fingerprint([replaceCourse(_original, meetings: _meetings)]) !=
          _initialMeetings;

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _credit.dispose();
    super.dispose();
  }

  Future<void> _back() async {
    if (_saving) return;
    if (_dirty &&
        !await showCampusConfirm(
          context,
          title: '放弃未保存修改？',
          message: '当前草稿尚未保存，离开后将丢失。',
          action: '放弃修改',
        )) {
      return;
    }
    if (mounted) {
      setState(() => _leaving = true);
      Navigator.pop(context, false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final creditText = _credit.text.trim();
    final credit = creditText.isEmpty ? null : num.tryParse(creditText);
    if (creditText.isNotEmpty && credit == null) {
      setState(() => _error = '请输入有效学分');
      return;
    }
    final course = normalizeSchedule([
      replaceCourse(
        _original,
        name: _name.text,
        teacher: _teacher.text,
        credit: credit,
        clearCredit: credit == null,
        meetings: _meetings,
      ),
    ]).single;
    try {
      if (course.meetings.isEmpty &&
          _original.meetings.isEmpty &&
          widget.course == null) {
        throw const ScheduleValidation('请至少添加一个上课时段');
      }
      validateSchedule([course]);
    } on ScheduleValidation catch (error, stack) {
      campusLog('[ScheduleEditor] action=validate error=$error\n$stack');
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final removing =
          widget.course != null &&
          _original.meetings.isNotEmpty &&
          course.meetings.isEmpty;
      if (removing &&
          !await showCampusConfirm(
            context,
            title: '保存后删除整门课程？',
            message: '所有时段已移除，保存将删除整门课程。可在历史版本中恢复。',
            action: '保存并删除',
          )) {
        return;
      }
      if (!mounted) return;
      final overlaps = courseOverlaps(course, widget.courses);
      if (overlaps.isNotEmpty &&
          !await showCampusConfirm(
            context,
            title: '上课时间有重叠',
            message: '${overlaps.map((overlap) => overlap.label).join('\n')}\n\n保留这些课程并继续保存？',
            action: '仍然保存',
          )) {
        return;
      }
      if (!mounted) return;
      final error = await widget.onSave(course);
      if (!mounted) return;
      if (error == null) {
        setState(() => _leaving = true);
        Navigator.pop(context, true);
      } else {
        setState(() => _error = error);
      }
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=save error=$error\n$stack');
      if (mounted) setState(() => _error = '保存未完成，草稿仍在，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editMeeting({int? index, bool duplicate = false}) async {
    final original = index == null ? null : _meetings[index];
    int? onlyWeek;
    if (original != null && !duplicate && original.weeks.length > 1) {
      final choice = await showCampusDialog<String>(
        context: context,
        builder: (context) => CampusGlassDialog(
          title: const Text('调整哪些周次？'),
          options: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'all'),
              child: const Text('此时段的全部周次'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'one'),
              child: const Text('仅某一周'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'one') {
        onlyWeek = await chooseMeetingWeek(
          context,
          original.weeks,
          preferred: widget.selectedWeek,
        );
        if (!mounted || onlyWeek == null) return;
      }
    }
    final edited = await showCampusDialog<CourseMeeting>(
      context: context,
      builder: (context) => _MeetingDialog(
        meeting: original,
        bells: widget.bells,
        onlyWeek: onlyWeek,
        places: widget.courses
            .expand((course) => course.meetings)
            .map((meeting) => meeting.place)
            .where((place) => place.isNotEmpty)
            .toSet()
            .toList(),
      ),
    );
    if (!mounted || edited == null) return;
    setState(() {
      if (index == null || duplicate) {
        _meetings.add(edited);
      } else {
        _meetings = changeMeeting(
          replaceCourse(_original, meetings: _meetings),
          index,
          edited,
          week: onlyWeek,
        ).meetings;
      }
      _error = null;
    });
  }

  Future<void> _deleteMeeting(int index) async {
    final meeting = _meetings[index];
    final scope = await showCampusDialog<String>(
      context: context,
      builder: (context) => CampusGlassDialog(
        title: const Text('删除范围'),
        options: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'all'),
            child: const Text('这个时段的全部周次'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'one'),
            child: const Text('仅某一周的这次课'),
          ),
        ],
      ),
    );
    if (!mounted || scope == null) return;
    final week = scope == 'one'
        ? await chooseMeetingWeek(
            context,
            meeting.weeks,
            preferred: widget.selectedWeek,
          )
        : null;
    if (!mounted || (scope == 'one' && week == null)) return;
    if (!await showCampusConfirm(
      context,
      title: '从草稿移除此时段？',
      message: '${week == null ? meetingLabel(meeting) : '仅第$week周的这次课'}\n保存课程后生效，历史版本中可恢复。',
      action: '移除',
    )) {
      return;
    }
    if (!mounted) return;
    setState(
      () => _meetings =
          removeMeeting(
            replaceCourse(_original, meetings: _meetings),
            index,
            week: week,
          )?.meetings ??
          [],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _leaving,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: '返回',
          onPressed: _saving ? null : _back,
          icon: const CampusIcon(CampusIcons.back),
        ),
        title: Text(widget.course == null ? '新增课程' : '编辑课程'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('课程信息作用于整门课；上课时段可分别调整。', style: TextStyle(fontSize: 14)),
            SizedBox(height: campusFieldGap(context)),
            TextField(
              controller: _name,
              enabled: !_saving,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: '课程名称',
                border: OutlineInputBorder(),
              ),
            ),
            SizedBox(height: campusFieldGap(context)),
            _SuggestionField(
              controller: _teacher,
              label: '教师（选填）',
              enabled: !_saving,
              options: widget.courses
                  .map((course) => course.teacherName)
                  .where((name) => name.isNotEmpty)
                  .toSet()
                  .toList(),
            ),
            SizedBox(height: campusFieldGap(context)),
            TextField(
              controller: _credit,
              enabled: !_saving,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: '学分（选填）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '上课时段 · ${_meetings.length}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (var index = 0; index < _meetings.length; index++)
              CampusSurface(padding: EdgeInsets.zero, margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        meetingLabel(_meetings[index]),
                        style: const TextStyle(fontSize: 14, height: 1.5),
                      ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _editMeeting(index: index),
                            child: const Text('调整'),
                          ),
                          TextButton(
                            onPressed:
                                _saving || _meetings.length >= maxCourseMeetings
                                ? null
                                : () => _editMeeting(
                                    index: index,
                                    duplicate: true,
                                  ),
                            child: const Text('复制'),
                          ),
                          TextButton(
                            onPressed: _saving
                                ? null
                                : () => _deleteMeeting(index),
                            child: const Text('移除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _saving || _meetings.length >= maxCourseMeetings
                  ? null
                  : () => _editMeeting(),
              icon: const CampusIcon(CampusIcons.add),
              label: const Text('添加时段'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 14,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: CampusBusyContent(busy: _saving, label: '保存课程', busyLabel: '保存中'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<int?> chooseMeetingWeek(
  BuildContext context,
  List<int> weeks, {
  int? preferred,
}) => showCampusDialog<int>(
  context: context,
  builder: (context) => CampusGlassDialog(
    title: const Text('选择周次'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final week in weeks.toSet().toList()..sort())
              CampusGlassChip(
                label: '第$week周',
                selected: week == preferred,
                onSelected: (_) => Navigator.pop(context, week),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
    ],
  ),
);

class _MeetingDialog extends StatefulWidget {
  const _MeetingDialog({
    this.meeting,
    this.onlyWeek,
    required this.bells,
    required this.places,
  });
  final CourseMeeting? meeting;
  final int? onlyWeek;
  final List<BellPeriod> bells;
  final List<String> places;
  @override
  State<_MeetingDialog> createState() => _MeetingDialogState();
}

class _MeetingDialogState extends State<_MeetingDialog> {
  late int _weekday = widget.meeting?.weekday ?? 1;
  late int _start = widget.meeting?.periodStart ?? 1;
  late int _end = widget.meeting?.periodEnd ?? 2;
  late final _place = TextEditingController(text: widget.meeting?.place ?? '');
  late Set<int> _weeks = widget.onlyWeek != null
      ? {widget.onlyWeek!}
      : widget.meeting?.weeks.toSet() ??
            {for (var week = 1; week <= 18; week++) week};
  late int _visibleWeeks = _weeks.fold(
    20,
    (maximum, week) => week > maximum ? week : maximum,
  );
  String? _error;
  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  String _periodLabel(int period) {
    final bell = widget.bells
        .where((bell) => bell.period == period)
        .firstOrNull;
    return '第$period节${bell == null ? '' : ' ${bell.start}–${bell.end}'}';
  }

  void _save() {
    if (_end < _start || _weeks.isEmpty) {
      setState(() => _error = _weeks.isEmpty ? '请至少选择一周' : '结束节次不能早于开始');
      return;
    }
    Navigator.pop(
      context,
      CourseMeeting(
        weekday: _weekday,
        periodStart: _start,
        periodEnd: _end,
        place: _place.text.trim(),
        weeks: _weeks.toList()..sort(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: Text(widget.onlyWeek == null ? '上课时段' : '仅调整第${widget.onlyWeek}周'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 8,
              children: [
                for (var day = 1; day <= 7; day++)
                  CampusGlassChip(
                    label: '周${weekdayLabel(day)}',
                    selected: _weekday == day,
                    onSelected: (_) => setState(() => _weekday = day),
                  ),
              ],
            ),
            SizedBox(height: campusFieldGap(context)),
            CampusMenuField<int>(
              label: '开始节次',
              value: _start,
              items: [
                for (var period = 1; period <= maxSchedulePeriods; period++)
                  CampusMenuItem(value: period, label: _periodLabel(period)),
              ],
              onChanged: (value) => setState(() => _start = value),
            ),
            SizedBox(height: campusFieldGap(context)),
            CampusMenuField<int>(
              label: '结束节次',
              value: _end,
              items: [
                for (var period = 1; period <= maxSchedulePeriods; period++)
                  CampusMenuItem(value: period, label: _periodLabel(period)),
              ],
              onChanged: (value) => setState(() => _end = value),
            ),
            SizedBox(height: campusFieldGap(context)),
            _SuggestionField(
              controller: _place,
              label: '地点（选填）',
              options: widget.places,
            ),
            const SizedBox(height: 16),
            Text(
              weeksLabel(_weeks.toList()),
              style: const TextStyle(fontSize: 14),
            ),
            if (widget.onlyWeek == null) ...[
              Wrap(
                spacing: 4,
                children: [
                  for (final choice in ['全选', '单周', '双周', '清空'])
                    TextButton(
                      onPressed: () => setState(
                        () => _weeks = {
                          for (var week = 1; week <= _visibleWeeks; week++)
                            if (choice == '全选' ||
                                choice == '单周' && week.isOdd ||
                                choice == '双周' && week.isEven)
                              week,
                        },
                      ),
                      child: Text(choice),
                    ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 8,
                children: [
                  for (var week = 1; week <= _visibleWeeks; week++)
                    CampusGlassChip(
                      label: '$week',
                      selected: _weeks.contains(week),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _weeks.add(week);
                        } else {
                          _weeks.remove(week);
                        }
                      }),
                    ),
                ],
              ),
              if (_visibleWeeks < maxScheduleWeeks)
                TextButton(
                  onPressed: () => setState(
                    () => _visibleWeeks = (_visibleWeeks + 10).clamp(
                      1,
                      maxScheduleWeeks,
                    ),
                  ),
                  child: const Text('显示更多周次'),
                ),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('确定时段')),
    ],
  );
}

class _SuggestionField extends StatelessWidget {
  const _SuggestionField({
    required this.controller,
    required this.label,
    required this.options,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String label;
  final List<String> options;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    // 横向候选栏高度随字号：按真实字形量出按钮文字行高再加按钮上下内边距，大字号不裁切，仍按需构建。
    // 候选是“点一下填入”的动作，用全局玻璃胶囊按钮，不用带选中语义的选择标签。
    final painter = TextPainter(
      text: TextSpan(text: '国', style: FilledButtonTheme.of(context).style!.textStyle!.resolve(const {})),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final rowHeight = math.max(48.0, painter.height + 14);
    painter.dispose();
    return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: controller,
        enabled: enabled,
        maxLength: 200,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
      if (options.isNotEmpty)
        SizedBox(
          height: rowHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: options.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            // 横向列表给子项的是行高的紧约束，居中放开后按钮保持约38的视觉高度、48的触区。
            itemBuilder: (context, index) => Center(
              child: FilledButton(
                onPressed: enabled
                    ? () => controller.text = options[index]
                    : null,
                child: Text(options[index]),
              ),
            ),
          ),
        ),
    ],
  );
  }
}
