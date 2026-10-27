import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/theme/campus_field_table.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/live_clock.dart';

String spanIdentity(PeriodSpan span) => span.empty ? span.key : '${span.key}:${span.meeting!.weekday}:${span.meeting!.place}';

// 今天此刻的上课状态（同 iOS 实时活动：有明确起止就画进度）。只对今天计算，其他日子为空。
// progress：已开始各节的进度，已下课为 1，上课中为已过比例；focus：正在上的课，没有就是下一节。
// 进度条起止：上课中是上课到下课；课间是上一节下课到下一节上课；第一节课前没有起点，只显示剩余时长。
class ClassMoment {
  const ClassMoment({this.progress = const {}, this.focus, this.ongoing = false, this.seconds = 0, this.target = 0, this.from, this.fromLabel = '', this.targetLabel = ''});
  final Map<String, double> progress;
  final PeriodSpan? focus;
  final bool ongoing;
  // 均为校园时区当天的秒数。
  final int seconds;
  final int target;
  final int? from;
  final String fromLabel;
  final String targetLabel;
  int get remainingMinutes => ((target - seconds) / 60).ceil();
  double? get fraction => from == null ? null : ((seconds - from!) / (target - from!)).clamp(0.0, 1.0);
}

ClassMoment classMoment(List<PeriodSpan> spans, List<BellPeriod> bells, String date, DateTime instant, {MeetingTime? Function(PeriodSpan)? timeOf}) {
  final now = campusInstant(instant);
  if (formatCampusDate(now) != date) return const ClassMoment();
  final seconds = now.hour * 3600 + now.minute * 60 + now.second;
  final progress = <String, double>{};
  (PeriodSpan, MeetingTime)? current, next, previous;
  for (final span in spans.where((span) => !span.empty)) {
    final time = timeOf == null ? meetingTime(bells, span.meeting!) : timeOf(span);
    if (time == null) continue;
    final start = time.startMinute * 60, end = time.endMinute * 60;
    if (end <= seconds) {
      progress[spanIdentity(span)] = 1;
      if (previous == null || end > previous.$2.endMinute * 60) previous = (span, time);
    } else if (start <= seconds) {
      progress[spanIdentity(span)] = (seconds - start) / (end - start);
      if (current == null || start > current.$2.startMinute * 60) current = (span, time);
    } else if (next == null || start < next.$2.startMinute * 60) {
      next = (span, time);
    }
  }
  if (current case (final span, final time)) {
    return ClassMoment(progress: progress, focus: span, ongoing: true, seconds: seconds, target: time.endMinute * 60, from: time.startMinute * 60, fromLabel: time.startLabel, targetLabel: time.endLabel);
  }
  if (next case (final span, final time)) {
    return ClassMoment(progress: progress, focus: span, seconds: seconds, target: time.startMinute * 60, from: previous == null ? null : previous.$2.endMinute * 60, fromLabel: previous?.$2.endLabel ?? '', targetLabel: time.startLabel);
  }
  return ClassMoment(progress: progress, seconds: seconds);
}

// 时长按小时分钟写：不足一小时“45分钟”，整点“2小时”，其余“1小时05分”（分钟补零，数字跳动时宽度不变）。
// 返回数字与单位分段，界面把数字放大、单位缩小；拼起来就是读屏与提示用的完整文字。
List<(String, bool)> classDurationParts(int minutes) {
  final hours = minutes ~/ 60, rest = minutes % 60;
  if (hours == 0) return [('$rest', true), ('分钟', false)];
  if (rest == 0) return [('$hours', true), ('小时', false)];
  return [('$hours', true), ('小时', false), (rest.toString().padLeft(2, '0'), true), ('分', false)];
}

String classDuration(int minutes) => classDurationParts(minutes).map((part) => part.$1).join();

// 有课卡的只读详情（今天页与课表页单击有课卡都打开它）：当天节次与时段、地点、教师、学分与这门课的全部上课时段；
// 给了 onEdit（课表页）时底部有「编辑课程」，点了先关详情再进编辑。次要色在弹层自己的 builder 里取，开着时切深浅色也跟着变。
Future<void> showCourseDetail(BuildContext context, {required PeriodSpan span, required List<CourseRecord> courses, required List<BellPeriod> bells, VoidCallback? onEdit}) {
  final key = courseKey(span.course!);
  final course = courses.firstWhere((course) => courseKey(course) == key, orElse: () => span.course!);
  final time = meetingTime(bells, span.meeting!);
  return showCampusSheet<void>(context: context, builder: (context) {
    final secondary = TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurfaceVariant);
    return CampusSheetPanel(child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 10), child: BalancedText(course.courseName, style: Theme.of(context).textTheme.titleLarge))),
          IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
        ]),
        Text('${periodLabel(span.start, span.end)}${time == null ? '' : ' · ${time.label}'}', style: secondary),
        const SizedBox(height: 16),
        Padding(padding: const EdgeInsets.only(right: 12), child: CampusFieldTable(rows: [
          ('地点', span.meeting!.place),
          ('教师', course.teacherName),
          ('学分', switch (course.credit) { final credit? => creditLabel(credit), null => '' }),
        ])),
        const SizedBox(height: 16),
        Text('上课时段', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        for (final meeting in course.meetings) Padding(padding: const EdgeInsets.fromLTRB(0, 4, 12, 4), child: DotSeparatedText(meetingLabel(meeting), style: const TextStyle(fontSize: 14, height: 1.5))),
        if (onEdit != null) ...[
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.only(right: 12), child: SizedBox(width: double.infinity, child: FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              onEdit();
            },
            icon: const CampusIcon(CampusIcons.edit),
            label: const Text('编辑课程'),
          ))),
        ],
      ]),
    ));
  });
}

class CourseDayCards extends StatefulWidget {
  const CourseDayCards({super.key, required this.spans, required this.bells, required this.date, this.detailKey, this.onDetail, this.onEdit, this.onCreate, this.onArrange, this.onOpen, this.header, this.physics, this.bottomInset = 0, this.obscuredBottom = 0, this.revealNow = false});
  final List<PeriodSpan> spans;
  final List<BellPeriod> bells;
  final String date;
  final String? detailKey;
  final ValueChanged<String?>? onDetail;
  final ValueChanged<CourseRecord>? onEdit;
  final ValueChanged<PeriodSpan>? onCreate;
  final ValueChanged<PeriodSpan>? onArrange;
  // 单击有课卡（今天页弹只读详情）；课表页不传，仍只认长按。
  final ValueChanged<PeriodSpan>? onOpen;
  final Widget? header;
  final ScrollPhysics? physics;
  final double bottomInset;
  // 列表底部被浮动玻璃栏覆盖的高度：卡片仍按可见区排布，内容可滚入玻璃下方透出。
  final double obscuredBottom;
  // 今天页：打开时把正在上或下一节滚进可见区（同 Google 日历打开即定位到此刻）；课表页不传。
  // [人工决策-2026-10-18 14:49:51] 用户选定；只在列表创建时定位一次，之后到点换课不移动用户正在看的内容。
  final bool revealNow;
  @override
  State<CourseDayCards> createState() => _CourseDayCardsState();
}

// 首次布局前才知道各卡高度：打开时的偏移在 LayoutBuilder 里算好，滚动位置创建时读取。
class _OpeningScrollController extends ScrollController {
  double opening = 0;
  @override
  double get initialScrollOffset => opening;
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
  final _scroll = _OpeningScrollController();
  String? _retainedDetail;
  double _restoreOffset = 0;
  String? _measureKey;
  double _height = 140;
  double _rowHeight = 48;
  // 左侧时间列宽：按当前字体与字号量“00:00”，各卡对齐。
  double _timeWidth = 56;
  // 内容一栏太窄时改两栏，时刻写在内容第一行（见 _cardHeight）。
  bool _stacked = false;

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

  String _emptyName(PeriodSpan span) => span.start == 1 && span.end >= 2 ? '早八没课哦~' : '没课';

  // 空档高度随时长增长（对数压缩，45 分钟起每翻倍加 16、最多加 40）：不读字也能看出空当长短
  // （Structured 用户反馈“30 分钟的空当和两小时看起来一样”）；不按真实比例，免得长空当把课挤出屏幕。
  double _gapHeight(PeriodSpan span) {
    final time = _timeOf(span);
    if (time == null) return _rowHeight;
    final minutes = math.max(1, time.endMinute - time.startMinute);
    return _rowHeight + (16 * math.log(minutes / 45) / math.ln2).clamp(0.0, 40.0);
  }

  MeetingTime? _timeOf(PeriodSpan span) => _times.putIfAbsent(spanIdentity(span), () => periodTime(widget.bells, span.start, span.end));

  // 读屏整卡一句（同 iOS 日历事件）：课名、教室、时段、节次、教师、此刻状态。
  String _spoken(PeriodSpan span, double? progress) {
    final time = _timeOf(span);
    return [span.course!.courseName, span.meeting!.place, if (time != null) '${time.startLabel}到${time.endLabel}', periodLabel(span.start, span.end), span.course!.teacherName, if (progress == 1) '已下课' else if (progress != null) '上课中，已过${(progress * 100).round()}%'].where((part) => part.isNotEmpty).join('，');
  }

  // 打开今天时正在上或下一节在可见区外（课多或字号大）：滚到它的上沿，已下课的课滚出上方；放得下就不动。
  // 卡片等高、空档按 _gapHeight，与列表实际排布一致，所以首帧就停在目标位置，不先画在顶部再跳。
  double _openingOffset(PeriodSpan? focus, double cardHeight, double viewport) {
    if (focus == null) return 0;
    double extent(PeriodSpan span) => (span.empty ? _gapHeight(span) : cardHeight) + 8;
    final index = widget.spans.indexWhere((span) => spanIdentity(span) == spanIdentity(focus));
    final top = widget.spans.take(index).fold(0.0, (sum, span) => sum + extent(span));
    if (top + cardHeight <= viewport - widget.obscuredBottom - widget.bottomInset) return 0;
    final total = widget.spans.fold(0.0, (sum, span) => sum + extent(span)) - 8 + widget.bottomInset + widget.obscuredBottom;
    return math.min(top, math.max(0.0, total - viewport));
  }

  double _cardHeight(BuildContext context, double width, double available) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = DefaultTextStyle.of(context).style;
    _dataStamp ??= widget.spans.map((span) => '${span.key}:${span.course?.courseName}:${span.meeting?.place}:${span.course?.teacherName}:${_timeOf(span)?.label}').join('|');
    final stamp = '${base.fontFamily}:${base.letterSpacing}:${MediaQuery.boldTextOf(context)}:${Localizations.localeOf(context)}:${Directionality.of(context)}:$width:$available:${scaler.scale(14)}:${scaler.scale(16)}:$_dataStamp';
    if (_measureKey == stamp) return _height;
    _measureKey = stamp;
    // 与卡片里的 Text 同一口径（默认样式的字距、系统粗体文本），见 theme/campus_typesetting.dart。
    double measure(String text, double size, FontWeight weight, double maxWidth) {
      final painter = campusTextPainter(context, text, style: TextStyle(fontSize: size, fontWeight: weight, height: 1.3, fontFeatures: const [FontFeature.tabularFigures()]), maxWidth: maxWidth);
      final height = maxWidth == double.infinity ? painter.width : painter.height;
      painter.dispose();
      return height;
    }
    // 字体不一定带等宽数字（衬线体没有 tnum），按本页实际出现的开始时间取最宽，避免“08:00”折行。
    // 开始前开始时刻大、开始后下课时刻大，两个都按大号量。
    _timeWidth = [for (final span in widget.spans) ...[_timeOf(span)?.startLabel ?? '--:--', ?_timeOf(span)?.endLabel], '00:00'].map((label) => measure(label, 20, FontWeight.w600, double.infinity)).reduce(math.max).ceilToDouble() + 1;
    // 三栏（时刻列 │ 竖条 │ 内容）里内容一栏放不下六个课名字时改两栏：时刻挪到内容第一行（「08:00–09:40」），课名、教室吃满竖条右边的整宽。
    // 学期视图左边还有月份周次栏，窄屏大字号下内容一栏曾只剩两个字宽，课名、教室一两个字一行。正常宽度照旧三栏。
    final columns = width - 28 - _timeWidth - 25;
    _stacked = columns < measure('国国国国国国', 17, FontWeight.w600, double.infinity);
    final detailWidth = _stacked ? width - 28 - 15 : math.max(48.0, columns);
    final timeColumn = _stacked ? 0.0 : measure('00:00', 20, FontWeight.w600, 200) + measure('00:00', 14, FontWeight.w500, 200);
    final timeRow = _stacked ? measure('00:00–00:00', 16, FontWeight.w600, detailWidth) + 2 : 0.0;
    // 空档是一行（触区不低于 48），只有有课卡分剩余高度。
    // 空档两行（时长标题 16、节次 14）的基础高度，触区不低于 48；再按时长加高，见 _gapHeight。两栏时上面多一行时刻。
    _rowHeight = math.max(48.0, timeRow + measure('00:00', 16, FontWeight.w600, 200) + measure('00:00', 14, FontWeight.w500, 200) + 18);
    final occupied = widget.spans.where((span) => !span.empty).toList();
    var contentHeight = timeColumn;
    for (final span in occupied) {
      final place = span.meeting!.place;
      var height = (place.isEmpty ? 4.0 : 8.0) + timeRow;
      for (final field in [
        (span.course!.courseName, 17.0, FontWeight.w600, detailWidth),
        // 教室行左边让出定位图标与间距。
        if (place.isNotEmpty) (place, 16.0, FontWeight.w600, detailWidth - 20),
        ('${periodLabel(span.start, span.end)}${_timeOf(span) == null ? ' · 作息时间未设置' : ''} · ${span.course!.teacherName}', 14.0, FontWeight.w500, detailWidth),
      ]) {
        height += measure(field.$1, field.$2, field.$3, field.$4);
      }
      contentHeight = math.max(contentHeight, height);
    }
    final minimum = math.max(112.0, contentHeight + 34);
    final gaps = widget.spans.where((span) => span.empty).fold(0.0, (sum, span) => sum + _gapHeight(span));
    final slot = (available - (widget.spans.length - 1) * 8 - gaps) / math.max(1, occupied.length);
    return _height = slot >= minimum ? math.min(slot, minimum * 1.12) : minimum;
  }

  @override
  Widget build(BuildContext context) {
    // 没课只说一次：今天页由顶部卡片说，课表页没有顶部卡片才在中间写。
    if (widget.spans.isEmpty) {
      return Column(children: [
      if (widget.header != null) widget.header!,
      Expanded(child: widget.header != null ? const SizedBox.expand() : Padding(padding: EdgeInsets.only(bottom: widget.obscuredBottom), child: const Center(child: Padding(padding: EdgeInsets.all(24),
        child: Text('这天没课', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      )))),
      ]);
    }
    return Column(children: [
      if (widget.header != null) widget.header!,
      Expanded(child: ValueListenableBuilder(valueListenable: _time, builder: (context, instant, _) => LayoutBuilder(builder: (context, constraints) {
      final moment = classMoment(widget.spans, widget.bells, widget.date, instant, timeOf: _timeOf);
      final progress = moment.progress;
      // 底部留白（今天页的“今天”胶囊）也不参与铺满：卡片排在胶囊上方，静止时最后一节课不被盖住。
      final height = _cardHeight(context, constraints.maxWidth, constraints.maxHeight - widget.obscuredBottom - widget.bottomInset);
      if (widget.revealNow && !_scroll.hasClients) _scroll.opening = _openingOffset(moment.focus, height, constraints.maxHeight);
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
            // [人工决策-2026-09-29 16:10:53] 有课卡与无课卡一致：长按展开详情与编辑入口，展开后点击收起；无课卡展开后再选新增课程或安排已有课程。
            // （原有「单击不展开」与 10-06 的「课表页仍按上条」已被下一条取代。）
            // [人工决策-2026-10-06 13:06:11] 今天页（只读、不传 onDetail）单击有课卡经 onOpen 弹只读详情（用户选定）。
            // [人工决策-2026-10-19 17:55:48] 课表页有课卡单击也经 onOpen 弹只读详情（同今天页，详情里有「编辑课程」），长按照旧展开（用户选定；
            // 同一张卡两页手势一致，HIG：长按只做快捷方式、不能是唯一入口）。空档仍只认长按。
            final actions = selected ? SizeTransition(sizeFactor: _curve, alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.only(top: 12), child: span.empty ? Wrap(spacing: 8, children: [
              if (widget.onCreate != null) TextButton.icon(onPressed: () => widget.onCreate!(span), icon: const CampusIcon(CampusIcons.add), label: const Text('新增课程')),
              if (widget.onArrange != null) TextButton.icon(onPressed: () => widget.onArrange!(span), icon: const CampusIcon(CampusIcons.edit), label: const Text('安排已有课程')),
            ]) : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('学分 ${switch (span.course?.credit) { final credit? => creditLabel(credit), null => '—' }}\n${periodLabel(span.start, span.end)}', style: const TextStyle(fontSize: 14, height: 1.5)),
              if (widget.onEdit != null) TextButton.icon(onPressed: () => widget.onEdit!(span.course!), icon: const CampusIcon(CampusIcons.edit), label: const Text('编辑课程')),
            ]))) : null;
            // [人工决策-2026-10-18 14:49:51] 今天页有课卡按下整块变暗（同全应用列表行）、读屏整卡读成一句并标为按钮（用户选定）。
            final open = !selected && !span.empty && widget.onOpen != null ? () => widget.onOpen!(span) : null;
            final card = GestureDetector(
              onTap: selected ? () => widget.onDetail?.call(null) : open == null ? () {} : null,
              onLongPress: widget.onDetail == null || span.empty && widget.onCreate == null ? null : () => widget.onDetail!(key),
              child: span.empty
                  ? _EmptySlot(key: ValueKey('course-card-$key'), span: span, time: _timeOf(span), name: _emptyName(span), minHeight: _gapHeight(span), timeWidth: _timeWidth, stacked: _stacked, reveal: selected ? _curve : const AlwaysStoppedAnimation(0.0), actions: actions)
                  : CampusSurface(
                      key: ValueKey('course-card-$key'), selected: selected, padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), onTap: open,
                      child: AnimatedBuilder(animation: selected ? _curve : const AlwaysStoppedAnimation(0.0),
                      builder: (context, child) => ConstrainedBox(constraints: BoxConstraints(minWidth: double.infinity, minHeight: height - 24 + (selected ? _curve.value * 80 : 0)), child: child),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                        _CourseCardBody(span: span, time: _timeOf(span), progress: progress[key], timeWidth: _timeWidth, stacked: _stacked),
                        ?actions,
                      ])),
                    ),
            );
            // [人工决策-2026-10-18 15:18:41] 课表页有课卡（只认长按）读屏同样读整句，长按动作提示“展开详情”；展开后不再合并，编辑入口单独可达（用户从走查清单选定）。
            final labelled = open != null
                ? Semantics(button: true, label: _spoken(span, progress[key]), onTap: open, onLongPress: widget.onDetail == null ? null : () => widget.onDetail!(key), onLongPressHint: widget.onDetail == null ? null : '展开详情', excludeSemantics: true, child: card)
                : !span.empty && !selected && widget.onDetail != null
                    ? Semantics(label: _spoken(span, progress[key]), onLongPress: () => widget.onDetail!(key), onLongPressHint: '展开详情', excludeSemantics: true, child: card)
                    : card;
            return AnimatedBuilder(animation: _retainedDetail == null ? const AlwaysStoppedAnimation(1.0) : _curve, child: RepaintBoundary(child: labelled), builder: (context, child) => ClipRect(child: Align(
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

// 课程卡正文（同 iOS 日程、Google 日历的层级）：左列时刻，等宽数字各卡对齐；中间一道主色竖条；
// 右列课名、教室（定位图标、正文色半粗）、节次与教师（次要色）。学生最关心上什么课、去哪上，教室不再混在次要行里。
// 左列开始前上课时刻大，开始后（上课中与已下课）下课时刻大，切换时字号平滑过渡；不是今天的日子上课时刻大。
// 今天的课按此刻分三态（同 iOS 日历、Google 日历的当日视图）：上课中的竖条自上而下按已过时间填满激活色；
// 已下课的整卡内容淡到 55%（同 iOS 日历的过去事件，卡底不变）；没开始的不变。剩余时长只在顶部“此刻”卡里显示，卡片不重复文字倒计时。
// [人工决策-2026-10-06 13:06:11] 已下课改为整卡内容淡化（取代只把课名转次要色），用户选定。
// [人工决策-2026-10-18 14:49:51] 教室单独一行带定位图标、节次与教师并到末行（用户从图标行、右侧大号房间号、节次进左列三种实物中选定图标行）；
// 时刻列开始前上课时刻大、开始后下课时刻大，已下课也是下课时刻大（用户选定，未选“只有上课中放大下课”）。
// 内容一栏太窄时（stacked）去掉时刻列，时刻写在内容第一行「08:00–09:40」，该放大的那个时刻用正文色半粗、另一个次要色，规则同时刻列。
class _CourseCardBody extends StatelessWidget {
  const _CourseCardBody({required this.span, required this.time, required this.progress, required this.timeWidth, required this.stacked});
  final PeriodSpan span;
  final MeetingTime? time;
  // 今天已开始的课：1 为已下课，其余为上课中已过的比例；没开始或不是今天为空。
  final double? progress;
  final double timeWidth;
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    const figures = [FontFeature.tabularFigures()];
    final time = this.time;
    final progress = this.progress;
    final done = progress == 1;
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600);
    final big = TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3, fontFeatures: figures, color: palette.onSurface);
    final small = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, fontFeatures: figures, color: palette.onSurfaceVariant);
    // 动画样式整体替换默认样式，先合并上默认样式，不丢应用字体。
    Widget clock(String label, bool emphasized) => AnimatedDefaultTextStyle(style: DefaultTextStyle.of(context).style.merge(emphasized ? big : small), duration: duration, curve: Curves.easeOutCubic, maxLines: 1, softWrap: false, child: Text(label));
    TextSpan inline(String label, bool emphasized) => TextSpan(text: label, style: emphasized ? small.copyWith(fontSize: 16, fontWeight: FontWeight.w600, color: palette.onSurface) : small);
    final place = span.meeting!.place;
    return AnimatedOpacity(
      opacity: done ? .55 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!stacked) ...[
          SizedBox(width: timeWidth, child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            clock(time?.startLabel ?? '--:--', time == null || progress == null),
            if (time != null) clock(time.endLabel, progress != null),
          ])),
          const SizedBox(width: 10),
        ],
        progress != null && !done
            ? _ProgressStripe(progress: progress)
            : DecoratedBox(decoration: BoxDecoration(color: palette.primary, borderRadius: BorderRadius.circular(2)), child: const SizedBox(width: 3)),
        const SizedBox(width: 12),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (stacked) ...[
            Text.rich(TextSpan(children: [inline(time?.startLabel ?? '--:--', time == null || progress == null), if (time != null) ...[TextSpan(text: '–', style: small), inline(time.endLabel, progress != null)]]), style: const TextStyle(height: 1.3)),
            const SizedBox(height: 2),
          ],
          BalancedText(span.course!.courseName, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface)),
          if (place.isNotEmpty) ...[const SizedBox(height: 4), CoursePlace(place)],
          const SizedBox(height: 4),
          // 缺作息时提示并在节次同一行，不额外占一行。
          DotSeparatedText([periodLabel(span.start, span.end), if (time == null) '作息时间未设置', span.course!.teacherName].where((part) => part.isNotEmpty).join(' · '), style: small),
        ])),
      ])),
    );
  }
}

// 教室行：定位图标加正文色半粗教室名，课程卡、此刻卡与下一节预告共用。图标对齐首行，长教室名在图标右侧换行。
class CoursePlace extends StatelessWidget {
  const CoursePlace(this.place, {super.key, this.size = 16});
  final String place;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: EdgeInsets.only(top: ((MediaQuery.textScalerOf(context).scale(size) * 1.3 - size) / 2).clamp(0.0, double.infinity)), child: CampusIcon(CampusIcons.place, size: size, color: palette.onSurfaceVariant)),
      const SizedBox(width: 4),
      Flexible(child: BalancedText(place, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface))),
    ]);
  }
}

// 空档（同 Structured、Timepage 的时间轴，并按其用户反馈“30 分钟和两小时看起来一样”改进）：
// 虚线空位框与课程卡同宽同圆角，沿用“时刻 │ 竖条 │ 内容”三列；时刻列像尺子，上沿开始、下沿结束，中间虚线连起来；
// 标题写空多久（“没课 1小时40分”），副标题写节次；高度随时长对数加高（见 _gapHeight），不读字也能看出空当长短。
// 课表页长按展开时，框内渐显成选中卡、下方展开新增入口，不从细行跳成整卡。
// [人工决策-2026-10-06 13:06:11] 空档由与正课等高的整卡改为细行（取代 09-24“正课空课等宽等高”），用户选定；今天页相邻空档合并，课表页按节次分行以便新增课程。
// [人工决策-2026-10-06 14:20:54] 空档定为虚线空位框（取代 13:31:50 的无容器时间轴连接）：尺子时刻列、按时长加高、标题写时长；用户从时间带、虚线空位框、斜纹带三种实物中选定。斜纹在日历里常表示忙碌，未采用。
class _EmptySlot extends StatelessWidget {
  const _EmptySlot({super.key, required this.span, required this.time, required this.name, required this.minHeight, required this.timeWidth, required this.stacked, required this.reveal, this.actions});
  final double timeWidth;
  // 同有课卡：内容一栏太窄时去掉尺子时刻列，起止写在内容第一行。
  final bool stacked;
  final PeriodSpan span;
  final MeetingTime? time;
  final String name;
  final double minHeight;
  final Animation<double> reveal;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    const figures = [FontFeature.tabularFigures()];
    final secondary = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, height: 1.3, color: palette.onSurfaceVariant, fontFeatures: figures);
    final time = this.time;
    final duration = time == null ? null : classDuration(time.endMinute - time.startMinute);
    // 标题写空多久（“没课 1小时40分”），早八写彩蛋；节次与缺作息放副标题。
    final title = name == '没课' && duration != null ? '没课 $duration' : name;
    final detail = [if (name != '没课' && duration != null) duration, periodLabel(span.start, span.end), if (time == null) '作息时间未设置'].join(' · ');
    return AnimatedBuilder(
      animation: reveal,
      builder: (context, child) => CustomPaint(
        painter: _GapBackdropPainter(line: palette.outline.withValues(alpha: .4), reveal: reveal.value, selectedFill: palette.surfaceSelected.withValues(alpha: .91), selectedBorder: palette.primary.withValues(alpha: .5)),
        child: child,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ConstrainedBox(
            constraints: BoxConstraints(minWidth: double.infinity, minHeight: minHeight - 16),
            child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // 时刻列像尺子：上沿写开始、下沿写结束，与中间虚线两端对齐，一眼读出“从几点到几点”。
              if (!stacked) ...[
                SizedBox(width: timeWidth, child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(time?.startLabel ?? '--:--', maxLines: 1, softWrap: false, style: secondary.copyWith(fontSize: 16)),
                  if (time != null) Text(time.endLabel, maxLines: 1, softWrap: false, style: secondary),
                ])),
                const SizedBox(width: 10),
              ],
              SizedBox(width: 3, child: CustomPaint(painter: _DashPainter(palette.outline.withValues(alpha: .5)))),
              const SizedBox(width: 12),
              Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (stacked) ...[
                  Text(time == null ? '--:--' : '${time.startLabel}–${time.endLabel}', style: secondary),
                  const SizedBox(height: 2),
                ],
                Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurfaceVariant, fontFeatures: figures)),
                const SizedBox(height: 2),
                Text(detail, style: secondary),
              ])),
            ])),
          ),
          ?actions,
        ]),
      ),
    );
  }
}

// 空档的虚线空位框：与课程卡同宽同圆角，实线卡是有课、虚线框是空着；课表页展开时框内渐显成选中卡。
class _GapBackdropPainter extends CustomPainter {
  _GapBackdropPainter({required this.line, required this.reveal, required this.selectedFill, required this.selectedBorder});
  final Color line;
  final double reveal;
  final Color selectedFill;
  final Color selectedBorder;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24));
    final paint = Paint()..color = line.withValues(alpha: line.a * (1 - reveal))..style = PaintingStyle.stroke..strokeWidth = 1.2;
    // 各段虚线拼进一条路径一次画完：Impeller 没有栅格缓存，逐段画每帧都要提交上百次（滑动时更明显）。
    final dashes = Path();
    for (final metric in (Path()..addRRect(shape.deflate(.6))).computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 9) {
        dashes.addPath(metric.extractPath(distance, distance + 5), Offset.zero);
      }
    }
    canvas.drawPath(dashes, paint);
    if (reveal > 0) {
      canvas.drawRRect(shape, Paint()..color = selectedFill.withValues(alpha: selectedFill.a * reveal));
      canvas.drawRRect(shape.deflate(.5), Paint()..color = selectedBorder.withValues(alpha: selectedBorder.a * reveal)..style = PaintingStyle.stroke);
    }
  }

  @override
  bool shouldRepaint(_GapBackdropPainter oldDelegate) => oldDelegate.line != line || oldDelegate.reveal != reveal || oldDelegate.selectedFill != selectedFill || oldDelegate.selectedBorder != selectedBorder;
}

// 空档的虚线竖条：与课程卡竖条同一列、同宽，空闲段用虚线（时间轴列表的通用写法）。
class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color..strokeWidth = size.width..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    const dash = 3.0, gap = 5.0;
    final x = size.width / 2;
    // 各段拼成一条路径一次画完（同上，逐段画每帧都要多次提交）。
    final dashes = Path();
    for (var y = size.width / 2; y < size.height - size.width / 2; y += dash + gap) {
      dashes..moveTo(x, y)..lineTo(x, math.min(y + dash, size.height - size.width / 2));
    }
    canvas.drawPath(dashes, paint);
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => oldDelegate.color != color;
}

// 上课中的竖条：浅主色轨道上自上而下填激活色，随分钟时钟平滑推进；减少动画时直接到位。
class _ProgressStripe extends StatelessWidget {
  const _ProgressStripe({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Semantics(
      label: '上课中，已过${(progress * 100).round()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(width: 3, child: ColoredBox(
          color: palette.primary.withValues(alpha: .22),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: progress),
            duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
            // 填充用画笔画，不参与外层 IntrinsicHeight 的固有高度计算：FractionallySizedBox 在刚开课（进度为 0）时
            // 固有高度除以 0 得无穷，整张卡布局失败、内容空白，到下一分钟才恢复。
            builder: (context, value, _) => CustomPaint(painter: _StripeFillPainter(value: value, color: palette.accent)),
          ),
        )),
      ),
    );
  }
}

class _StripeFillPainter extends CustomPainter {
  _StripeFillPainter({required this.value, required this.color});
  final double value;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(Offset.zero & Size(size.width, size.height * value), Paint()..color = color);

  @override
  bool shouldRepaint(_StripeFillPainter oldDelegate) => oldDelegate.value != value || oldDelegate.color != color;
}
