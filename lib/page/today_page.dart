import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/schedule_calendar.dart';
import 'package:superxd/page/today_date_transition.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
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

  DateTime _instant() => widget.now?.call() ?? _clock?.value ?? DateTime.now();
  String _campusDay() => formatCampusDate(campusInstant(_instant()));
  bool _current(int generation) =>
      mounted &&
      generation == _readGeneration &&
      (widget.isAccountCurrent?.call() ?? true);

  // [人工决策-2026-09-25 21:16:32] 上滑下一天、下滑上一天；日期与标题同栏，圆形上箭头归位；当前学期范围、保留浏览日及午夜仅跟随今天不变。
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
    if (reactivated && !_syncing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
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
            view.error?.code == 'TERM_START_REQUIRED' ||
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
        confirmSchedule: (term, message) async {
          if (!mounted) return false;
          return await showCampusDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(term.label.isEmpty ? term.key : term.label),
              content: SingleChildScrollView(child: Text(message)),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('保留本地')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('覆盖')),
              ],
            ),
          ) == true;
        },
        chooseBells: _chooseBells,
        onProgress: (progress) { if (mounted) setState(() => _syncProgress = progress); },
      );
      if (!mounted) return;
      await _refresh(notify: false);
      if (!mounted || !TickerMode.valuesOf(context).enabled || report.cancelled || report.busy) return;
      await showCampusSyncReport(context, report);
      if (mounted && report.sessionExpired) await widget.onSessionExpired?.call();
    } catch (error, stack) {
      campusLog('[TodayPage] action=sync errorType=${error.runtimeType}\n$stack');
      await _notice('同步中断，已保存的数据保留，请重试。');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<BellsChoice> _chooseBells(TermRef target, BellsView source) async {
    if (!mounted) return BellsChoice.cancel;
    return await showCampusDialog<BellsChoice>(
      context: context,
      builder: (context) => AlertDialog(
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
    await showCampusDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('知道了'))],
      ),
    );
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
            TextButton(onPressed: _refresh, child: const Text('重试')),
          ],
        ),
      );
    } else if (_needsStart) {
      content = Center(
        child: FilledButton(onPressed: _pickStart, child: const Text('设置开学日')),
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
                    child: day != _today && spans.isEmpty ? const Text('当天暂无课程') : _NextClass(
                      spans: spans,
                      bells: _bells,
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
    return Semantics(
        key: ValueKey('today-date-$day'), label: '$day $weekday', liveRegion: true,
        customSemanticsActions: {
          if (_covered(formatIsoDate(date.subtract(const Duration(days: 1))))) const CustomSemanticsAction(label: '前一天') : () => _step(-1),
          if (_covered(formatIsoDate(date.add(const Duration(days: 1))))) const CustomSemanticsAction(label: '下一天') : () => _step(1),
        },
        // 日期快照保留布局状态，但颜色订阅当前主题，不能把创建快照时的明暗色固化。
        child: ExcludeSemantics(child: Center(child: Builder(builder: (context) => Text('$year${date.month}月${date.day}日 $weekday', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: CampusPalette.of(context).onSurface))))),
    );
  }

  Widget _layout(BuildContext context, Widget date, Widget body, bool previewing) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final hintHeight = (32 * scale + 16) / 2;
    return Column(children: [
      GlassPanel(edge: GlassEdge.bottom, child: SafeArea(bottom: false, child: SizedBox(
        height: 56 * scale,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Row(children: [
          Text('今天', style: Theme.of(context).textTheme.titleLarge),
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
      ))),
      if (_syncing) CampusLoading(label: _syncProgress.label, inline: true, network: true, animating: !_syncProgress.waitingForInput),
      // [人工决策-2026-09-27 17:28:58] 切日只保留页面直接交接，不再叠胶囊让位与回位动画；状态胶囊、归位按钮保持。
      Expanded(child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: body),
        Positioned(right: 16, bottom: hintHeight + 12 + MediaQuery.paddingOf(context).bottom, child: IgnorePointer(ignoring: _day == _today && !previewing, child: ExcludeSemantics(excluding: _day == _today && !previewing, child: AnimatedOpacity(
          opacity: _day == _today && !previewing ? 0 : 1,
          duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 180),
          child: CampusGlassCircleButton(key: const ValueKey('today-reset'), icon: const CampusIcon(CampusIcons.arrowUp, size: 24), label: '回今天', onPressed: () => _selectDay(_campusDay(), recenter: true)),
        )))),
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

class _NextClass extends StatelessWidget {
  const _NextClass({required this.spans, required this.bells, this.now});
  final List<PeriodSpan> spans;
  final List<BellPeriod> bells;
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
    final occupied = spans.where((span) => !span.empty);
    if (occupied.isEmpty) return const Text('今天暂无课程');
    // 作息不完整时不把“第3节”当钟点比较，也不猜测下一节或已下课。
    if (occupied.any((span) => meetingTime(bells, span.meeting!) == null)) {
      return const Text('今日课程');
    }
    final instant = campusInstant(
      now?.call() ?? LiveClock.maybeOf(context)?.value,
    );
    final minutes = instant.hour * 60 + instant.minute;
    final active = occupied
        .where((span) => meetingTime(bells, span.meeting!)!.endMinute > minutes)
        .firstOrNull;
    if (active == null) return const Text('今天的课上完了');
    final time = meetingTime(bells, active.meeting!)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          time.startMinute <= minutes ? '正在上课' : '下一节',
          style: TextStyle(
            fontSize: 14,
            color: CampusPalette.of(context).onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          active.course!.courseName,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 4),
        Text(
          '${time.label}  ${active.meeting!.place}  ${active.course!.teacherName}',
          style: TextStyle(
            fontSize: 14,
            color: CampusPalette.of(context).onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CampusSurface(padding: const EdgeInsets.all(16), child: child);
  }
}
