import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_merge.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// [人工决策-2026-10-19 16:08:42] 好友分享的课表可以导入（用户选定，取代 10-04 的「接收方只读、不覆盖自己的课表」，同 WakeUp 课程表、小爱课程表导入分享）：
// 都存成当前账号的新版本、可在历史版本恢复，开学日和作息不动；之后教务同步要覆盖时照旧先问。只读写本机，不联网；本机没有这个学期时说明原因，不替用户同步。
// [人工决策-2026-10-23 16:48:13] 用户选「逐项合并」（取代 10-19 的「挑几门加进来」，整份替换保留）：同 Word 修订逐条接受、VS Code 合并编辑器——
// 两份课表按课名配对，列出TA有你没有的课、同一门课改了的每一处（上课时间、周次、教室、教师、学分各占一行）、你有TA没有的课，每一行都能单独勾「用TA的」。
// 默认只勾有同一个教学班的那几门课的改动（同班同学的课表多半是对的），同名但教学班不同的、新课与要删的课都不勾；以前只能把多出来的课加进来，改了教室、教师、时间的没法只改那一处。
Future<void> importSharedSchedule(BuildContext context, {required CampusGateway gateway, required ScheduleShare share, required String friendName}) async {
  try {
    final terms = await gateway.listTerms();
    final term = terms.data?.where((term) => term.key == share.term.key).firstOrNull;
    if (!context.mounted) return;
    if (term == null) {
      await showCampusNotice(context, '你的账号里还没有「${_termLabel(share.term)}」，先在今天页同步这个学年再导入。');
      return;
    }
    final read = await gateway.readSchedule(ScheduleScope.term(term));
    if (!context.mounted) return;
    final mine = read.data;
    if (!read.ok || mine == null) {
      await showCampusNotice(context, read.error?.message ?? '读取本机课表失败，请重试');
      return;
    }
    // 先读好本机课表再打开（同取件手机号管理的先读后开），页面一出来就是对比结果；成功的提示条回到发起的页面上显示。
    final done = await Navigator.of(context, rootNavigator: true).push<String>(
      CampusPageRoute(builder: (_) => _ImportPage(gateway: gateway, term: term, mine: mine, share: share, friendName: friendName)),
    );
    if (done != null && context.mounted) showCampusToast(context, done);
  } catch (error, stack) {
    campusLog('[ScheduleImport] action=open errorType=${error.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '导入未完成，课表没有改动');
  }
}

String _termLabel(TermRef term) => term.label.isEmpty ? term.key : term.label;

enum _Mode { merge, replace }

class _ImportPage extends StatefulWidget {
  const _ImportPage({required this.gateway, required this.term, required this.mine, required this.share, required this.friendName});
  final CampusGateway gateway;
  final TermRef term;
  final ScheduleView mine;
  final ScheduleShare share;
  final String friendName;

  @override
  State<_ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<_ImportPage> {
  late final _plan = planScheduleMerge(widget.mine.courses, widget.share.courses);
  // 这学期在本机还没有课表时没什么可合并的，默认整份导入。
  late final _fresh = widget.mine.revisionId == null;
  late var _mode = _fresh ? _Mode.replace : _Mode.merge;
  late final _items = {for (final course in _plan.changed) if (course.sameClass) ...course.items.map((item) => item.id)};
  final _added = <String>{};
  final _removed = <String>{};
  bool _saving = false;

  int get _picked => _items.length + _added.length + _removed.length;

  void _toggle(Set<String> selection, String id) => setState(() => selection.contains(id) ? selection.remove(id) : selection.add(id));

  Future<void> _apply() async {
    final friend = widget.friendName;
    final List<CourseRecord> courses;
    final String summary;
    final String done;
    if (_mode == _Mode.replace) {
      final mineCount = courseGroups(widget.mine.courses).length, theirCount = courseGroups(widget.share.courses).length;
      if (!await showCampusConfirm(
        context,
        title: _fresh ? '导入这份课表？' : '替换这学期的课表？',
        message: _fresh
            ? '会用$friend分享的 $theirCount 门课建立「${_termLabel(widget.term)}」的课表。开学日和作息不变。'
            : '「${_termLabel(widget.term)}」现在的 $mineCount 门课会换成$friend分享的 $theirCount 门课，存成一个新版本；现在的课表留在历史版本里，可以恢复。开学日和作息不变。',
        action: _fresh ? '导入' : '替换',
        destructive: !_fresh,
      )) {
        return;
      }
      courses = widget.share.courses;
      summary = '导入$friend分享的课表';
      done = '已换成$friend的课表，可在历史版本恢复';
    } else {
      courses = applyScheduleMerge(_plan, widget.mine.courses, items: _items, added: _added, removed: _removed, newLocalId: () => const Uuid().v4());
      // 改过的与新加的课和其余课的上课时间有重叠时先说明，仍要合并才存。
      final touched = {
        for (final course in _plan.changed)
          if (course.items.any((item) => _items.contains(item.id))) course.name,
        ..._added,
      };
      final overlaps = {
        for (final course in courses)
          if (touched.contains(course.courseName.trim()))
            for (final overlap in courseOverlaps(course, courses))
              if (overlap.courseName.trim() != course.courseName.trim()) '${course.courseName} 与 ${overlap.label}',
      };
      if (overlaps.isNotEmpty &&
          !await showCampusConfirm(context, title: '上课时间有重叠', message: '${overlaps.join('\n')}\n\n仍然合并？', action: '仍然合并')) {
        return;
      }
      final changedCount = _plan.changed.where((course) => course.items.any((item) => _items.contains(item.id))).length;
      final parts = [if (changedCount > 0) '改 $changedCount 门', if (_added.isNotEmpty) '加 ${_added.length} 门', if (_removed.isNotEmpty) '删 ${_removed.length} 门'];
      summary = '合并$friend分享的课表：${parts.join('、')}';
      done = '已合并$friend的课表，可在历史版本恢复';
    }
    if (!mounted) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.gateway.saveScheduleRevision(widget.term, courses, summary, expectedRevisionId: widget.mine.revisionId);
      if (!mounted) return;
      if (!saved.ok) {
        await showCampusNotice(context, saved.error?.message ?? '导入未完成，课表没有改动');
        return;
      }
      // 成功轻触一次（人工决策见 chaoxing_sign_sheet.dart 的 _finishIfDone）。
      HapticFeedback.successNotification();
      Navigator.of(context).pop(done);
    } catch (error, stack) {
      campusLog('[ScheduleImport] action=${_mode.name} errorType=${error.runtimeType}\n$stack');
      if (mounted) await showCampusNotice(context, '导入未完成，课表没有改动');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final replace = _mode == _Mode.replace;
    final theirCount = courseGroups(widget.share.courses).length, mineCount = courseGroups(widget.mine.courses).length;
    Widget section(String title, {String? note}) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: textTheme.titleMedium),
        if (note != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(note, style: secondary)),
      ]),
    );
    final List<Widget> body;
    if (replace) {
      body = [
        const SizedBox(height: 16),
        CampusSurface(
          child: Text(
            _fresh
                ? '会用${widget.friendName}分享的 $theirCount 门课建立这学期的课表。开学日和作息不变。'
                : '你现在的 $mineCount 门课会换成${widget.friendName}分享的 $theirCount 门课。现在的课表留在历史版本里，可以恢复；开学日和作息不变。',
            style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface),
          ),
        ),
      ];
    } else if (_plan.identical) {
      body = [
        const SizedBox(height: 16),
        CampusSurface(child: Row(children: [
          Padding(padding: const EdgeInsets.only(right: 12), child: CampusIcon(CampusIcons.success, color: palette.onSurfaceVariant)),
          Expanded(child: Text('两份课表一样，没有要合并的', style: TextStyle(fontSize: 16, color: palette.onSurface))),
        ])),
      ];
    } else {
      body = [
        if (_plan.changed.isNotEmpty) ...[
          section('有改动 · ${_plan.changed.length} 门', note: '勾上的用${widget.friendName}的'),
          for (final course in _plan.changed) _ChangedCourse(course: course, selection: _items, enabled: !_saving, onChanged: () => setState(() {})),
        ],
        if (_plan.added.isNotEmpty) ...[
          section('${widget.friendName}有你没有 · ${_plan.added.length} 门', note: '勾上的加进你的课表'),
          for (final group in _plan.added)
            _WholeCourse(group: group, picked: _added.contains(group.first.courseName.trim()), enabled: !_saving, onTap: () => _toggle(_added, group.first.courseName.trim())),
        ],
        if (_plan.removed.isNotEmpty) ...[
          section('你有${widget.friendName}没有 · ${_plan.removed.length} 门', note: '勾上的从你的课表删掉'),
          for (final group in _plan.removed)
            _WholeCourse(group: group, picked: _removed.contains(group.first.courseName.trim()), removing: true, enabled: !_saving, onTap: () => _toggle(_removed, group.first.courseName.trim())),
        ],
        if (_plan.same > 0) Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 0), child: Text('其余 ${_plan.same} 门两边一样', style: secondary)),
      ];
    }
    final String label;
    if (replace) {
      label = _fresh ? '导入这份课表' : '替换这学期的课表';
    } else {
      label = _picked == 0 ? '应用改动' : '应用 $_picked 项改动';
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text('导入${widget.friendName}的课表'),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: CampusScrollFade(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  DotSeparatedText('${_termLabel(widget.term)} · ${widget.friendName}的 $theirCount 门课', style: secondary),
                  const SizedBox(height: 12),
                  CampusSegmented<_Mode>(
                    values: _Mode.values,
                    selected: _mode,
                    label: (mode) => mode == _Mode.merge ? '逐项合并' : '整份替换',
                    onSelected: _saving ? null : (mode) => setState(() => _mode = mode),
                  ),
                  ...body,
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: replace && !_fresh ? campusDestructive : campusProminent,
                onPressed: _saving || (!replace && _picked == 0) ? null : _apply,
                child: CampusBusyContent(
                  busy: _saving,
                  label: label,
                  busyLabel: '正在保存',
                  icon: CampusIcon(replace ? CampusIcons.replaceSchedule : CampusIcons.mergeSchedule),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// 勾选行：整行点按勾选（同签到对象），读屏把勾选框与这一行的文字合成一项。
class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.value, required this.onTap, required this.child, this.enabled = true});
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

const _fieldNames = {
  MergeField.slot: '上课时间',
  MergeField.place: '教室',
  MergeField.weeks: '周次',
  MergeField.teacher: '教师',
  MergeField.addSlot: '加上时段',
  MergeField.removeSlot: '去掉时段',
  MergeField.credit: '学分',
};

// 两边都有、有差异的一门课：课名一行可整门勾选（部分勾选时是半选），下面每处差异一行，原来的划掉、TA的写在下面。
class _ChangedCourse extends StatelessWidget {
  const _ChangedCourse({required this.course, required this.selection, required this.onChanged, required this.enabled});
  final CourseMerge course;
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
        _CheckRow(
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
            Text(course.sameClass ? '同一个教学班' : '同名课程，教学班不同', style: secondary),
          ]),
        ),
        for (final item in course.items)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: _CheckRow(
              value: selection.contains(item.id),
              enabled: enabled,
              onTap: () {
                selection.contains(item.id) ? selection.remove(item.id) : selection.add(item.id);
                onChanged();
              },
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DotSeparatedText([_fieldNames[item.field]!, if (item.scope.isNotEmpty) item.scope].join(' · '), style: secondary),
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

// 只有一边有的一门课：整门勾选，下面列时段（老师写在各自时段后）；要删的那组勾上时课名划掉、写明会删掉。
class _WholeCourse extends StatelessWidget {
  const _WholeCourse({required this.group, required this.picked, required this.onTap, required this.enabled, this.removing = false});
  final List<CourseRecord> group;
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
      child: _CheckRow(
        value: picked,
        enabled: enabled,
        onTap: onTap,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            group.first.courseName,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface, decoration: struck ? TextDecoration.lineThrough : null),
          ),
          for (final slot in courseSlots(group)) DotSeparatedText(slotLabel(slot), style: secondary.copyWith(height: 1.5)),
          if (struck) Text('会从你的课表删掉', style: TextStyle(fontSize: 14, color: palette.danger)),
        ]),
      ),
    );
  }
}
