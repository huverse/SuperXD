import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/common_free.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/share_card.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

enum _View { theirs, common }

// 好友分享的课表（只读快照）：按周看 TA 的课；“共同空闲”把自己同学期的课表按日期对齐叠上去，列出双方都没课的时段。
// 自己的课表只读本机（gateway.read 系列），不联网；没有同学期课表时只能看对方的。
class FriendSchedulePage extends StatefulWidget {
  const FriendSchedulePage({super.key, required this.friendName, required this.share, required this.sharedAt, this.gateway, this.outgoing = false});
  final String friendName;
  final ScheduleShare share;
  final String sharedAt;
  // 为空时不对比（未登录或测试）。
  final CampusGateway? gateway;
  // 自己发出的卡片：只看课表，不对比自己。
  final bool outgoing;
  @override
  State<FriendSchedulePage> createState() => _FriendSchedulePageState();
}

class _FriendSchedulePageState extends State<FriendSchedulePage> {
  late _View _view = widget.outgoing ? _View.theirs : _View.common;
  late final int _weekCount = math.max(termWeekCount(widget.share.courses), 1);
  late int _week = _initialWeek();
  bool _loadingMine = true;
  List<CourseRecord>? _myCourses;
  String? _myStart;
  List<BellPeriod> _myBells = const [];

  // 默认看对方学期里“今天”所在的周，超出范围时取第 1 周或最后一周。
  int _initialWeek() {
    final start = widget.share.termStartDate;
    if (start == null) return 1;
    return weekIndex(start, campusToday()).clamp(1, _weekCount);
  }

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  Future<void> _loadMine() async {
    final gateway = widget.gateway;
    if (gateway == null || widget.outgoing) {
      setState(() => _loadingMine = false);
      return;
    }
    try {
      final terms = await gateway.listTerms();
      final term = terms.data?.where((term) => term.key == widget.share.term.key).firstOrNull;
      if (term != null) {
        final schedule = await gateway.readSchedule(ScheduleScope.term(term));
        final bells = await gateway.readBells(term);
        if (schedule.ok && schedule.data != null && schedule.data!.revisionId != null) {
          _myCourses = schedule.data!.courses;
          _myStart = schedule.data!.termStartDate;
          _myBells = bells.data?.periods ?? const [];
        }
      }
    } catch (error, stack) {
      campusLog('[FriendSchedule] action=load_mine errorType=${error.runtimeType}\n$stack');
    } finally {
      if (mounted) setState(() => _loadingMine = false);
    }
  }

  List<BellPeriod> get _bells => widget.share.bells.isNotEmpty ? widget.share.bells : _myBells;

  void _showCourse(CourseRecord course, CourseMeeting meeting) => showCampusNotice(
    context,
    [meetingLabel(meeting), if (course.teacherName.isNotEmpty) course.teacherName].join('\n'),
    title: course.courseName,
  );

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final comparison = compareWeek(theirCourses: widget.share.courses, theirStart: widget.share.termStartDate, theirWeek: _week, myCourses: _myCourses, myStart: _myStart, bells: _bells);
    final common = _view == _View.common;
    final secondary = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
    final term = widget.share.term;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text('${widget.friendName}的课表'),
      ),
      body: CampusScrollFade(child: SafeArea(child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text('${term.label.isEmpty ? term.key : term.label} · ${formatCampusTimestamp(widget.sharedAt)} 分享', style: secondary),
        const SizedBox(height: 12),
        if (!widget.outgoing) ...[
          CampusSegmented<_View>(values: _View.values, selected: _view, label: (view) => view == _View.theirs ? 'TA的课表' : '共同空闲', onSelected: (view) => setState(() => _view = view)),
          const SizedBox(height: 12),
        ],
        Row(children: [
          IconButton(tooltip: '上一周', onPressed: _week > 1 ? () => setState(() => _week--) : null, icon: const CampusIcon(CampusIcons.back)),
          Expanded(child: Text('第 $_week 周', textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium)),
          IconButton(tooltip: '下一周', onPressed: _week < _weekCount ? () => setState(() => _week++) : null, icon: Transform.flip(flipX: true, child: const CampusIcon(CampusIcons.back))),
        ]),
        if (common && _loadingMine) const Padding(padding: EdgeInsets.all(24), child: CampusLoading(label: '读取我的课表'))
        else if (common && comparison.mine == null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('你这台设备上没有这个学期的课表，无法对比。可先在今天页同步该学年。', style: secondary))
        else if (common && !comparison.alignedByDate) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('有一方未设置开学日，按相同周次对比', style: secondary)),
        const SizedBox(height: 8),
        CampusSurface(padding: const EdgeInsets.fromLTRB(8, 12, 8, 12), child: _WeekGrid(comparison: comparison, courses: widget.share.courses, bells: _bells, common: common && comparison.mine != null, onCourse: _showCourse)),
        if (common && comparison.mine != null) ...[
          const SizedBox(height: 16),
          Text('本周共同空闲', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...switch (comparison.commonFree(_bells)) {
            final spans when spans.isEmpty => [Text('这一周没有共同空闲的时段', style: secondary)],
            final spans => [for (final span in spans) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(span.label, style: const TextStyle(fontSize: 16)))],
          },
        ],
      ]))),
    );
  }
}

// 周网格：列为星期、行为节次。TA 的课表模式下画课程块（点开看详情）；共同空闲模式下逐格标出谁有课，双方都空的格子着激活色。
class _WeekGrid extends StatelessWidget {
  const _WeekGrid({required this.comparison, required this.courses, required this.bells, required this.common, required this.onCourse});
  final WeekComparison comparison;
  final List<CourseRecord> courses;
  final List<BellPeriod> bells;
  final bool common;
  final void Function(CourseRecord course, CourseMeeting meeting) onCourse;

  @override
  Widget build(BuildContext context) {
    final colors = CampusPalette.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final rowHeight = 48.0 * scale;
    final labelWidth = 36.0 * scale;
    final days = comparison.weekdays;
    final periods = comparison.periodCount;
    final cell = TextStyle(fontSize: 14, color: colors.onSurfaceVariant, height: 1.15);
    return LayoutBuilder(builder: (context, constraints) {
      final columnWidth = (constraints.maxWidth - labelWidth) / days.length;
      Widget block({required int day, required int start, required int end, required Color color, required Widget child, VoidCallback? onTap, String? semantics}) => Positioned(
        left: labelWidth + days.indexOf(day) * columnWidth + 1.5,
        top: rowHeight * (start - 1) + 1.5,
        width: columnWidth - 3,
        height: rowHeight * (end - start + 1) - 3,
        child: Semantics(
          label: semantics,
          button: onTap != null,
          child: Material(color: color, borderRadius: BorderRadius.circular(8), clipBehavior: Clip.antiAlias, child: InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.all(3), child: child))),
        ),
      );
      final blocks = <Widget>[];
      if (!common) {
        for (final course in courses) {
          for (final meeting in course.meetings) {
            if (!meeting.weeks.contains(comparison.theirWeek) || !days.contains(meeting.weekday)) continue;
            blocks.add(block(
              day: meeting.weekday,
              start: meeting.periodStart,
              end: meeting.periodEnd,
              color: colors.surfaceSelected,
              onTap: () => onCourse(course, meeting),
              semantics: '周${weekdayLabel(meeting.weekday)} ${course.courseName}',
              child: Text(course.courseName, overflow: TextOverflow.fade, style: TextStyle(fontSize: 14, color: colors.onSurface, height: 1.15)),
            ));
          }
        }
      } else {
        for (final day in days) {
          for (var period = 1; period <= periods; period++) {
            final theirs = comparison.theirBusy(day, period), mine = comparison.myBusy(day, period)!;
            if (!theirs && !mine) {
              blocks.add(block(day: day, start: period, end: period, color: colors.accent.withValues(alpha: .22), semantics: '周${weekdayLabel(day)} 第$period节 共同空闲', child: const SizedBox.expand()));
            } else {
              final label = theirs && mine ? '都有' : theirs ? 'TA' : '我';
              blocks.add(block(day: day, start: period, end: period, color: colors.outlineSubtle.withValues(alpha: .35), semantics: '周${weekdayLabel(day)} 第$period节 ${theirs && mine ? '双方都有课' : '$label有课'}', child: Center(child: Text(label, maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: cell))));
            }
          }
        }
      }
      return Column(children: [
        Row(children: [
          SizedBox(width: labelWidth),
          for (final day in days) SizedBox(width: columnWidth, child: Text('周${weekdayLabel(day)}', textAlign: TextAlign.center, style: cell)),
        ]),
        const SizedBox(height: 6),
        SizedBox(height: rowHeight * periods, child: Stack(children: [
          for (var period = 1; period <= periods; period++) Positioned(
            left: 0,
            top: rowHeight * (period - 1),
            width: labelWidth,
            height: rowHeight,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('$period', style: TextStyle(fontSize: 14, color: colors.onSurface)),
            ]),
          ),
          ...blocks,
        ])),
      ]);
    });
  }
}
