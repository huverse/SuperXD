import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/domain/campus_log.dart';

// 编辑一门课：同名的几个教学班合在一起编辑（人工决策见 domain/schedule_edit.dart 的 courseGroups），
// 课名与学分对整门生效，老师和地点写在每个时段上，保存时按老师分回教学班。
class CourseEditorPage extends StatefulWidget {
  const CourseEditorPage({
    super.key,
    this.group = const [],
    this.slot,
    required this.courses,
    required this.bells,
    required this.onSave,
    this.selectedWeek,
  });
  // 要编辑的这门课（同名的几个教学班）；新增课程时为空。
  final List<CourseRecord> group;
  // 从课表页无课时段进来时预填的时段。
  final CourseSlot? slot;
  final List<CourseRecord> courses;
  final List<BellPeriod> bells;
  final int? selectedWeek;
  // 交出分回教学班后的记录（空表示整门删除），返回错误文案，成功为 null。
  final Future<String?> Function(List<CourseRecord> records) onSave;
  @override
  State<CourseEditorPage> createState() => _CourseEditorPageState();
}

class _CourseEditorPageState extends State<CourseEditorPage> {
  late final _initialName = widget.group.firstOrNull?.courseName ?? '';
  late final _initialCredit = switch (widget.group.firstOrNull?.credit) { final credit? => creditLabel(credit), null => '' };
  late final _name = TextEditingController(text: _initialName);
  late final _credit = TextEditingController(text: _initialCredit);
  late List<CourseSlot> _slots = [...courseSlots(widget.group), ?widget.slot];
  // 预填时段属于打开时的初始草稿：未改动返回不提示放弃，但仍须保存才生效。
  late final _initialSlots = _signature(_slots);
  bool _saving = false;
  bool _leaving = false;
  String? _error;
  bool get _dirty => _name.text != _initialName || _credit.text != _initialCredit || _signature(_slots) != _initialSlots;

  static String _signature(List<CourseSlot> slots) =>
      (slots.map((slot) => jsonEncode([meetingKey(slot.meeting), slot.meeting.weeks.toSet().toList()..sort(), slot.teacher])).toList()..sort()).join('\n');

  @override
  void dispose() {
    _name.dispose();
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
          action: '放弃修改', destructive: true,
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
    final removing = widget.group.any((course) => course.meetings.isNotEmpty) && _slots.isEmpty;
    final records = removing
        ? <CourseRecord>[]
        : normalizeSchedule(regroupCourse(
            widget.group,
            name: _name.text,
            slots: _slots,
            newLocalId: () => const Uuid().v4(),
            credit: _credit.text == _initialCredit ? null : (value: credit),
          ));
    try {
      if (_slots.isEmpty && widget.group.isEmpty) {
        throw const ScheduleValidation('请至少添加一个上课时段');
      }
      validateSchedule(records);
    } on ScheduleValidation catch (error) {
      // 校验不过是预期内的用户输入错误，只记类型不带堆栈
      campusLog('[ScheduleEditor] action=validate errorType=${error.runtimeType}');
      setState(() => _error = error.message);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (removing &&
          !await showCampusConfirm(
            context,
            title: '保存后删除整门课程？',
            message: '所有时段已移除，保存将删除整门课程。可在历史版本中恢复。',
            action: '保存并删除', destructive: true,
          )) {
        return;
      }
      if (!mounted) return;
      final keys = {for (final course in widget.group) courseKey(course)};
      final others = widget.courses.where((course) => !keys.contains(courseKey(course))).toList();
      final overlaps = [for (final record in records) ...courseOverlaps(record, others)];
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
      final error = await widget.onSave(records);
      if (!mounted) return;
      if (error == null) {
        // 成功轻触一次（人工决策见 chaoxing_sign_sheet.dart 的 _finishIfDone）。
        HapticFeedback.successNotification();
        setState(() => _leaving = true);
        Navigator.pop(context, true);
      } else {
        setState(() => _error = error);
      }
    } catch (error, stack) {
      campusLog('[ScheduleEditor] action=save errorType=${error.runtimeType}\n$stack');
      if (mounted) setState(() => _error = '保存未完成，草稿仍在，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // 点时段卡直接打开时段弹窗，改动范围在弹窗顶部选（人工决策见 _SlotDialog）；新加的时段默认沿用上一个时段的老师。
  Future<void> _editSlot({int? index, bool duplicate = false}) async {
    final original = index == null ? null : _slots[index];
    final edited = await showCampusDialog<({CourseSlot slot, int? week})>(
      context: context,
      builder: (context) => _SlotDialog(
        slot: original,
        teacher: original?.teacher ?? _slots.lastOrNull?.teacher ?? '',
        singleWeek: original != null && !duplicate && original.meeting.weeks.length > 1,
        preferredWeek: widget.selectedWeek,
        bells: widget.bells,
        places: widget.courses
            .expand((course) => course.meetings)
            .map((meeting) => meeting.place)
            .where((place) => place.isNotEmpty)
            .toSet()
            .toList(),
        teachers: widget.courses
            .map((course) => course.teacherName)
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList(),
      ),
    );
    if (!mounted || edited == null) return;
    setState(() {
      _slots = index == null || duplicate ? [..._slots, edited.slot] : changeSlot(_slots, index, edited.slot, week: edited.week);
      _error = null;
    });
  }

  Future<void> _slotMenu(BuildContext anchor, int index) async {
    final action = await showCampusMenu<String>(anchor, items: [
      if (_slots.length < maxCourseMeetings) const CampusMenuItem(value: 'copy', label: '复制为新时段', icon: CampusIcons.copy),
      const CampusMenuItem(value: 'remove', label: '移除', icon: CampusIcons.delete, destructive: true),
    ]);
    if (!mounted) return;
    if (action == 'copy') await _editSlot(index: index, duplicate: true);
    if (action == 'remove') await _deleteSlot(index);
  }

  Future<void> _deleteSlot(int index) async {
    final meeting = _slots[index].meeting;
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
      action: '移除', destructive: true,
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => _slots = removeSlot(_slots, index, week: week));
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
        title: Text(widget.group.isEmpty ? '新增课程' : '编辑课程'),
      ),
      body: CampusScrollFade(child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SizedBox(height: campusFieldGap(context)),
            TextField(
              controller: _name,
              enabled: !_saving,
              maxLength: 200,
              buildCounter: _nearLimitCounter,
              decoration: const InputDecoration(
                labelText: '课程名称',
                border: OutlineInputBorder(),
              ),
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
              '上课时段 · ${_slots.length}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            // 时段卡整卡点按调整这个时段，复制与移除在右上⋯里（同管理课程的课程卡）。
            for (var index = 0; index < _slots.length; index++)
              CampusSurface(
                padding: EdgeInsets.zero,
                margin: const EdgeInsets.symmetric(vertical: 8),
                onTap: _saving ? null : () => _editSlot(index: index),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: DotSeparatedText(slotLabel(_slots[index]), style: const TextStyle(fontSize: 14, height: 1.5)),
                        ),
                      ),
                      Builder(
                        builder: (anchor) => IconButton(
                          tooltip: '时段操作',
                          onPressed: _saving ? null : () => _slotMenu(anchor, index),
                          icon: const CampusIcon(CampusIcons.manage),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _saving || _slots.length >= maxCourseMeetings
                  ? null
                  : () => _editSlot(),
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
              style: campusProminent,
              onPressed: _saving ? null : _save,
              child: CampusBusyContent(busy: _saving, label: '保存课程', busyLabel: '保存中', icon: const CampusIcon(CampusIcons.check)),
            ),
          ],
        ),
      )),
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

enum _Scope { all, one }

class _SlotDialog extends StatefulWidget {
  const _SlotDialog({
    this.slot,
    required this.teacher,
    required this.singleWeek,
    this.preferredWeek,
    required this.bells,
    required this.places,
    required this.teachers,
  });
  final CourseSlot? slot;
  final String teacher;
  // 已有的多周时段才给「只改某一周」。
  final bool singleWeek;
  final int? preferredWeek;
  final List<BellPeriod> bells;
  final List<String> places;
  final List<String> teachers;
  @override
  State<_SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<_SlotDialog> {
  late final CourseMeeting? _meeting = widget.slot?.meeting;
  late int _weekday = _meeting?.weekday ?? 1;
  late int _start = _meeting?.periodStart ?? 1;
  late int _end = _meeting?.periodEnd ?? 2;
  late final _place = TextEditingController(text: _meeting?.place ?? '');
  late final _teacher = TextEditingController(text: widget.teacher);
  late Set<int> _weeks = _meeting?.weeks.toSet() ?? {for (var week = 1; week <= 18; week++) week};
  late int _visibleWeeks = _weeks.fold(
    20,
    (maximum, week) => week > maximum ? week : maximum,
  );
  var _scope = _Scope.all;
  // 只改某一周时改的是哪周：默认课表页正在看的那周（这个时段那周有课才算）。
  late int? _onlyWeek = _meeting?.weeks.contains(widget.preferredWeek) == true ? widget.preferredWeek : null;
  String? _error;
  @override
  void dispose() {
    _place.dispose();
    _teacher.dispose();
    super.dispose();
  }

  String _periodLabel(int period) {
    final bell = widget.bells
        .where((bell) => bell.period == period)
        .firstOrNull;
    return '第$period节${bell == null ? '' : ' ${bell.start}–${bell.end}'}';
  }

  void _save() {
    final one = _scope == _Scope.one;
    if (one && _onlyWeek == null || _end < _start || !one && _weeks.isEmpty) {
      setState(() => _error = one && _onlyWeek == null ? '请选择改哪一周' : _end < _start ? '结束节次不能早于开始' : '请至少选择一周');
      return;
    }
    Navigator.pop(context, (
      slot: CourseSlot(
        meeting: CourseMeeting(
          weekday: _weekday,
          periodStart: _start,
          periodEnd: _end,
          place: _place.text.trim(),
          weeks: one ? [_onlyWeek!] : (_weeks.toList()..sort()),
        ),
        teacher: _teacher.text.trim(),
        origin: widget.slot?.origin,
      ),
      week: one ? _onlyWeek : null,
    ));
  }

  // 快捷选周：当前选择正好是全部、单周、双周或一周没选时，那一项显示选中（同一时刻最多一项，不像以前三个都带勾）。
  Set<int> _preset(String choice) => {
    for (var week = 1; week <= _visibleWeeks; week++)
      if (choice == '全选' || choice == '单周' && week.isOdd || choice == '双周' && week.isEven) week,
  };

  Widget _weekPresets() => Wrap(spacing: 8, runSpacing: 8, children: [
    for (final choice in ['全选', '单周', '双周', '清空'])
      CampusGlassChip(
        label: choice,
        selected: _weeks.length == _preset(choice).length && _weeks.containsAll(_preset(choice)),
        onSelected: (_) => setState(() => _weeks = _preset(choice)),
      ),
  ]);

  // [人工决策-2026-10-19 18:51:59] 周次改等宽网格、选中填激活色，快捷选周不带勾、只亮正好匹配的那一项（用户从带勾标签、网格填色、网格描边三种实物中选定）：
  // 以前「全选、单周、双周」的勾号与已选周次一模一样、三个看着同时选中，周次选中后多出勾号变宽，一行 4 个、一行 5 个对不齐。
  // 周次网格：等宽格子按列对齐（每格至少 40 宽、48 高），一眼数得出第几周；选中只改底色，不加勾号、不变宽。
  Widget _weekGrid() => LayoutBuilder(builder: (context, constraints) {
    final palette = CampusPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    const gap = 6.0;
    final columns = ((constraints.maxWidth + gap) / (40 * scale + gap)).floor().clamp(4, 10);
    final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
    return Wrap(spacing: gap, runSpacing: gap, children: [
      for (var week = 1; week <= _visibleWeeks; week++)
        Builder(builder: (context) {
          final selected = _weeks.contains(week);
          return Semantics(
            button: true,
            selected: selected,
            label: '第$week周',
            excludeSemantics: true,
            child: Material(
              color: selected ? palette.accent : palette.onSurface.withValues(alpha: .06),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => selected ? _weeks.remove(week) : _weeks.add(week)),
                child: SizedBox(width: width, height: 48, child: Center(child: Text('$week', style: TextStyle(
                  fontSize: 16,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: selected ? Colors.white : palette.onSurface,
                  fontFeatures: const [FontFeature.tabularFigures()],
                )))),
              ),
            ),
          );
        }),
    ]);
  });

  @override
  Widget build(BuildContext context) => CampusGlassDialog(
    title: const Text('上课时段'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // [人工决策-2026-10-19 16:08:42] 时段卡整卡点按直接打开本弹窗，改动范围在顶部分段里选（用户选定，取代先弹「此时段的全部周次 / 仅某一周」再进弹窗）：
            // 默认「全部周次」、保存前看得见，范围仍由用户明确选择（09-25 的「改全部时段须明确选择」照旧）；复制与移除收进时段卡的⋯。
            if (widget.singleWeek) ...[
              CampusSegmented<_Scope>(
                values: _Scope.values,
                selected: _scope,
                label: (scope) => scope == _Scope.all ? '全部周次' : '只改某一周',
                onSelected: (scope) => setState(() {
                  _scope = scope;
                  _error = null;
                }),
              ),
              const SizedBox(height: 16),
              if (_scope == _Scope.one) ...[
                Text('改哪一周', style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 8,
                  children: [
                    for (final week in _meeting!.weeks.toSet().toList()..sort())
                      CampusGlassChip(
                        label: '第$week周',
                        selected: _onlyWeek == week,
                        onSelected: (_) => setState(() {
                          _onlyWeek = week;
                          _error = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ],
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
            SizedBox(height: campusFieldGap(context)),
            _SuggestionField(
              controller: _teacher,
              label: '教师（选填）',
              options: widget.teachers,
            ),
            if (_scope == _Scope.all) ...[
              const SizedBox(height: 16),
              Text(
                weeksLabel(_weeks.toList()),
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 8),
              _weekPresets(),
              const SizedBox(height: 12),
              _weekGrid(),
              if (_visibleWeeks < maxScheduleWeeks)
                TextButton.icon(
                  onPressed: () => setState(
                    () => _visibleWeeks = (_visibleWeeks + 10).clamp(
                      1,
                      maxScheduleWeeks,
                    ),
                  ),
                  icon: const CampusIcon(CampusIcons.expand),
                  label: const Text('显示更多周次'),
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
      // 只写「确定」：标题已是「上课时段」，四个字在 360dp、大字号下会折出孤字「段」。
      FilledButton(onPressed: _save, child: const Text('确定')),
    ],
  );
}

class _SuggestionField extends StatelessWidget {
  const _SuggestionField({
    required this.controller,
    required this.label,
    required this.options,
  });
  final TextEditingController controller;
  final String label;
  final List<String> options;
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
        maxLength: 200,
        buildCounter: _nearLimitCounter,
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
                onPressed: () => controller.text = options[index],
                child: Text(options[index]),
              ),
            ),
          ),
        ),
    ],
  );
  }
}

// 字数计数只在接近上限（剩 20 字以内）时出现，平时不占视线；超限仍由 maxLength 截断。
Widget? _nearLimitCounter(BuildContext context, {required int currentLength, required int? maxLength, required bool isFocused}) =>
    maxLength == null || maxLength - currentLength > 20 ? null : Text('$currentLength/$maxLength', style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant));
