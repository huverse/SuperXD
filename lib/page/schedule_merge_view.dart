import 'package:flutter/material.dart';

import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_merge.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 逐项合并的列表行，好友课表导入（schedule_import.dart）与教务课表冲突（sync_merge_page.dart）共用。

// 勾选行：整行点按勾选（同签到对象），读屏把勾选框与这一行的文字合成一项。
class MergeCheckRow extends StatelessWidget {
  const MergeCheckRow({super.key, required this.value, required this.onTap, required this.child, this.enabled = true});
  final bool? value;
  final VoidCallback onTap;
  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: enabled ? onTap : null,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: value, tristate: value == null, onChanged: enabled ? (_) => onTap() : null),
        Expanded(child: Padding(padding: const EdgeInsets.only(top: 12, bottom: 8), child: child)),
      ]),
    ),
  );
}

const mergeFieldNames = {
  MergeField.slot: '上课时间',
  MergeField.place: '教室',
  MergeField.weeks: '周次',
  MergeField.teacher: '教师',
  MergeField.addSlot: '加上时段',
  MergeField.removeSlot: '去掉时段',
  MergeField.credit: '学分',
};

// 两边都有、有差异的一门课：课名一行可整门勾选（部分勾选时是半选），下面写 caption（同不同教学班、是谁改的），
// 再下面每处差异一行，原来的划掉、对方的写在下面。
class MergeChangedCourse extends StatelessWidget {
  const MergeChangedCourse({super.key, required this.course, required this.caption, required this.selection, required this.onChanged, required this.enabled});
  final CourseMerge course;
  final String caption;
  final Set<String> selection;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final picked = course.items.where((item) => selection.contains(item.id)).length;
    final all = picked == course.items.length;
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      radius: 16,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MergeCheckRow(
          value: picked == 0 ? false : all ? true : null,
          enabled: enabled,
          onTap: () {
            for (final item in course.items) {
              all ? selection.remove(item.id) : selection.add(item.id);
            }
            onChanged();
          },
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(course.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
            Text(caption, style: secondary),
          ]),
        ),
        for (final item in course.items)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: MergeCheckRow(
              value: selection.contains(item.id),
              enabled: enabled,
              onTap: () {
                selection.contains(item.id) ? selection.remove(item.id) : selection.add(item.id);
                onChanged();
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DotSeparatedText([mergeFieldNames[item.field]!, if (item.scope.isNotEmpty) item.scope].join(' · '), style: secondary),
                if (item.before.isNotEmpty)
                  DotSeparatedText(item.before, style: secondary.copyWith(decoration: TextDecoration.lineThrough, decorationColor: palette.onSurfaceVariant, height: 1.5)),
                if (item.after.isNotEmpty) DotSeparatedText(item.after, style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface)),
              ]),
            ),
          ),
      ]),
    );
  }
}

// 只有一边有的一门课：整门勾选，下面列时段（老师写在各自时段后）；要删的那组勾上时课名划掉、写明会删掉。caption 给了时写在课名下（是谁改的）。
class MergeWholeCourse extends StatelessWidget {
  const MergeWholeCourse({super.key, required this.group, required this.picked, required this.onTap, required this.enabled, this.removing = false, this.caption});
  final List<CourseRecord> group;
  final String? caption;
  final bool picked;
  final VoidCallback onTap;
  final bool enabled;
  final bool removing;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final struck = removing && picked;
    return CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      radius: 16,
      child: MergeCheckRow(
        value: picked,
        enabled: enabled,
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            group.first.courseName,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface, decoration: struck ? TextDecoration.lineThrough : null),
          ),
          if (caption != null) Text(caption!, style: secondary),
          for (final slot in courseSlots(group)) DotSeparatedText(slotLabel(slot), style: secondary.copyWith(height: 1.5)),
          if (struck) Text('会从你的课表删掉', style: TextStyle(fontSize: 14, color: palette.danger)),
        ]),
      ),
    );
  }
}
