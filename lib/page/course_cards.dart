import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/live_clock.dart';

String spanIdentity(PeriodSpan span) => span.empty ? span.key : '${span.key}:${span.meeting!.weekday}:${span.meeting!.place}';

Map<String, String> courseCountdowns(List<PeriodSpan> spans, List<BellPeriod> bells, String date, DateTime instant, {MeetingTime? Function(PeriodSpan)? timeOf}) {
  final now = campusInstant(instant);
  if (formatCampusDate(now) != date) return const {};
  final seconds = now.hour * 3600 + now.minute * 60 + now.second;
  PeriodSpan? current;
  PeriodSpan? next;
  var currentStart = -1;
  var currentEnd = -1;
  var nextStart = 86401;
  for (final span in spans.where((span) => !span.empty)) {
    final time = timeOf == null ? meetingTime(bells, span.meeting!) : timeOf(span);
    if (time == null) continue;
    final start = time.startMinute * 60;
    if (start <= seconds && seconds < time.endMinute * 60 && start > currentStart) { current = span; currentStart = start; currentEnd = time.endMinute * 60; }
    if (start > seconds && start < nextStart) { next = span; nextStart = start; }
  }
  return {
    if (current != null) spanIdentity(current): '距离下课还有${((currentEnd - seconds) / 60).ceil()}分钟',
    if (next != null) spanIdentity(next): '距离上课还有${((nextStart - seconds) / 60).ceil()}分钟',
  };
}

class CourseDayCards extends StatefulWidget {
  const CourseDayCards({super.key, required this.spans, required this.bells, required this.date, this.detailKey, this.onDetail, this.onEdit, this.onCreate, this.onArrange, this.header, this.physics, this.bottomInset = 0, this.obscuredBottom = 0});
  final List<PeriodSpan> spans;
  final List<BellPeriod> bells;
  final String date;
  final String? detailKey;
  final ValueChanged<String?>? onDetail;
  final ValueChanged<CourseRecord>? onEdit;
  final ValueChanged<PeriodSpan>? onCreate;
  final ValueChanged<PeriodSpan>? onArrange;
  final Widget? header;
  final ScrollPhysics? physics;
  final double bottomInset;
  // 列表底部被浮动玻璃栏覆盖的高度：卡片仍按可见区排布，内容可滚入玻璃下方透出。
  final double obscuredBottom;
  @override
  State<CourseDayCards> createState() => _CourseDayCardsState();
}

class _CourseDayCardsState extends State<CourseDayCards> with SingleTickerProviderStateMixin {
  final _fallbackTime = ValueNotifier(DateTime.now());
  late ValueNotifier<DateTime> _time;
  ValueNotifier<DateTime>? _clock;
  bool _active = true;
  String? _lastClockDay;
  final Map<String, MeetingTime?> _times = {};
  String? _dataStamp;
  late final _detail = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  late final _curve = CurvedAnimation(parent: _detail, curve: Curves.easeInOutCubic);
  final _scroll = ScrollController();
  String? _retainedDetail;
  double _restoreOffset = 0;
  String? _measureKey;
  double _height = 140;
  // 左侧时间列宽：按当前字体与字号量“00:00”，各卡对齐。
  double _timeWidth = 56;

  @override
  void initState() {
    super.initState();
    _retainedDetail = widget.detailKey;
    if (_retainedDetail != null) _detail.value = 1;
    _detail.addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) {
        setState(() => _retainedDetail = null);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) _scroll.jumpTo(_restoreOffset.clamp(0, _scroll.position.maxScrollExtent));
        });
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = LiveClock.maybeOf(context);
    final active = TickerMode.valuesOf(context).enabled;
    if (clock != _clock || active != _active) {
      _clock?.removeListener(_tick);
      _clock = clock;
      _active = active;
      if (_active) _clock?.addListener(_tick);
    }
    _time = _fallbackTime;
    if (_active) _tick();
  }

  void _tick() {
    final instant = _clock?.value ?? DateTime.now();
    final day = formatCampusDate(campusInstant(instant));
    // 非今天不更新分钟倒计时；午夜仍刷新一次日期归属。隐藏分支不挂时钟监听。
    if (_active && (widget.date == day || _lastClockDay != day)) _fallbackTime.value = instant;
    _lastClockDay = day;
  }

  @override
  void deactivate() { _clock?.removeListener(_tick); _clock = null; super.deactivate(); }

  @override
  void didUpdateWidget(CourseDayCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spans != widget.spans || oldWidget.bells != widget.bells) { _times.clear(); _dataStamp = null; _measureKey = null; }
    if (oldWidget.date != widget.date) _tick();
    if (oldWidget.detailKey == widget.detailKey) return;
    if (widget.detailKey != null) {
      _restoreOffset = _scroll.hasClients ? _scroll.offset : 0;
      _retainedDetail = widget.detailKey;
      _detail.forward();
      if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeInOutCubic);
    } else {
      _detail.reverse();
    }
    if (MediaQuery.disableAnimationsOf(context)) _detail.value = widget.detailKey == null ? 0 : 1;
  }

  @override
  void dispose() { _clock?.removeListener(_tick); _fallbackTime.dispose(); _curve.dispose(); _detail.dispose(); _scroll.dispose(); super.dispose(); }

  String _emptyName(PeriodSpan span) => span.start == 1 && span.end >= 2 ? '早八没课哦~' : '这几节没课';

  MeetingTime? _timeOf(PeriodSpan span) => _times.putIfAbsent(spanIdentity(span), () => periodTime(widget.bells, span.start, span.end));

  double _cardHeight(BuildContext context, double width, double available, Map<String, String> labels) {
    final scaler = MediaQuery.textScalerOf(context);
    final font = Theme.of(context).textTheme.bodyMedium!.fontFamily;
    _dataStamp ??= widget.spans.map((span) => '${span.key}:${span.course?.courseName}:${span.meeting?.place}:${span.course?.teacherName}:${_timeOf(span)?.label}').join('|');
    final stamp = '$font:${Localizations.localeOf(context)}:${Directionality.of(context)}:$width:$available:${scaler.scale(14)}:${scaler.scale(16)}:${labels.entries.map((entry) => '${entry.key}:${entry.value}').join('|')}:$_dataStamp';
    if (_measureKey == stamp) return _height;
    _measureKey = stamp;
    double measure(String text, double size, FontWeight weight, double maxWidth) {
      final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(fontFamily: font, fontSize: size, fontWeight: weight, height: 1.3, fontFeatures: const [FontFeature.tabularFigures()])), textDirection: Directionality.of(context), locale: Localizations.localeOf(context), textScaler: scaler)..layout(maxWidth: maxWidth);
      final height = maxWidth == double.infinity ? painter.width : painter.height;
      painter.dispose();
      return height;
    }
    // 字体不一定带等宽数字（衬线体没有 tnum），按本页实际出现的开始时间取最宽，避免“08:00”折行。
    _timeWidth = [for (final span in widget.spans) _timeOf(span)?.startLabel ?? '--:--', '00:00'].map((label) => measure(label, 20, FontWeight.w600, double.infinity)).reduce(math.max).ceilToDouble() + 1;
    final timeColumn = measure('00:00', 20, FontWeight.w600, 200) + measure('00:00', 14, FontWeight.w500, 200);
    final detailWidth = math.max(48.0, width - 28 - _timeWidth - 25);
    var contentHeight = timeColumn;
    for (final span in widget.spans) {
      var height = 2.0;
      for (final field in [
        ('第${span.start}–${span.end}节${_timeOf(span) == null ? ' · 作息时间未设置' : ''}', 14.0, FontWeight.w500),
        span.empty ? (_emptyName(span), 16.0, FontWeight.w500) : (span.course!.courseName, 17.0, FontWeight.w600),
        if (!span.empty) ('${span.meeting!.place} · ${span.course!.teacherName}', 14.0, FontWeight.w500),
        if (labels[spanIdentity(span)] != null) (labels[spanIdentity(span)]!, 14.0, FontWeight.w500),
      ]) {
        height += measure(field.$1, field.$2, field.$3, detailWidth);
      }
      if (!span.empty) height += 4;
      contentHeight = math.max(contentHeight, height);
    }
    final minimum = math.max(112.0, contentHeight + 34 + (labels.isEmpty ? 0 : 4));
    final slot = (available - (widget.spans.length - 1) * 8) / widget.spans.length;
    return _height = slot >= minimum ? math.min(slot, minimum * 1.12) : minimum;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.spans.isEmpty) {
      return Column(children: [
      if (widget.header != null) widget.header!,
      Expanded(child: Padding(padding: EdgeInsets.only(bottom: widget.obscuredBottom), child: const Center(child: Padding(padding: EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('这天没课', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        SizedBox(height: 12),
        Text('是放假了还是?反正今天一定很爽啦!', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5)),
      ]))))),
      ]);
    }
    return Column(children: [
      if (widget.header != null) widget.header!,
      Expanded(child: ValueListenableBuilder(valueListenable: _time, builder: (context, instant, _) => LayoutBuilder(builder: (context, constraints) {
      final labels = courseCountdowns(widget.spans, widget.bells, widget.date, instant, timeOf: _timeOf);
      final height = _cardHeight(context, constraints.maxWidth, constraints.maxHeight - widget.obscuredBottom, labels);
      // 顶部淡出只随实际滚动出现，最多24dp；遮罩层有无只由底栏决定，滚动不重建列表。
      return AnimatedBuilder(animation: _scroll, builder: (context, child) => ScrollEdgeFade(
        top: widget.obscuredBottom > 0 && _scroll.hasClients ? _scroll.offset.clamp(0.0, 24.0) : 0,
        bottom: widget.obscuredBottom, child: child!,
      ), child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _retainedDetail == null ? null : () => widget.onDetail?.call(null),
        child: ListView.builder(
          controller: _scroll, padding: EdgeInsets.zero, physics: widget.physics,
          itemCount: widget.spans.length + 1,
          itemBuilder: (context, index) {
            if (index == widget.spans.length) return SizedBox(height: (_retainedDetail == null ? 0 : 80) + widget.bottomInset + widget.obscuredBottom);
            final span = widget.spans[index];
            final key = spanIdentity(span);
            final selected = _retainedDetail == key;
            // [人工决策-2026-09-29 16:10:53] 有课卡与无课卡一致：仅长按展开详情与编辑入口，展开后点击收起，单击不展开；无课卡展开后再选新增课程或安排已有课程。
            final card = GestureDetector(
              onTap: selected ? () => widget.onDetail?.call(null) : () {},
              onLongPress: widget.onDetail == null || span.empty && widget.onCreate == null ? null : () => widget.onDetail!(key),
              child: CampusSurface(
                key: ValueKey('course-card-$key'), selected: selected, padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: AnimatedBuilder(animation: selected ? _curve : const AlwaysStoppedAnimation(0.0),
                builder: (context, child) => ConstrainedBox(constraints: BoxConstraints(minWidth: double.infinity, minHeight: height - 24 + (selected ? _curve.value * 80 : 0)), child: child),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                  _CourseCardBody(span: span, time: _timeOf(span), emptyName: _emptyName(span), countdown: labels[key], timeWidth: _timeWidth),
                  if (selected) SizeTransition(sizeFactor: _curve, alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.only(top: 12), child: span.empty ? Wrap(spacing: 8, children: [
                    if (widget.onCreate != null) TextButton.icon(onPressed: () => widget.onCreate!(span), icon: const CampusIcon(CampusIcons.add), label: const Text('新增课程')),
                    if (widget.onArrange != null) TextButton.icon(onPressed: () => widget.onArrange!(span), icon: const CampusIcon(CampusIcons.edit), label: const Text('安排已有课程')),
                  ]) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('学分 ${span.course?.credit ?? '—'}\n第${span.start}–${span.end}节', style: const TextStyle(fontSize: 14, height: 1.5)),
                    if (widget.onEdit != null) TextButton.icon(onPressed: () => widget.onEdit!(span.course!), icon: const CampusIcon(CampusIcons.edit), label: const Text('编辑课程')),
                  ]))),
                ])),
              ),
            );
            return AnimatedBuilder(animation: _retainedDetail == null ? const AlwaysStoppedAnimation(1.0) : _curve, child: RepaintBoundary(child: card), builder: (context, child) => ClipRect(child: Align(
              alignment: Alignment.topCenter, heightFactor: _retainedDetail != null && !selected ? 1 - _curve.value : 1,
              child: Padding(padding: EdgeInsets.only(bottom: index == widget.spans.length - 1 ? 0 : 8), child: child),
            )));
          },
        ),
      ));
    }))),
    ]);
  }
}

// 课程卡正文（同 iOS 日程、鸿蒙日程卡的层级）：左列开始时间加粗、结束时间次要，等宽数字各卡对齐；
// 中间一道竖条，有课为主色、空档为浅描边；右列节次、课名、地点与教师，倒计时在右下。空档整体降一级，不与有课卡同等醒目。
class _CourseCardBody extends StatelessWidget {
  const _CourseCardBody({required this.span, required this.time, required this.emptyName, required this.countdown, required this.timeWidth});
  final PeriodSpan span;
  final MeetingTime? time;
  final String emptyName;
  final String? countdown;
  final double timeWidth;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    const figures = [FontFeature.tabularFigures()];
    final time = this.time;
    return IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: timeWidth, child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(time?.startLabel ?? '--:--', maxLines: 1, softWrap: false, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3, fontFeatures: figures, color: span.empty ? palette.onSurfaceVariant : palette.onSurface)),
        if (time != null) Text(time.endLabel, maxLines: 1, softWrap: false, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, fontFeatures: figures, color: palette.onSurfaceVariant)),
      ])),
      const SizedBox(width: 10),
      DecoratedBox(decoration: BoxDecoration(color: span.empty ? palette.outlineSubtle : palette.primary, borderRadius: BorderRadius.circular(2)), child: const SizedBox(width: 3)),
      const SizedBox(width: 12),
      Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 缺作息时提示并在节次同一行，不额外占一行。
        Text.rich(TextSpan(children: [
          TextSpan(text: '第${span.start}–${span.end}节', style: TextStyle(color: span.empty ? palette.onSurfaceVariant : palette.primary)),
          if (time == null) TextSpan(text: ' · 作息时间未设置', style: TextStyle(color: palette.onSurfaceVariant)),
        ]), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3)),
        const SizedBox(height: 2),
        span.empty
            ? Text(emptyName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, height: 1.3, color: palette.onSurfaceVariant))
            : Text(span.course!.courseName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface)),
        if (!span.empty) ...[
          const SizedBox(height: 4),
          Text('${span.meeting!.place} · ${span.course!.teacherName}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: palette.onSurfaceVariant)),
          if (countdown != null) Align(alignment: Alignment.centerRight, child: Text(countdown!, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: palette.primary))),
        ],
      ])),
    ]));
  }
}
