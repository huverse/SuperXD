import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/auto_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_merge.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/schedule_merge_view.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 教务课表和本地改过的版本冲突时选择性覆盖（三方合并，人工决策见 domain/auto_sync.dart）：
// 以最近一次教务同步的版本为基准分清是谁改的——只有教务改的默认勾上（用教务的），你改过的与两边都改了的默认不勾（保留你的）；
// 每处差异都能单独勾，「整份替换」整份换成教务的（覆盖仍要确认）。没勾任何一项时按钮就是保留我的课表。
// 合并后存成两个版本（先一版教务同步、再一版合并结果），都能在历史版本恢复；开学日与作息不动。

// 手动同步遇到冲突（CampusSync 的 resolveSchedule）：先读好本机课表再打开合并页；退出合并页同以前的「保留本地」，这份教务课表不再提醒。
// 本机课表没读到时用户没做过选择：留着这份等打扰时机再问，不记成「不再提醒」。
Future<ScheduleResolution> resolveScheduleSync(BuildContext context, {required CampusGateway gateway, required TermRef term, required SyncPlan plan, required List<CourseRecord> edu}) async =>
    switch (await _openMergePage(context, gateway: gateway, term: term, plan: plan, edu: edu)) {
      (failed: true, resolution: _) => const KeepLocal(remember: false),
      (failed: false, :final resolution) => resolution ?? const KeepLocal(remember: true),
    };

// 打扰时机里自动同步留下的冲突：先问一句，要选的再打开合并页；按返回或点空白处是以后再说（下一个打扰时机再问）。
// 弹之前从本机库重读一遍：手动同步过（暂存的那份已经放掉）或换过账号时就不问了，不拿旧的一份落库。
Future<void> showHeldScheduleSync(BuildContext context, {required AutoSync autoSync, required CampusGateway gateway, required HeldScheduleSync held}) async {
  if (await autoSync.stillHeld(held) == null || !context.mounted) return;
  final pick = await showCampusDialog<bool>(
    context: context,
    builder: (context) => CampusGlassDialog(
      title: const Text('教务课表有更新'),
      content: Text('「${_termLabel(held.term)}」教务的课表和你改过的不一样，可以逐项挑要用的改动。', style: const TextStyle(fontSize: 14)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留本地')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('逐项选择')),
      ],
    ),
  );
  if (pick == null || !context.mounted) return;
  try {
    if (!pick) {
      final kept = await autoSync.settle(held, const KeepLocal(remember: true), expectedRevisionId: null);
      if (kept.outcome == SyncOutcome.failed && context.mounted) await showCampusNotice(context, kept.message);
      return;
    }
    final planned = await gateway.planScheduleSync(held.term, held.courses);
    if (!context.mounted) return;
    final plan = planned.data;
    if (!planned.ok || plan == null) {
      await showCampusNotice(context, planned.error?.message ?? '读取本机课表失败，请重试');
      return;
    }
    // 期间本地已经换回教务的版本：不再冲突，直接落这份教务课表（暂存的这份比那时同步的新：手动同步过会放掉暂存，弹之前已重读）。
    final resolution = plan.conflict ? (await _openMergePage(context, gateway: gateway, term: held.term, plan: plan, edu: held.courses)).resolution : const TakeEdu();
    if (resolution == null || !context.mounted) return;
    final result = await autoSync.settle(held, resolution, expectedRevisionId: plan.revisionId);
    if (!context.mounted) return;
    result.outcome == SyncOutcome.failed ? await showCampusNotice(context, result.message) : showCampusToast(context, result.message);
  } catch (error, stack) {
    campusLog('[SyncMerge] action=held errorType=${error.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '课表没有改动，请稍后重试');
  }
}

String _termLabel(TermRef term) => term.label.isEmpty ? term.key : term.label;

// 打开合并页，退出时 resolution 为空。本机课表读不到、或比对之后又被改过时说明原因，failed 为真。
// 两边看不出差别（只是课程代码这类不显示的字段不同）时没什么可选的，不打开页面，直接用教务的那份（现在的留在历史版本里）。
Future<({ScheduleResolution? resolution, bool failed})> _openMergePage(BuildContext context, {required CampusGateway gateway, required TermRef term, required SyncPlan plan, required List<CourseRecord> edu}) async {
  final read = await gateway.readSchedule(ScheduleScope.term(term));
  if (!context.mounted) return (resolution: null, failed: true);
  final mine = read.data;
  if (!read.ok || mine == null || mine.revisionId != plan.revisionId) {
    await showCampusNotice(context, read.ok && mine != null ? '课表刚刚有改动，请重新同步' : read.error?.message ?? '读取本机课表失败，请重试');
    return (resolution: null, failed: true);
  }
  if (planScheduleMerge(mine.courses, edu).identical) return (resolution: const TakeEdu(), failed: false);
  final route = CampusPageRoute<ScheduleResolution>(builder: (_) => SyncMergePage(term: term, base: plan.base, mine: mine.courses, edu: edu));
  // 换账号时导航器连同这页一起销毁、不走返回，push 的结果就一直不来、同步那一轮一直挂着；completed 在页面销毁时也会完成（为空，同退出）。
  final resolution = await Future.any([Navigator.of(context, rootNavigator: true).push(route), route.completed]);
  return (resolution: resolution, failed: false);
}

enum _Mode { merge, replace }

class SyncMergePage extends StatefulWidget {
  const SyncMergePage({super.key, required this.term, required this.base, required this.mine, required this.edu});
  final TermRef term;
  final List<CourseRecord>? base;
  final List<CourseRecord> mine;
  final List<CourseRecord> edu;

  @override
  State<SyncMergePage> createState() => _SyncMergePageState();
}

class _SyncMergePageState extends State<SyncMergePage> {
  late final _plan = planScheduleMerge(widget.mine, widget.edu);
  late final _origins = scheduleMergeOrigins(_plan, base: widget.base, mine: widget.mine, theirs: widget.edu);
  var _mode = _Mode.merge;
  // 默认只勾只有教务改了的：你改过的、两边都改了的都先保留你的。
  late final _items = {
    for (final course in _plan.changed)
      if (_origins[course.name] == MergeOrigin.theirs) ...course.items.map((item) => item.id),
  };
  late final _added = {for (final group in _plan.added) if (_origins[_name(group)] == MergeOrigin.theirs) _name(group)};
  late final _removed = {for (final group in _plan.removed) if (_origins[_name(group)] == MergeOrigin.theirs) _name(group)};

  static String _name(List<CourseRecord> group) => group.first.courseName.trim();

  int get _picked => _items.length + _added.length + _removed.length;

  void _toggle(Set<String> selection, String name) => setState(() => selection.contains(name) ? selection.remove(name) : selection.add(name));

  String _caption(String name, {required String theirs, required String mine, required String both}) => switch (_origins[name]) {
    MergeOrigin.theirs || null => theirs,
    MergeOrigin.mine => mine,
    MergeOrigin.both => both,
  };

  Future<void> _apply() async {
    final ScheduleResolution resolution;
    if (_mode == _Mode.replace) {
      final mineCount = courseGroups(widget.mine).length, eduCount = courseGroups(widget.edu).length;
      if (!await showCampusConfirm(
        context,
        title: '换成教务课表？',
        message: '「${_termLabel(widget.term)}」现在的 $mineCount 门课会换成教务的 $eduCount 门课，你改过的地方都会换掉；现在的课表留在历史版本里，可以恢复。开学日和作息不变。',
        action: '换成教务的',
        destructive: true,
      )) {
        return;
      }
      resolution = const TakeEdu();
    } else if (_picked == 0) {
      resolution = const KeepLocal(remember: true);
    } else {
      final merged = applyEduMerge(_plan, base: widget.base, mine: widget.mine, theirs: widget.edu, items: _items, added: _added, removed: _removed, newLocalId: () => const Uuid().v4());
      // 合并出来的课表不合规（同一时段同一周重复、超过上限）时原地说明，留在这页换一种勾法，不等落库失败再整个重来。
      try {
        validateSchedule(normalizeSchedule(merged));
      } on ScheduleValidation catch (error) {
        await showCampusNotice(context, '这样合并不行：${error.message}');
        return;
      }
      if (!mounted) return;
      // 要从课表删掉的课先确认（教务这学期的课没了时，默认会删掉所有你没改过的课）。
      if (_removed.isNotEmpty &&
          !await showCampusConfirm(
            context,
            title: '删掉 ${_removed.length} 门课？',
            message: '${_removed.join('、')}\n\n会从你的课表删掉。现在的课表留在历史版本里，可以恢复。',
            action: '删掉',
            destructive: true,
          )) {
        return;
      }
      if (!mounted) return;
      // 改过的与新加的课和其余课的上课时间有重叠时先说明，仍要合并才存（同好友课表导入）。
      final touched = {
        for (final course in _plan.changed)
          if (course.items.any((item) => _items.contains(item.id))) course.name,
        ..._added,
      };
      final overlaps = {
        for (final course in merged)
          if (touched.contains(course.courseName.trim()))
            for (final overlap in courseOverlaps(course, merged))
              if (overlap.courseName.trim() != course.courseName.trim()) '${course.courseName} 与 ${overlap.label}',
      };
      if (overlaps.isNotEmpty && !await showCampusConfirm(context, title: '上课时间有重叠', message: '${overlaps.join('\n')}\n\n仍然合并？', action: '仍然合并')) {
        return;
      }
      final changedCount = _plan.changed.where((course) => course.items.any((item) => _items.contains(item.id))).length;
      final parts = [if (changedCount > 0) '改 $changedCount 门', if (_added.isNotEmpty) '加 ${_added.length} 门', if (_removed.isNotEmpty) '删 ${_removed.length} 门'];
      resolution = MergeEdu(merged, '合并教务课表：${parts.join('、')}');
    }
    if (mounted) Navigator.of(context).pop(resolution);
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final replace = _mode == _Mode.replace;
    final eduCount = courseGroups(widget.edu).length, mineCount = courseGroups(widget.mine).length;
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
            '你现在的 $mineCount 门课会换成教务的 $eduCount 门课，你改过的地方都会换掉。现在的课表留在历史版本里，可以恢复；开学日和作息不变。',
            style: TextStyle(fontSize: 16, height: 1.5, color: palette.onSurface),
          ),
        ),
      ];
    } else {
      body = [
        if (_plan.changed.isNotEmpty) ...[
          section('有改动 · ${_plan.changed.length} 门', note: '勾上的用教务的，没勾的保留你的'),
          for (final course in _plan.changed)
            MergeChangedCourse(
              course: course,
              caption: _caption(course.name, theirs: '教务改了', mine: '你改过，教务没变', both: '你和教务都改了'),
              selection: _items,
              enabled: true,
              onChanged: () => setState(() {}),
            ),
        ],
        if (_plan.added.isNotEmpty) ...[
          section('教务有你没有 · ${_plan.added.length} 门', note: '勾上的加进你的课表'),
          for (final group in _plan.added)
            MergeWholeCourse(
              group: group,
              caption: _caption(_name(group), theirs: '教务新加的', mine: '你删掉的', both: '你删掉后教务又改了'),
              picked: _added.contains(_name(group)),
              enabled: true,
              onTap: () => _toggle(_added, _name(group)),
            ),
        ],
        if (_plan.removed.isNotEmpty) ...[
          section('你有教务没有 · ${_plan.removed.length} 门', note: '勾上的从你的课表删掉'),
          for (final group in _plan.removed)
            MergeWholeCourse(
              group: group,
              caption: _caption(_name(group), theirs: '教务删掉了', mine: '你加的', both: '教务删掉了，你也改过'),
              picked: _removed.contains(_name(group)),
              removing: true,
              enabled: true,
              onTap: () => _toggle(_removed, _name(group)),
            ),
        ],
        if (_plan.same > 0) Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 0), child: Text('其余 ${_plan.same} 门两边一样', style: secondary)),
      ];
    }
    final label = replace ? '换成教务课表' : _picked == 0 ? '保留我的课表' : '应用 $_picked 项改动';
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('合并教务课表'),
      ),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: CampusScrollFade(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  DotSeparatedText('${_termLabel(widget.term)} · 教务的 $eduCount 门课', style: secondary),
                  const SizedBox(height: 12),
                  CampusSegmented<_Mode>(
                    values: _Mode.values,
                    selected: _mode,
                    label: (mode) => mode == _Mode.merge ? '逐项合并' : '整份替换',
                    onSelected: (mode) => setState(() => _mode = mode),
                  ),
                  ...body,
                ],
              ),
            ),
          ),
          // 底部主按钮是提示条的锚点，提示条停在它上方。
          CampusToastAnchor(child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              // 落库由同步（或打扰时机的处理）在返回后做，这里只交回选择。
              child: FilledButton.icon(
                style: replace ? campusDestructive : campusProminent,
                onPressed: _apply,
                icon: CampusIcon(replace ? CampusIcons.replaceSchedule : CampusIcons.mergeSchedule),
                label: Text(label),
              ),
            ),
          )),
        ]),
      ),
    );
  }
}
