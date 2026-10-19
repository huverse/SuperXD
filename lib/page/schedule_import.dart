import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// [人工决策-2026-10-19 16:08:42] 好友分享的课表可以导入（用户选定，取代 10-04 的「接收方只读、不覆盖自己的课表」，同 WakeUp 课程表、小爱课程表导入分享）：
// 整份替换这学期的课表，或挑几门加进来（比如一起上的选修课）。都存成当前账号的新版本、可在历史版本恢复，开学日和作息不动；
// 之后教务同步要覆盖时照旧先问。只读写本机，不联网；本机没有这个学期时说明原因，不替用户同步。
Future<void> importSharedSchedule(BuildContext context, {required CampusGateway gateway, required ScheduleShare share, required String friendName}) async {
  final mode = await showCampusSheet<String>(context: context, builder: (context) => _ImportChoice(share: share, friendName: friendName));
  if (mode == null || !context.mounted) return;
  try {
    final terms = await gateway.listTerms();
    final term = terms.data?.where((term) => term.key == share.term.key).firstOrNull;
    if (!context.mounted) return;
    final termLabel = share.term.label.isEmpty ? share.term.key : share.term.label;
    if (term == null) {
      await showCampusNotice(context, '你的账号里还没有「$termLabel」，先在今天页同步这个学年再导入。');
      return;
    }
    final read = await gateway.readSchedule(ScheduleScope.term(term));
    if (!context.mounted) return;
    final mine = read.data;
    if (!read.ok || mine == null) {
      await showCampusNotice(context, read.error?.message ?? '读取本机课表失败，请重试');
      return;
    }
    final List<CourseRecord> courses;
    final String summary;
    if (mode == 'replace') {
      final fresh = mine.revisionId == null;
      if (!await showCampusConfirm(
        context,
        title: fresh ? '导入这份课表？' : '替换这学期的课表？',
        message: fresh
            ? '会用$friendName分享的 ${courseGroups(share.courses).length} 门课建立「$termLabel」的课表。开学日和作息不变。'
            : '「$termLabel」现在的 ${courseGroups(mine.courses).length} 门课会换成$friendName分享的 ${courseGroups(share.courses).length} 门课，存成一个新版本；现在的课表留在历史版本里，可以恢复。开学日和作息不变。',
        action: fresh ? '导入' : '替换',
        destructive: !fresh,
      )) {
        return;
      }
      courses = share.courses;
      summary = '导入$friendName分享的课表';
    } else {
      if (!context.mounted) return;
      final picked = await showCampusSheet<List<CourseRecord>>(context: context, builder: (context) => _CoursePicker(share: share, mine: mine.courses, friendName: friendName));
      if (picked == null || picked.isEmpty || !context.mounted) return;
      final overlaps = [for (final course in picked) ...courseOverlaps(course, mine.courses)];
      if (overlaps.isNotEmpty &&
          !await showCampusConfirm(
            context,
            title: '上课时间有重叠',
            message: '${overlaps.map((overlap) => overlap.label).join('\n')}\n\n仍然加进来？',
            action: '仍然加入',
          )) {
        return;
      }
      final names = courseGroups(picked).map((group) => group.first.courseName).toList();
      courses = [...mine.courses, ...picked];
      summary = '加入$friendName分享的课程：${names.take(3).join('、')}${names.length > 3 ? ' 等 ${names.length} 门' : ''}';
    }
    if (!context.mounted) return;
    final saved = await showCampusWaiting(context, label: '正在导入课表', operation: () => gateway.saveScheduleRevision(term, courses, summary, expectedRevisionId: mine.revisionId));
    if (!context.mounted) return;
    if (!saved.ok) {
      await showCampusNotice(context, saved.error?.message ?? '导入未完成，课表没有改动');
      return;
    }
    // 成功轻触一次（人工决策见 chaoxing_sign_sheet.dart 的 _finishIfDone）。
    HapticFeedback.successNotification();
    showCampusToast(context, mode == 'replace' ? '已换成$friendName的课表，可在历史版本恢复' : '已加进你的课表，可在历史版本恢复');
  } catch (error, stack) {
    campusLog('[ScheduleImport] action=$mode errorType=${error.runtimeType}\n$stack');
    if (context.mounted) await showCampusNotice(context, '导入未完成，课表没有改动');
  }
}

// 第一步：整份替换，还是挑几门加进来。
class _ImportChoice extends StatelessWidget {
  const _ImportChoice({required this.share, required this.friendName});
  final ScheduleShare share;
  final String friendName;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    Widget option(String value, IconData icon, String title, String detail) => CampusSurface(
      margin: const EdgeInsets.only(bottom: 8),
      radius: 16,
      onTap: () => Navigator.pop(context, value),
      child: Row(children: [
        CampusIcon(icon, color: palette.primary),
        const SizedBox(width: 16),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 2),
          Text(detail, style: secondary),
        ])),
      ]),
    );
    return CampusSheetPanel(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text('导入$friendName的课表', style: Theme.of(context).textTheme.titleLarge),
              )),
              IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
            ]),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              child: DotSeparatedText('${share.term.label.isEmpty ? share.term.key : share.term.label} · ${courseGroups(share.courses).length} 门课', style: secondary),
            ),
            option('replace', CampusIcons.replaceSchedule, '替换我这学期的课表', '现在的课表留在历史版本里'),
            option('pick', CampusIcons.addCourses, '挑几门加进来', '比如一起上的选修课'),
          ],
        ),
      ),
    );
  }
}

// 第二步：勾选要加进来的课（按课名合成一门）；自己已有的同一个教学班不重复加。
class _CoursePicker extends StatefulWidget {
  const _CoursePicker({required this.share, required this.mine, required this.friendName});
  final ScheduleShare share;
  final List<CourseRecord> mine;
  final String friendName;
  @override
  State<_CoursePicker> createState() => _CoursePickerState();
}

class _CoursePickerState extends State<_CoursePicker> {
  late final _owned = {for (final course in widget.mine) courseKey(course)};
  late final _groups = [
    for (final group in courseGroups(widget.share.courses))
      if (group.where((course) => !_owned.contains(courseKey(course))).toList() case final fresh when fresh.isNotEmpty) fresh,
  ];
  late final _skipped = courseGroups(widget.share.courses).length - _groups.length;
  final _picked = <int>{};

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    return CampusSheetPanel(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 16, 0),
            child: Row(children: [
              Expanded(child: Text('挑几门加进来', style: Theme.of(context).textTheme.titleLarge)),
              IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
            ]),
          ),
          if (_skipped > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('你已有的 $_skipped 门没有列出', style: secondary),
            ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              children: [
                if (_groups.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('这些课你的课表里都有了', style: secondary)),
                for (final (index, group) in _groups.indexed)
                  // 整行点按勾选（同签到对象），读屏把勾选框与课名、时段合成一项。
                  CampusSurface(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                    radius: 16,
                    child: MergeSemantics(child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => setState(() => _picked.contains(index) ? _picked.remove(index) : _picked.add(index)),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Checkbox(value: _picked.contains(index), onChanged: (value) => setState(() => value == true ? _picked.add(index) : _picked.remove(index))),
                        Expanded(child: Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(group.first.courseName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface)),
                            for (final slot in courseSlots(group)) DotSeparatedText(slotLabel(slot), style: secondary.copyWith(height: 1.5)),
                          ]),
                        )),
                      ]),
                    )),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: FilledButton.icon(
              style: campusProminent,
              onPressed: _picked.isEmpty ? null : () => Navigator.pop(context, [for (final index in _picked.toList()..sort()) ..._groups[index]]),
              icon: const CampusIcon(CampusIcons.addCourses),
              label: Text(_picked.isEmpty ? '加进来' : '加进来 ${_picked.length} 门'),
            ),
          ),
        ],
      ),
    );
  }
}
