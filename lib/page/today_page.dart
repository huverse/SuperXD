import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/schedule_calendar.dart';
import 'package:superxd/page/today_date_transition.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/campus_sync_dialogs.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/page/sync_selection_dialog.dart';
import 'package:superxd/page/term_start_dialog.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/gateway_code.dart';

class TodayPage extends StatefulWidget {
  const TodayPage({
    super.key,
    required this.gateway,
    this.onSessionExpired,
    this.isAccountCurrent,
    this.now,
  });
  final CampusGateway gateway;
  final Future<void> Function()? onSessionExpired;
  final bool Function()? isAccountCurrent;
  final DateTime Function()? now;

  @override
  State<TodayPage> createState() => _TodayPageState();
}

class _TodayPageState extends State<TodayPage> with WidgetsBindingObserver {
  late final CampusSync _syncService = CampusSync(widget.gateway);
  TermRef? _term;
  ScheduleView? _schedule;
  List<BellPeriod> _bells = const [];
  bool _needsStart = false;
  bool _loading = true;
  bool _syncing = false;
  CampusSyncProgress _syncProgress = const CampusSyncProgress('准备同步');
  bool _choosing = false;
  late String _today = _campusDay();
  late String _day = _today;
  bool _followingToday = true;
  String? _first;
  String? _last;
  String? _readError;
  bool _knownSchedule = false;
  int _recenter = 0;
  final Map<String, List<PeriodSpan>> _days = {};
  int _termLastPeriod = 0;
  int _contentRevision = 0;
  ValueNotifier<DateTime>? _clock;
  bool? _branchActive;
  int _readGeneration = 0;
  CampusSyncReport? _pendingReport;

  DateTime _instant() => widget.now?.call() ?? _clock?.value ?? DateTime.now();
  String _campusDay() => formatCampusDate(campusInstant(_instant()));
  bool _current(int generation) =>
      mounted &&
      generation == _readGeneration &&
      (widget.isAccountCurrent?.call() ?? true);

  // [人工决策-2026-09-25 21:16:32] 上滑下一天、下滑上一天；日期与标题同栏；当前学期范围、保留浏览日及午夜仅跟随今天不变。
  // 原“圆形上箭头归位”已由 2026-10-05 23:16:48 的人工决策改为底部居中“今天”胶囊，见 _layout。
  void _updateToday() {
    final today = _campusDay();
    if (_today == today) return;
    setState(() {
      _today = today;
      _contentRevision++;
      if (_followingToday) _day = today;
    });
  }

  bool _covered(String date) =>
      _first != null &&
      _last != null &&
      date.compareTo(_first!) >= 0 &&
      date.compareTo(_last!) <= 0;
  String _adjacent(int step) =>
      formatIsoDate(parseIsoDate(_day).add(Duration(days: step)));
  bool _canStep(int step) => _covered(_adjacent(step));
  void _step(int step) {
    _updateToday();
    if (_canStep(step)) _selectDay(_adjacent(step));
  }

  void _selectDay(String date, {bool recenter = false}) {
    final today = _campusDay();
    campusLog('[TodayPage] action=select_day date=$date recenter=$recenter');
    setState(() {
      _today = today;
      _day = date;
      _followingToday = date == today;
      if (recenter) _recenter++;
    });
  }

  List<PeriodSpan> _spans(String date) {
    final cached = _days.remove(date);
    if (cached != null) {
      _days[date] = cached;
      return cached;
    }
    final courses = visibleCourses(
      _schedule!.courses,
      ScheduleScope.day(
        term: _term!,
        date: date,
        termStartDate: _schedule!.termStartDate!,
      ),
    );
    final spans = List<PeriodSpan>.unmodifiable(
      periodSpans(courses, bells: _bells, termLastPeriod: _termLastPeriod),
    );
    if (_days.length >= 5) _days.remove(_days.keys.first);
    return _days[date] = spans;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final clock = LiveClock.maybeOf(context);
    if (clock != _clock) {
      _clock?.removeListener(_tick);
      _clock = clock;
      _clock?.addListener(_tick);
    }
    final active = TickerMode.valuesOf(context).enabled;
    final reactivated = _branchActive == false && active;
    _branchActive = active;
    if (reactivated) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        if (!_syncing) await _refresh();
        await _showPendingReport();
      });
    }
  }

  @override
  void deactivate() {
    _clock?.removeListener(_tick);
    _clock = null;
    _branchActive = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _clock?.removeListener(_tick);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_syncing) _refresh();
  }

  void _tick() {
    if (!mounted || _branchActive != true || _syncing || _loading) return;
    _updateToday();
  }

  Future<void> _refresh({bool notify = true}) async {
    final generation = ++_readGeneration;
    _updateToday();
    campusLog(
      '[TodayPage] action=read_local generation=$generation state=start',
    );
    try {
      final terms = await widget.gateway.listTerms();
      if (!_current(generation)) return;
      final term = terms.data?.firstOrNull;
      if (!terms.ok || term == null) {
        setState(() {
          _loading = false;
          _term = null;
          _schedule = null;
          _first = _last = null;
          _knownSchedule = false;
          _needsStart = false;
          _readError = terms.ok ? null : terms.error?.message ?? '学期读取失败';
          _contentRevision++;
        _days.clear();
        });
        if (notify && !terms.ok) await _notice(_readError!);
        return;
      }
      final view = await widget.gateway.readSchedule(ScheduleScope.term(term));
      if (!_current(generation)) return;
      final bells = await widget.gateway.readBells(term);
      if (!_current(generation)) return;
      final schedule = view.data;
      final start = schedule?.termStartDate;
      final hasWeeks =
          schedule?.courses.any(
            (course) =>
                course.meetings.any((meeting) => meeting.weeks.isNotEmpty),
          ) ??
          false;
      setState(() {
        _term = term;
        _loading = false;
        _knownSchedule =
            view.ok && schedule != null && schedule.revisionId != null;
        _needsStart =
            view.error?.code == GatewayCode.termStartRequired ||
            _knownSchedule && (start == null || start.isEmpty);
        _readError = !view.ok && !_needsStart
            ? view.error?.message ?? '本地课表读取失败'
            : null;
        _schedule = schedule;
        _termLastPeriod =
            schedule?.termLastPeriod ??
            maxCoursePeriod(schedule?.courses ?? const []);
        _bells = bells.data?.periods ?? const [];
        _first = _knownSchedule && !_needsStart && hasWeeks ? start : null;
        _last = _first == null
            ? null
            : weekRange(_first!, maxCourseWeek(schedule!.courses)).end;
        _contentRevision++;
        _days.clear();
      });
      campusLog(
        '[TodayPage] action=read_local generation=$generation state=complete',
      );
      if (!notify) return;
      if (!view.ok) await _notice(view.error?.message ?? '本地课表读取失败');
      if (_current(generation) && !bells.ok) {
        await _notice(bells.error?.message ?? '本地作息读取失败');
      }
    } catch (error, stack) {
      campusLog(
        '[TodayPage] action=read_local errorType=${error.runtimeType}\n$stack',
      );
      if (!_current(generation)) return;
      setState(() {
        _loading = false;
        _readError = '本地数据读取失败，请重试';
        _contentRevision++;
      });
      if (notify) await _notice('本地数据读取失败，请重试。');
    }
  }

  Future<void> _pickStart() async {
    final term = _term;
    if (term == null) return;
    final full = await widget.gateway.readSchedule(ScheduleScope.term(term));
    if (!mounted) return;
    final saved = await editTermStart(context, widget.gateway, term, full.data?.termStartDate);
    if (saved != null && mounted) await _refresh();
  }

  Future<void> _chooseSync() async {
    if (_syncing || _choosing) return;
    _choosing = true;
    try {
      final selected = await chooseSyncSelection(context, widget.gateway);
      if (selected != null && mounted) await _sync(selected);
    } finally {
      _choosing = false;
    }
  }

  Future<void> _sync(SyncSelection selection) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final report = await _syncService.run(
        contents: selection.contents,
        years: selection.years,
        isActive: () => mounted && (widget.isAccountCurrent?.call() ?? true) && TickerMode.valuesOf(context).enabled,
        confirmSchedule: (term, message) async => mounted &&
            await showCampusConfirm(context, title: term.label.isEmpty ? term.key : term.label, message: message, cancel: '保留本地', action: '覆盖', destructive: true),
        chooseBells: _chooseBells,
        onProgress: (progress) { if (mounted) setState(() => _syncProgress = progress); },
      );
      if (!mounted) return;
      await _refresh(notify: false);
      if (!mounted || report.busy) return;
      // [人工决策-2026-09-29 21:31:03] 同步中离开今天页仍在下一检查点中止；结果暂存，回到今天页再提示“同步已中止”，列出已完成与未处理项并可重新同步；离开期间跑完的结果也回来展示，不再静默。
      _pendingReport = report;
      await _showPendingReport();
    } catch (error, stack) {
      campusLog('[TodayPage] action=sync errorType=${error.runtimeType}\n$stack');
      await _notice('同步中断，已保存的数据保留，请重试。');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  // 今天页可见且账号未变时才展示；会话失效看完后照常转登录，选择重新同步则打开同步范围。
  Future<void> _showPendingReport() async {
    final report = _pendingReport;
    if (report == null || !mounted || !TickerMode.valuesOf(context).enabled || !(widget.isAccountCurrent?.call() ?? true)) return;
    _pendingReport = null;
    final again = await showCampusSyncReport(context, report);
    if (!mounted) return;
    if (report.sessionExpired) {
      await widget.onSessionExpired?.call();
    } else if (again) {
      await _chooseSync();
    }
  }

  Future<BellsChoice> _chooseBells(TermRef target, BellsView source) async {
    if (!mounted) return BellsChoice.cancel;
    return await showCampusDialog<BellsChoice>(
      context: context,
      builder: (context) => CampusGlassDialog(
        title: const Text('采用这套作息时间？'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${target.label}没有可用的已采用作息。\n来源：${source.term.label}', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            for (final period in source.periods)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text('第${period.period}节  ${period.start}–${period.end}', style: const TextStyle(fontSize: 16)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, BellsChoice.cancel), child: const Text('暂不采用')),
          TextButton(onPressed: () => Navigator.pop(context, BellsChoice.next), child: const Text('看下一套')),
          FilledButton(onPressed: () => Navigator.pop(context, BellsChoice.use), child: const Text('用这套')),
        ],
      ),
    ) ?? BellsChoice.cancel;
  }

  Future<void> _notice(String message) async {
    if (!mounted || message.isEmpty || !TickerMode.valuesOf(context).enabled) return;
    await showCampusNotice(context, message);
  }

  double _bodyInset(BuildContext context) => (32 * MediaQuery.textScalerOf(context).scale(14) / 14 + 16) / 2;
  // 正文延伸到玻璃底栏下方，被遮挡高度扣除正文留白后交给列表留白，非列表状态在可见区居中。
  double _obscured(BuildContext context) => (MediaQuery.paddingOf(context).bottom - _bodyInset(context)).clamp(0.0, double.infinity);

  Widget _dayContent(String day) {
    final spans = _covered(day) && _readError == null
        ? _spans(day)
        : const <PeriodSpan>[];
    final obscured = _obscured(context);
    var inset = obscured;
    Widget content;
    if (_readError != null) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_readError!, textAlign: TextAlign.center),
            TextButton.icon(onPressed: _refresh, icon: const CampusIcon(CampusIcons.sync), label: const Text('重试')),
          ],
        ),
      );
    } else if (_needsStart) {
      content = Center(
        child: FilledButton.icon(style: campusProminent, onPressed: _pickStart, icon: const CampusIcon(CampusIcons.termStart), label: const Text('设置开学日')),
      );
    } else if (!_knownSchedule) {
      content = const Center(child: Text('尚未同步课表'));
    } else if (!_covered(day)) {
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _schedule!.courses.isEmpty
                  ? '当前学期暂无课程'
                  : _first == null
                  ? '暂无已知教学日期'
                  : '这天不在已知课表范围内',
              textAlign: TextAlign.center,
            ),
            if (_first != null)
              TextButton(
                onPressed: () =>
                    _selectDay(day.compareTo(_first!) < 0 ? _first! : _last!),
                child: const Text('查看已知课表'),
              ),
          ],
        ),
      );
    } else {
      inset = 0;
      content = CourseDayCards(
          key: ValueKey('today-cards-$day-$_recenter'),
          spans: spans,
          bells: _bells,
          date: day,
          bottomInset: day == _today ? 0 : 68,
          obscuredBottom: obscured,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          header: day == _today || spans.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _Card(
                    child: day != _today && spans.isEmpty ? const Text('当天暂无课程') : _ClassNow(
                      spans: spans,
                      bells: _bells,
                      date: day,
                      now: widget.now,
                    ),
                  ),
                )
              : null,
      );
    }
    return Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, inset), child: content);
  }

  Widget _dateHeader(String day) {
    final date = parseIsoDate(day);
    final weekday = const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][date.weekday - 1];
    final year = date.year == parseIsoDate(_today).year ? '' : '${date.year}年';
    // 看别的日子时在日期下注明离今天多远，和底部“今天”胶囊的箭头方向一起说明今天在哪边。
    final offset = date.difference(parseIsoDate(_today)).inDays;
    final relative = switch (offset) { 0 => null, 1 => '明天', -1 => '昨天', 2 => '后天', -2 => '前天', > 0 => '$offset天后', _ => '${-offset}天前' };
    return Semantics(
        key: ValueKey('today-date-$day'), label: '$day $weekday${relative == null ? '' : ' $relative'}', liveRegion: true,
        customSemanticsActions: {
          if (_covered(formatIsoDate(date.subtract(const Duration(days: 1))))) const CustomSemanticsAction(label: '前一天') : () => _step(-1),
          if (_covered(formatIsoDate(date.add(const Duration(days: 1))))) const CustomSemanticsAction(label: '下一天') : () => _step(1),
        },
        // 日期快照保留布局状态，但颜色订阅当前主题，不能把创建快照时的明暗色固化。
        child: ExcludeSemantics(child: Center(child: Builder(builder: (context) => Column(mainAxisSize: MainAxisSize.min, children: [
          Text('$year${date.month}月${date.day}日 $weekday', textAlign: TextAlign.center, maxLines: 1, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurface)),
          if (relative != null) Text(relative, textAlign: TextAlign.center, maxLines: 1, style: TextStyle(fontSize: 14, height: 1.2, color: CampusPalette.of(context).onSurfaceVariant)),
        ])))),
    );
  }

  Widget _layout(BuildContext context, Widget date, Widget body, bool previewing) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final hintHeight = (32 * scale + 16) / 2;
    return Column(children: [
      CampusTopBar(child: SizedBox(
        height: 56 * scale,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Row(children: [
          Text('今天', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(width: 8),
          Expanded(child: date),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _syncing || _choosing ? null : _chooseSync,
            onLongPress: _syncing || _choosing ? null : _chooseSync,
            icon: const CampusIcon(CampusIcons.sync, size: 20),
            label: Text(_syncing ? '同步中' : '同步', style: const TextStyle(fontSize: 16)),
          ),
        ])),
      )),
      if (_syncing) CampusLoading(label: _syncProgress.label, inline: true, network: true, animating: !_syncProgress.waitingForInput),
      // [人工决策-2026-09-27 17:28:58] 切日只保留页面直接交接，不再叠胶囊让位与回位动画；状态胶囊、归位按钮保持。
      Expanded(child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: body),
        // [人工决策-2026-10-05 23:16:48] 回今天改为底栏上方居中的玻璃胶囊“今天”，取代右下圆形上箭头（用户选定，同 X、Telegram 的“回到最新”）：
        // 左右对称；箭头指向今天所在方向（看之后的日子朝上、之前的日子朝下，与上下滑切日一致）；出现时自下浮起并显形；顶栏日期下注明相对天数。
        Positioned(left: 0, right: 0, bottom: hintHeight + 12 + MediaQuery.paddingOf(context).bottom, child: Center(child: _TodayReturn(
          visible: _day != _today || previewing,
          upward: _day.compareTo(_today) >= 0,
          onPressed: () {
            HapticFeedback.selectionClick();
            _selectDay(_campusDay(), recenter: true);
          },
        ))),
      ])),
    ]);
  }

  @override
  Widget build(BuildContext context) => TodayDateTransition(
    date: _day, revision: _contentRevision, recenter: _recenter,
    bodyInset: _bodyInset(context),
    canSelect: (date) => !_loading && _readError == null && _covered(date),
    onCommit: _selectDay,
    frameBuilder: (date) => TodayDateFrame(
      header: _dateHeader(date),
      body: _loading ? Padding(padding: EdgeInsets.only(bottom: _obscured(context)), child: const Center(child: CampusLoading(label: '正在读取课表'))) : _dayContent(date),
      scrollable: !_loading && _readError == null && _covered(date) && _spans(date).isNotEmpty,
    ),
    builder: _layout,
  );

}

// 今天页顶部的“此刻”卡（同 iOS 实时活动、Google 日历的“下一项”）：上课中或下一节的课名、地点，
// 大号剩余时长（小时分钟）加起止时刻进度条；课间画上一节下课到下一节上课的进度，第一节课前只显示时长。
class _ClassNow extends StatelessWidget {
  const _ClassNow({required this.spans, required this.bells, required this.date, this.now});
  final List<PeriodSpan> spans;
  final List<BellPeriod> bells;
  final String date;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) {
    final clock = LiveClock.maybeOf(context);
    if (clock == null || !TickerMode.valuesOf(context).enabled) return _summary(context);
    return ValueListenableBuilder(
      valueListenable: clock,
      builder: (context, _, child) => _summary(context),
    );
  }

  Widget _summary(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final occupied = spans.where((span) => !span.empty);
    if (occupied.isEmpty) return const Text('今天暂无课程');
    // 作息不完整时不把“第3节”当钟点比较，也不猜测下一节或已下课。
    if (occupied.any((span) => meetingTime(bells, span.meeting!) == null)) {
      return const Text('今日课程');
    }
    final moment = classMoment(spans, bells, date, now?.call() ?? LiveClock.maybeOf(context)?.value ?? DateTime.now());
    final focus = moment.focus;
    if (focus == null) {
      return Row(children: [
        CampusIcon(CampusIcons.success, color: palette.primary, size: 20),
        const SizedBox(width: 10),
        const Expanded(child: Text('今天的课上完了')),
      ]);
    }
    final remaining = classDuration(moment.remainingMinutes);
    final suffix = moment.ongoing ? '后下课' : '后上课';
    final fraction = moment.fraction;
    const figures = [FontFeature.tabularFigures()];
    // 同 iOS 实时活动：课的信息在左，剩余时长在右上（数字大、单位小），起止时刻标在进度条两端。
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${moment.ongoing ? '上课中' : '下一节'} · 第${focus.start}–${focus.end}节', style: secondary),
          const SizedBox(height: 4),
          Text(focus.course!.courseName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text('${focus.meeting!.place} · ${focus.course!.teacherName}', style: secondary),
        ])),
        const SizedBox(width: 12),
        Semantics(
          label: '$remaining$suffix',
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text.rich(TextSpan(children: [
              for (final (text, number) in classDurationParts(moment.remainingMinutes))
                TextSpan(text: text, style: number
                    ? TextStyle(fontSize: 28, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface, fontFeatures: figures)
                    : TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: palette.onSurface)),
            ])),
            Text(suffix, style: secondary),
          ]),
        ),
      ]),
      if (fraction != null) ...[
        const SizedBox(height: 12),
        ExcludeSemantics(child: DefaultTextStyle.merge(style: secondary.copyWith(fontFeatures: figures), child: Row(children: [
          Text(moment.fromLabel),
          const SizedBox(width: 10),
          Expanded(child: _TimeTrack(fraction: fraction)),
          const SizedBox(width: 10),
          Text(moment.targetLabel),
        ]))),
      ],
    ]);
  }
}

// 起止时刻进度条：浅轨道上填激活色，末端一个小圆点标出此刻；随分钟时钟平滑推进，减少动画时直接到位。
class _TimeTrack extends StatelessWidget {
  const _TimeTrack({required this.fraction});
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return SizedBox(height: 10, child: TweenAnimationBuilder<double>(
      tween: Tween(end: fraction),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => CustomPaint(size: Size.infinite, painter: _TimeTrackPainter(value: value, track: palette.primary.withValues(alpha: .18), fill: palette.accent, knob: palette.surface)),
    ));
  }
}

class _TimeTrackPainter extends CustomPainter {
  _TimeTrackPainter({required this.value, required this.track, required this.fill, required this.knob});
  final double value;
  final Color track;
  final Color fill;
  final Color knob;

  @override
  void paint(Canvas canvas, Size size) {
    const bar = 6.0;
    final top = (size.height - bar) / 2;
    final paint = Paint();
    canvas.drawRRect(RRect.fromLTRBR(0, top, size.width, top + bar, const Radius.circular(bar / 2)), paint..color = track);
    final end = size.width * value;
    if (end > 0) canvas.drawRRect(RRect.fromLTRBR(0, top, math.max(end, bar), top + bar, const Radius.circular(bar / 2)), paint..color = fill);
    final center = Offset(end.clamp(size.height / 2, size.width - size.height / 2), size.height / 2);
    canvas.drawCircle(center, size.height / 2, paint..color = fill);
    canvas.drawCircle(center, size.height / 2 - 2.5, paint..color = knob);
  }

  @override
  bool shouldRepaint(_TimeTrackPainter oldDelegate) => oldDelegate.value != value || oldDelegate.track != track || oldDelegate.fill != fill || oldDelegate.knob != knob;
}

// 回今天胶囊：导航层玻璃胶囊（箭头加“今天”），隐藏时不可点、不进读屏；显隐用玻璃显形加 12dp 上浮，减少动画时直接切换。
class _TodayReturn extends StatelessWidget {
  const _TodayReturn({required this.visible, required this.upward, required this.onPressed});
  final bool visible;
  final bool upward;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 300);
    return IgnorePointer(ignoring: !visible, child: ExcludeSemantics(excluding: !visible, child: AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, .25),
      duration: duration,
      curve: campusSpringCurve,
      child: CampusGlassPresence(visible: visible, child: CampusChrome(child: Semantics(
        label: '回今天',
        button: true,
        excludeSemantics: true,
        child: FilledButton.icon(
          key: const ValueKey('today-reset'),
          onPressed: onPressed,
          icon: AnimatedRotation(turns: upward ? 0 : .5, duration: duration, curve: campusSpringCurve, child: const CampusIcon(CampusIcons.arrowUp, size: 20)),
          label: const Text('今天'),
        ),
      ))),
    )));
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: double.infinity, child: CampusSurface(padding: const EdgeInsets.all(16), child: child));
  }
}
