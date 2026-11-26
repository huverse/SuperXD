import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/local/display_settings.dart';
import 'package:superxd/page/schedule_calendar.dart';
import 'package:superxd/page/today_date_transition.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_rolling_text.dart';
import 'package:superxd/theme/campus_side_drawer.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/application/auto_sync.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/meeting_time.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/schedule_edit.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/campus_sync_dialogs.dart';
import 'package:superxd/page/live_clock.dart';
import 'package:superxd/page/sync_merge_page.dart';
import 'package:superxd/page/sync_selection_dialog.dart';
import 'package:superxd/page/term_start_dialog.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/gateway_code.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// [人工决策-2026-10-19 17:55:48] 别的页面要同步时（课表页「去同步」）只把人带回今天页、在这里打开同步范围并预选那一学年（用户选定）：
// 同步入口仍只有今天页与成绩页，不另起同步实例。由组合根（router.dart）创建、交给两个页面。
class TodaySyncRequest extends ChangeNotifier {
  String? _year;
  bool _pending = false;

  void request({String? year}) {
    _year = year;
    _pending = true;
    notifyListeners();
  }

  ({String? year})? take() {
    if (!_pending) return null;
    _pending = false;
    return (year: _year);
  }
}

class TodayPage extends StatefulWidget {
  const TodayPage({
    super.key,
    required this.gateway,
    this.onSessionExpired,
    this.isAccountCurrent,
    this.now,
    this.syncRequest,
    this.autoSync,
  });
  final CampusGateway gateway;
  // 自动同步（设备级，经账号门面跟着当前账号）：这页只听它记下的结果、看得见时马上重读本机；设置入口只在学业页（同步范围里不再给）。
  final AutoSync? autoSync;
  final Future<void> Function()? onSessionExpired;
  final bool Function()? isAccountCurrent;
  final DateTime Function()? now;
  final TodaySyncRequest? syncRequest;

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
  // 上次读到的本地数据签名：切回今天页、回到前台都会重读本地，读到的跟上次一样时不刷新内容（不清日程缓存、不换内容版本，
  // 免得整页重排；10-27 iPhone 日志里每次切回今天构建 24–34ms）。课表按版本号认（编辑、同步、恢复都会出新版本），没有版本号时照常刷新。
  String? _signature;
  ValueNotifier<DateTime>? _clock;
  bool? _branchActive;
  int _readGeneration = 0;
  CampusSyncReport? _pendingReport;
  int _nextRevision = -1;
  final Map<String, ({String date, CourseRecord course, CourseMeeting meeting})?> _nexts = {};

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
    // 今天页只读：相邻空档合成一行（“16:00–20:40 · 第7–10节 没课”）；课表页仍按节次分行，便于在其中新增课程。
    final merged = <PeriodSpan>[];
    for (final span in periodSpans(courses, bells: _bells, termLastPeriod: _termLastPeriod)) {
      final previous = merged.lastOrNull;
      if (span.empty && previous != null && previous.empty) {
        merged.last = PeriodSpan(start: previous.start, end: span.end);
      } else {
        merged.add(span);
      }
    }
    final spans = List<PeriodSpan>.unmodifiable(merged);
    if (_days.length >= 5) _days.remove(_days.keys.first);
    return _days[date] = spans;
  }

  // after 这天之后的第一节课（只读本机课表，最多看到已知范围末）：今天的课上完、今天或之后某天没课时在此刻卡预告，省去下滑切日。
  // 按日子与内容版本缓存（最多几天），分钟时钟重建时不重算。
  ({String date, CourseRecord course, CourseMeeting meeting})? _nextClass(String after) {
    if (_nextRevision != _contentRevision) {
      _nexts.clear();
      _nextRevision = _contentRevision;
    }
    if (_nexts.containsKey(after)) return _nexts[after];
    ({String date, CourseRecord course, CourseMeeting meeting})? next;
    if (_first != null && _last != null) {
      final following = formatIsoDate(parseIsoDate(after).add(const Duration(days: 1)));
      for (var date = following.compareTo(_first!) < 0 ? _first! : following; date.compareTo(_last!) <= 0; date = formatIsoDate(parseIsoDate(date).add(const Duration(days: 1)))) {
        final courses = visibleCourses(_schedule!.courses, ScheduleScope.day(term: _term!, date: date, termStartDate: _schedule!.termStartDate!));
        for (final course in courses) {
          for (final meeting in course.meetings) {
            if (next == null || meeting.periodStart < next.meeting.periodStart) next = (date: date, course: course, meeting: meeting);
          }
        }
        if (next != null) break;
      }
    }
    if (_nexts.length >= 5) _nexts.remove(_nexts.keys.first);
    return _nexts[after] = next;
  }

  // 今天页单击有课卡：只读详情（见 course_cards.dart 的 showCourseDetail）；编辑只在课表页。
  Future<void> _openCourse(PeriodSpan span) {
    HapticFeedback.selectionClick();
    return showCourseDetail(context, span: span, courses: _schedule!.courses, bells: _bells);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.syncRequest?.addListener(_onSyncRequest);
    widget.autoSync?.addListener(_onAutoSync);
    _refresh();
  }

  // 前台的自动同步每记一次结果都会通知：看得见时马上重读本机（课表、作息变了才重排），不用等切页或下次打开（11-19 用户选定）。
  void _onAutoSync() {
    if (!mounted || _branchActive != true || _syncing || _loading) return;
    unawaited(_refresh(notify: false));
  }

  // 只在今天页看得见时接请求；切回来之前到的，由重新可见时接着处理。
  void _onSyncRequest() {
    if (!mounted || _branchActive != true) return;
    final request = widget.syncRequest?.take();
    if (request != null) unawaited(_chooseSync(initialYear: request.year));
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
        _onSyncRequest();
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
    widget.syncRequest?.removeListener(_onSyncRequest);
    widget.autoSync?.removeListener(_onAutoSync);
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
        _signature = null;
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
      final revision = schedule?.revisionId;
      final signature = revision == null || !bells.ok
          ? null
          : [term.key, revision, start, schedule!.termLastPeriod, for (final period in bells.data?.periods ?? const <BellPeriod>[]) '${period.period}/${period.dayPart}/${period.dayPartCode}/${period.start}/${period.end}'].join('\u0000');
      if (signature != null && signature == _signature && !_loading && _readError == null) {
        campusLog('[TodayPage] action=read_local generation=$generation state=unchanged');
        return;
      }
      _signature = signature;
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
      _signature = null;
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

  Future<void> _chooseSync({String? initialYear}) async {
    if (_syncing || _choosing) return;
    _choosing = true;
    try {
      final selected = await chooseSyncSelection(context, widget.gateway, initialYear: initialYear);
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
        // 和本地改过的课表冲突：打开合并页逐项选（三方合并，人工决策见 domain/auto_sync.dart），退出同保留本地。
        // 合并页整页盖在今天页上（今天页的 TickerMode 随之关掉），同步要等它返回才接着判断；页面退出后下一帧今天页才重新可见，
        // 等过这一帧再交回结果，不然刚选完就被当成中途离开，选择被丢掉。
        resolveSchedule: (term, plan, courses) async {
          if (!mounted) return const KeepLocal(remember: true);
          final resolution = await resolveScheduleSync(context, gateway: widget.gateway, term: term, plan: plan, edu: courses);
          await WidgetsBinding.instance.endOfFrame;
          return resolution;
        },
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

  Future<BellsChoice> _chooseBells(TermRef target, BellsView source) async => mounted ? await chooseBellsSource(context, target, source) : BellsChoice.cancel;

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
      // 空状态原地给下一步（HIG、Material 的空状态写法）：顶栏的「同步」离得远，第一次打开的人不一定看得到。
      content = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('尚未同步课表'),
            const SizedBox(height: 12),
            FilledButton.icon(style: campusProminent, onPressed: _syncing || _choosing ? null : _chooseSync, icon: const CampusIcon(CampusIcons.sync), label: const Text('同步课表')),
          ],
        ),
      );
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
              TextButton.icon(
                onPressed: () =>
                    _selectDay(day.compareTo(_first!) < 0 ? _first! : _last!),
                icon: const CampusIcon(CampusIcons.jumpToday),
                label: const Text('查看已知课表'),
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
          // 看别的日子时给“今天”胶囊让位：胶囊的实际高度再留 8dp 间隙，滚到底时最后一节课完整露出。
          bottomInset: day == _today ? 0 : 8 + _returnHeight(context),
          obscuredBottom: obscured,
          physics: const ClampingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          onOpen: _openCourse,
          revealNow: true,
          header: day == _today || spans.isEmpty
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _ClassNow(
                    spans: spans,
                    bells: _bells,
                    date: day,
                    today: _today,
                    now: widget.now,
                    // 过去的日子不预告“下一节”。
                    next: day.compareTo(_today) >= 0 ? _nextClass(day) : null,
                    onOpen: _openCourse,
                    onJump: (date) {
                      HapticFeedback.selectionClick();
                      _selectDay(date);
                    },
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
        // 窄屏、大字号下「10月19日 周一」一行放不下时（以前被截成「周」），星期换到第二行、和离今天多远写在一起（「周二 · 明天」），最多两行。
        child: ExcludeSemantics(child: Center(child: LayoutBuilder(builder: (context, constraints) {
          // 日期就是这页的标题（顶栏去掉了「今天」大字），一号标题字半粗；离今天多远写在下面一行。
          final primary = _datePrimary.copyWith(color: CampusPalette.of(context).onSurface);
          final secondary = _dateSecondary.copyWith(color: CampusPalette.of(context).onSurfaceVariant);
          final full = '$year${date.month}月${date.day}日 $weekday';
          final fits = campusTextWidth(context, full, style: primary) <= constraints.maxWidth;
          final second = fits ? relative : [weekday, ?relative].join(' · ');
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Text(fits ? full : '$year${date.month}月${date.day}日', textAlign: TextAlign.center, maxLines: 1, style: primary),
            if (second != null) Text(second, textAlign: TextAlign.center, maxLines: 1, style: secondary),
          ]);
        }))),
    );
  }

  // 顶栏高：至少 56（同 AppBar）；日期两行（看别的日子时第二行写明天、几天前）按当前字号与字体量出来放得下为准，今天与别的日子同一个高、切日不跳。
  // 不再按 56 × 字号倍数：两侧圆钮固定 44，跟着放大只多出留白（见 shell_page.dart 底栏 11-25 的人工决策）。
  double _topBarHeight(BuildContext context) {
    final primary = campusTextPainter(context, '12月31日', style: _datePrimary, maxLines: 1);
    final secondary = campusTextPainter(context, '周三 · 明天', style: _dateSecondary, maxLines: 1);
    final height = math.max(56.0, primary.height + secondary.height + 8);
    primary.dispose();
    secondary.dispose();
    return height.ceilToDouble();
  }

  // 回今天胶囊占的高：主题的 FilledButton（触区至少 48，上下内边距加一行字），按这一行在当前字号下的实际高度算；
  // 以前是 48 × 字号倍数，触区与内边距跟着放大，大字号下列表末尾多空出一截。
  double _returnHeight(BuildContext context) {
    final style = Theme.of(context).filledButtonTheme.style!;
    final line = campusTextPainter(context, '今天', style: style.textStyle!.resolve(const {}), maxLines: 1);
    final height = math.max(48.0, style.padding!.resolve(const {})!.vertical + line.height);
    line.dispose();
    return height;
  }

  Widget _layout(BuildContext context, Widget date, Widget body, bool previewing) {
    return Column(children: [
      CampusTopBar(child: SizedBox(
        height: _topBarHeight(context),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), child: Builder(builder: (context) {
          final drawer = CampusSideDrawer.maybeOf(context);
          // [人工决策-2026-11-23 18:29:13] 顶栏两侧玻璃圆钮、日期居中（用户 11-23 选定，同 Claude、Google 日历）：左边拉出侧栏（见 side_drawer.dart），右边同步；
          // 去掉「今天」大字（底栏已写着今天，看别的日子时日期下面写明天、几天前）。没选两行大标题、把按钮插在「今天」前面。没有侧栏时左边空出同宽，日期仍居中。
          return Row(children: [
            if (drawer != null) CampusGlassCircleButton(label: '侧栏', size: 44, onPressed: drawer.open, icon: const CampusMenuGlyph()) else const SizedBox(width: 44),
            const SizedBox(width: 8),
            Expanded(child: date),
            const SizedBox(width: 8),
            CampusGlassCircleButton(label: _syncing ? '同步中' : '同步', size: 44, onPressed: _syncing || _choosing ? null : _chooseSync, icon: const CampusIcon(CampusIcons.sync, size: 20)),
          ]);
        })),
      )),
      if (_syncing) CampusLoading(label: _syncProgress.label, inline: true, network: true, animating: !_syncProgress.waitingForInput),
      // [人工决策-2026-09-27 17:28:58] 切日只保留页面直接交接，不再叠胶囊让位与回位动画；状态胶囊、归位按钮保持。
      Expanded(child: Stack(fit: StackFit.expand, children: [
        Positioned.fill(child: body),
        // [人工决策-2026-10-05 23:16:48] 回今天改为底栏上方居中的玻璃胶囊“今天”，取代右下圆形上箭头（用户选定，同 X、Telegram 的“回到最新”）：
        // 左右对称；箭头指向今天所在方向（看之后的日子朝上、之前的日子朝下，与上下滑切日一致）；出现时自下浮起并显形；顶栏日期下注明相对天数。
        // 胶囊贴着底栏上沿（可见间隙约 18dp，同 Telegram“回到最新”），少压内容、拇指也更近。
        // 显示时是提示条的锚点：提示条停在胶囊上方，不盖住它。
        Positioned(left: 0, right: 0, bottom: MediaQuery.paddingOf(context).bottom, child: Center(child: CampusToastAnchor(enabled: _day != _today || previewing, child: _TodayReturn(
          visible: _day != _today || previewing,
          upward: _day.compareTo(_today) >= 0,
          onPressed: () {
            HapticFeedback.selectionClick();
            _selectDay(_campusDay(), recenter: true);
          },
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

// 今天页顶部的“此刻”卡（同 iOS 实时活动、Google 日历的“下一项”）：首行状态与节次，下面课名、教室（同课程卡的教室行）与教师，
// 大号剩余时长（小时分钟）加起止时刻进度条；课间画上一节下课到下一节上课的进度，第一节课前只显示时长。
// [人工决策-2026-10-06 13:06:11] 今天的课上完或今天没课时，此刻卡下方预告下一节（日子、开始时刻、课名、地点），用户选定。
// [人工决策-2026-10-18 21:03:19] 课上完与没课改为「状态为主」（取代 16:37:59 的同一骨架）：大字写“今天没课”“今天的课上完了”，下面一行“下一节 · 哪天 时刻”、
// 一行课名与教室，不放右侧大号时刻。用户反馈同一骨架像课程卡、容易误以为今天还有课，从状态为主、日期牌、分隔预告三种实物中选定状态为主
// （同 Pixel“一览”、负一屏课程卡：先说今天，下一节只是预告）。没课只在这张卡里说一次、以后没课的日子也预告，这两条不变。
// [人工决策-2026-10-18 16:37:59] 灵动化（用户选定）：到点换状态时卡片高度平滑过渡、内容先淡出再淡入（同灵动岛的形变），切日仍只由页面交接；
// 开课前 15 分钟内倒计时数字转激活色（同 Pixel“一览”临近才强调）；点卡片看这节课的详情，预告的是别的日子的课时点了跳到那天；
// 下一节是明天第 1 节时写“明天早八”。
// [人工决策-2026-10-18 21:03:19] 再加三项灵动（用户选定）：倒计时换数字时滚动（同 iOS 实时活动的数字过渡）；开课前 5 分钟内倒计时精确到秒；
// 上课中进度条末端的此刻点定时向外漾开一圈（同苹果地图的定位点），两次之间停一会儿、页面看不见或减少动画时不动。
// [人工决策-2026-11-26 12:29:30] 此刻卡能收成一条（用户 11-25 提出想法、11-26 从选项里选定，同灵动岛的展开与紧凑、Apple Music 的迷你播放条）：
// 卡片底边一道把手，点一下或往上推收成一条，条上点一下或往下拉展开（手势只在把手与条上，别处上下拖动照旧切日；没选跟着列表滚动收起、卡片上下滑）；
// 所有状态都能收：上课中与下一节写课名 · 教室与剩余时长、下面一道进度，课上完与没课写状态与下一节何时；收起后一直保持（记在显示设置里，重开应用也是条），
// 只在开课前 5 分钟自动展开一次显示秒级倒数，这时再收起，这节课开始前不再展开；上课、下课只换条里的内容。
// 点完整卡片照旧看这节课的详情（上面 10-18 那条不变），点条是展开。剩余时长一律带单位（「1小时29分」「4分59秒」：用户指出「1:29」会被看成 1 分 29 秒）；
// 下课前 5 分钟也按秒倒数（用户选定，同开课前）。
class _ClassNow extends StatefulWidget {
  const _ClassNow({required this.spans, required this.bells, required this.date, required this.today, required this.onOpen, required this.onJump, this.now, this.next});
  final List<PeriodSpan> spans;
  final List<BellPeriod> bells;
  final String date;
  final String today;
  final ValueChanged<PeriodSpan> onOpen;
  final ValueChanged<String> onJump;
  final DateTime Function()? now;
  final ({String date, CourseRecord course, CourseMeeting meeting})? next;

  @override
  State<_ClassNow> createState() => _ClassNowState();
}

// 一个状态的两种样子：完整卡片 content 与收起后的一条 strip（为空是不能收：作息不全时）；peek 是开课前 _secondsWindow 内那一节的编号（收着时自动展开一次）。
typedef _ClassNowView = ({String key, Widget content, Widget? strip, String spoken, VoidCallback? onTap, String? peek});

class _ClassNowState extends State<_ClassNow> {
  // 开课前这么多分钟内强调倒计时。
  static const _soonMinutes = 15;
  // 开课前与下课前这么多秒内倒计时精确到秒。
  static const _secondsWindow = 300;
  // 没有显示设置（测试）时只在内存里记。
  ValueNotifier<bool>? _memory;
  // 开课前自动展开过、又被收起的那一节：只展开一次。
  String? _peekDismissed;

  ValueNotifier<bool> get _collapsed => DisplayScope.read(context)?.classNowCollapsed ?? (_memory ??= ValueNotifier(false));

  void _setCollapsed(bool value) {
    HapticFeedback.selectionClick();
    final settings = DisplayScope.read(context);
    if (settings == null) {
      _collapsed.value = value;
      return;
    }
    unawaited(settings.setClassNowCollapsed(value).catchError((Object error, StackTrace stack) => campusLog('[Today] action=class_now_collapse errorType=${error.runtimeType}\n$stack')));
  }

  @override
  void dispose() {
    _memory?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clock = LiveClock.maybeOf(context);
    final listenable = clock == null || !TickerMode.valuesOf(context).enabled ? _collapsed : Listenable.merge([clock, _collapsed]);
    return ListenableBuilder(listenable: listenable, builder: (context, _) => _card(context));
  }

  // 状态键或收起与否变了才过渡；同一状态里分钟倒计时与进度原地更新。读屏整卡一句，可点时报按钮。
  Widget _card(BuildContext context) {
    final view = _state(context);
    final strip = view.strip;
    final peeking = view.peek != null && view.peek != _peekDismissed;
    final collapsed = strip != null && _collapsed.value && !peeking;
    // 收起：开着时记成一直收着；收着、只是开课前自动展开的，记下这一节不再展开。展开：记成一直展开。
    void collapse() {
      if (!_collapsed.value) return _setCollapsed(true);
      HapticFeedback.selectionClick();
      setState(() => _peekDismissed = view.peek);
    }
    void expand() => _setCollapsed(false);
    final body = collapsed || strip == null ? strip ?? view.content : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [view.content, _Grabber(onCollapse: collapse)]);
    final keyed = KeyedSubtree(key: ValueKey('${view.key}:${collapsed ? 'strip' : 'card'}'), child: body);
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : campusEnter;
    // 自成读屏节点，不并进祖先（否则整卡一句落到外层列表上，范围和按钮都不对）；把手在读屏里是「收起成一条」这个动作。
    return Semantics(
      container: true,
      button: collapsed || view.onTap != null,
      label: view.spoken,
      onTap: collapsed ? expand : view.onTap,
      onTapHint: collapsed ? '展开' : null,
      customSemanticsActions: strip == null || collapsed ? null : {const CustomSemanticsAction(label: '收起成一条'): collapse},
      excludeSemantics: true,
      // 条上往下拉展开（这里的上下拖动不再交给页面切日：手势竞技场里它更深、先认领）。
      child: _Flick(upward: false, onFlick: collapsed ? expand : null, child: SizedBox(width: double.infinity, child: CampusSurface(
        padding: EdgeInsets.zero,
        onTap: collapsed ? expand : view.onTap,
        child: AnimatedPadding(
        duration: duration,
        curve: Curves.easeInOutCubic,
        // 条矮一些；带把手的完整卡片底边留给把手。
        padding: collapsed ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12) : EdgeInsets.fromLTRB(16, 16, 16, strip == null ? 16 : 4),
        // 减少动画时直接换内容：AnimatedSize 时长为 0 会在自己的布局里报错。
        // 高度用先慢后快再慢的缓动，主要在新旧内容交接时变化：弹簧曲线前段太快，旧内容还没淡出就被裁掉（录屏所见）。
        child: MediaQuery.disableAnimationsOf(context) ? keyed : AnimatedSize(
          duration: campusEnter,
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: campusEnter,
            // 先淡出旧内容、再淡入新内容（Material 的 fade through），两段文字不叠成重影；新内容同时从 96% 放大到位。
            transitionBuilder: (child, animation) {
              final shown = animation.drive(CurveTween(curve: const Interval(.5, 1, curve: Curves.easeOut)));
              return FadeTransition(opacity: shown, child: ScaleTransition(scale: shown.drive(Tween(begin: .96, end: 1.0)), alignment: Alignment.centerLeft, child: child));
            },
            // 旧内容叠在上面淡出、不占高度，卡片高度只跟新内容走，由 AnimatedSize 过渡；
            // Stack 不裁剪，旧内容比新内容高的部分交给 AnimatedSize 按过渡中的高度裁（Stack 默认裁剪会让它当场消失）。
            layoutBuilder: (current, previous) => Stack(clipBehavior: Clip.none, children: [
              for (final child in previous) Positioned(left: 0, top: 0, right: 0, child: child),
              ?current,
            ]),
            child: keyed,
          ),
        ),
      )))),
    );
  }

  _ClassNowView _state(BuildContext context) {
    final occupied = widget.spans.where((span) => !span.empty);
    if (occupied.isEmpty) return _rest(context, widget.date == widget.today ? '今天没课' : '这天没课', CampusIcons.dayOff);
    // 作息不完整时不把“第3节”当钟点比较，也不猜测下一节或已下课。
    if (occupied.any((span) => meetingTime(widget.bells, span.meeting!) == null)) {
      return (key: 'bells', content: const Text('今日课程'), strip: null, spoken: '今日课程', onTap: null, peek: null);
    }
    final instant = widget.now?.call() ?? LiveClock.maybeOf(context)?.value ?? DateTime.now();
    final moment = classMoment(widget.spans, widget.bells, widget.date, instant);
    final focus = moment.focus;
    if (focus == null) return _rest(context, '今天的课上完了', CampusIcons.success);
    return _live(context, moment, focus, instant);
  }

  _ClassNowView _live(BuildContext context, ClassMoment moment, PeriodSpan focus, DateTime instant) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final course = focus.course!;
    final place = focus.meeting!.place;
    final status = '${moment.ongoing ? '上课中' : '下一节'} · ${periodLabel(focus.start, focus.end)}';
    final remaining = classDuration(moment.remainingMinutes);
    final suffix = moment.ongoing ? '后下课' : '后上课';
    final soon = !moment.ongoing && moment.remainingMinutes <= _soonMinutes;
    final fraction = moment.fraction;
    final left = moment.target - moment.seconds;
    // 开课前与下课前 5 分钟内按秒倒数（真实时钟下自己每秒走，到点由分钟时钟换状态）；其余按分钟，换数字时滚动。
    final seconds = left <= _secondsWindow;
    const figures = [FontFeature.tabularFigures()];
    const figure = TextStyle(fontSize: 28, fontWeight: FontWeight.w600, height: 1.15, fontFeatures: figures);
    final unit = TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: palette.onSurface);
    // 剩余时长（卡片与条共用）：数字大、单位小，一律带单位（「1小时29分」「4分59秒」，不写「1:29」免得看成分秒）。
    // 临近开课数字转激活色（大号字，单位仍是正文色，小字对比度不够），颜色渐变；动画样式先合并默认样式，不丢应用字体。
    Widget remainingOf(TextStyle figure) => AnimatedDefaultTextStyle(
      style: DefaultTextStyle.of(context).style.merge(TextStyle(color: soon ? palette.accentText : palette.onSurface)),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : campusEnter,
      child: seconds
          ? _SecondsCountdown(key: const ValueKey('class-now-remaining'), deadline: instant.add(Duration(seconds: left)), left: left, live: widget.now == null && LiveClock.liveOf(context), style: figure, unit: unit)
          : Row(key: const ValueKey('class-now-remaining'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
              for (final (text, number) in classDurationParts(moment.remainingMinutes))
                number ? CampusRollingText(text, style: figure, countsDown: true) : Text(text, style: unit),
            ]),
    );
    // 同 iOS 实时活动：课的信息在左，剩余时长在右上（数字大、单位小），起止时刻标在进度条两端。
    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          DotSeparatedText(status, style: secondary),
          const SizedBox(height: 4),
          BalancedText(course.courseName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          // 教师跟在教室后面（次要色）；首行不放教师，免得大字号下被右侧时长挤得折行。
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (place.isNotEmpty) CoursePlace(place),
            if (course.teacherName.isNotEmpty) BalancedText(course.teacherName, style: secondary.copyWith(height: 1.5)),
          ]),
        ])),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          remainingOf(figure),
          Text(suffix, style: secondary),
        ]),
      ]),
      if (fraction != null) ...[
        const SizedBox(height: 12),
        DefaultTextStyle.merge(style: secondary.copyWith(fontFeatures: figures), child: Row(children: [
          Text(moment.fromLabel),
          const SizedBox(width: 10),
          Expanded(child: _TimeTrack(fraction: fraction, pulse: moment.ongoing)),
          const SizedBox(width: 10),
          Text(moment.targetLabel),
        ])),
      ],
    ]);
    // 收起后的一条：课名 · 教室在左、剩余时长在右，下面一道同卡片的进度（课间与上课中才有）；不同字号按行中线对齐。
    // 放不下时先省略课名、教室照写（去哪上课最要紧，课名看头几个字就认得）：课名至少留三个字加省略号的宽，其余给教室，教室再长也只省略它自己
    // （模拟器上「思想道德与法治 · 综…」后改的）。
    final titleStyle = Theme.of(context).textTheme.titleMedium;
    final strip = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: LayoutBuilder(builder: (context, constraints) => Row(children: [
          Flexible(child: Text(course.courseName, maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle)),
          if (place.isNotEmpty) ConstrainedBox(
            constraints: BoxConstraints(maxWidth: math.max(constraints.maxWidth / 2, constraints.maxWidth - campusTextWidth(context, '课程名…', style: titleStyle))),
            child: Text(' · $place', maxLines: 1, overflow: TextOverflow.ellipsis, style: titleStyle),
          ),
        ]))),
        const SizedBox(width: CampusGap.medium),
        remainingOf(const TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.2, fontFeatures: figures)),
        const SizedBox(width: CampusGap.hairline),
        Text(suffix, style: secondary),
      ]),
      if (fraction != null) ...[const SizedBox(height: CampusGap.small), _TimeTrack(fraction: fraction, pulse: moment.ongoing)],
    ]);
    return (
      key: '${moment.ongoing ? 'ongoing' : 'next'}:${spanIdentity(focus)}',
      content: content,
      strip: strip,
      spoken: [status.replaceAll(' · ', '，'), course.courseName, place, course.teacherName, '$remaining$suffix'].where((part) => part.isNotEmpty).join('，'),
      onTap: () => widget.onOpen(focus),
      // 开课前 5 分钟：收着的条自动展开一次（同实时活动到点在灵动岛展开）。
      peek: !moment.ongoing && seconds ? spanIdentity(focus) : null,
    );
  }

  // 课上完或没课：大字写状态，这是今天的主要信息；有下一节就在下面预告：一行“下一节 · 哪天 时刻”，一行课名（预告里最突出）与教室。
  // 不放右侧大号时刻：那样和下面的课程卡一个样子，像今天还有这节课。
  // 哪天按离今天多远写：明天、后天，一周内写星期，更远写月日；作息缺这节时写节次。
  _ClassNowView _rest(BuildContext context, String status, IconData icon) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, height: 1.3, color: palette.onSurfaceVariant);
    // 图标对齐状态行的首行（大字号下状态会折行，居中会悬在几行中间）。
    final iconTop = ((MediaQuery.textScalerOf(context).scale(20) * 1.3 - 22) / 2).clamp(0.0, double.infinity);
    final headline = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: EdgeInsets.only(top: iconTop), child: CampusIcon(icon, color: palette.primary, size: 22)),
      const SizedBox(width: 10),
      Expanded(child: Text(status, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface))),
    ]);
    // 收起后的一条：状态在左（放不下省略）、下一节何时在右（不省略，窄屏大字号下先让状态省略，同上课中的条留着剩余时长）。
    Widget strip(String? when) => Row(children: [
      CampusIcon(icon, color: palette.primary, size: 20),
      const SizedBox(width: CampusGap.medium),
      Expanded(child: Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)),
      if (when != null) ...[const SizedBox(width: CampusGap.medium), Text(when, maxLines: 1, style: secondary.copyWith(fontFeatures: const [FontFeature.tabularFigures()]))],
    ]);
    final next = widget.next;
    if (next == null) return (key: 'rest:$status', content: headline, strip: strip(null), spoken: status, onTap: null, peek: null);
    final target = parseIsoDate(next.date);
    final offset = target.difference(parseIsoDate(widget.today)).inDays;
    // [人工决策-2026-10-19 17:55:48] 跨到下周的写「下周一」（用户选定）：以前按离今天几天算，周六看到「10月26日」其实就是后天周一、周五看到「周一」分不清是哪周。
    final week = parseIsoDate(mondayOf(next.date)).difference(parseIsoDate(mondayOf(widget.today))).inDays ~/ 7;
    final day = switch (offset) { 1 => '明天', 2 => '后天', _ when week == 0 => '周${weekdayLabel(target.weekday)}', _ when week == 1 => '下周${weekdayLabel(target.weekday)}', _ => '${target.month}月${target.day}日' };
    final early = offset == 1 && next.meeting.periodStart == 1;
    final time = meetingTime(widget.bells, next.meeting)?.startLabel ?? periodLabel(next.meeting.periodStart, next.meeting.periodEnd);
    final when = '${early ? '明天早八' : day} $time';
    final place = next.meeting.place;
    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      headline,
      const SizedBox(height: 10),
      DotSeparatedText('下一节 · $when', style: secondary.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      const SizedBox(height: 2),
      // 课名 16 号、教室 14 号排在一行：按行中线对齐。按底边对齐时小一号的教室整体偏下（汉字占满字框，看的是字的中线，不是基线），真机上像错位（用户 11-11 指出）。
      Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        BalancedText(next.course.courseName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface)),
        if (place.isNotEmpty) CoursePlace(place, size: 14),
      ]),
    ]);
    return (
      key: 'rest:$status:${next.date}:${courseKey(next.course)}:${next.meeting.periodStart}',
      content: content,
      strip: strip(when),
      spoken: [status, '下一节$when', next.course.courseName, place].where((part) => part.isNotEmpty).join('，'),
      onTap: () => widget.onJump(next.date),
      peek: null,
    );
  }
}

// 把手（同底部弹层顶上那一道）：点一下或往上推，此刻卡收成一条（人工决策见 _ClassNow）。触区比短横大，读屏里是卡片的「收起成一条」动作。
class _Grabber extends StatelessWidget {
  const _Grabber({required this.onCollapse});
  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) => Center(child: _Flick(upward: true, onFlick: onCollapse, child: GestureDetector(
    key: const ValueKey('class-now-grabber'),
    behavior: HitTestBehavior.opaque,
    onTap: onCollapse,
    child: SizedBox(width: 96, height: 24, child: Center(child: DecoratedBox(
      decoration: BoxDecoration(color: CampusPalette.of(context).onSurfaceVariant.withValues(alpha: .4), borderRadius: BorderRadius.circular(2)),
      child: const SizedBox(width: 32, height: 4),
    ))),
  )));
}

// 往上推或往下拉一下就算（同底部弹层把手的轻推，不跟手）：按位移或速度认；onFlick 为空时不接上下拖动、树的结构不变（里面的过渡不重来）。
// 接着的时候，落在这里的上下拖动不交给页面切日（手势竞技场里它更深、先认领）。
class _Flick extends StatefulWidget {
  const _Flick({required this.upward, required this.onFlick, required this.child});
  final bool upward;
  final VoidCallback? onFlick;
  final Widget child;

  @override
  State<_Flick> createState() => _FlickState();
}

class _FlickState extends State<_Flick> {
  var _moved = 0.0;

  @override
  Widget build(BuildContext context) {
    final onFlick = widget.onFlick;
    return GestureDetector(
      onVerticalDragStart: onFlick == null ? null : (_) => _moved = 0,
      onVerticalDragUpdate: onFlick == null ? null : (details) => _moved += details.delta.dy,
      onVerticalDragEnd: onFlick == null ? null : (details) {
        final sign = widget.upward ? -1 : 1;
        if (_moved * sign > 12 || (details.primaryVelocity ?? 0) * sign > 300) onFlick();
      },
      child: widget.child,
    );
  }
}

// 开课前与下课前最后几分钟的秒级倒计时（同 iOS 实时活动的计时器）：「4分59秒」「59秒」，带单位（「4:59」会和「1:29」这种时分混淆），换数字时滚动。
// 真实时钟下按截止时刻每秒自己刷新，只在页面可见时走；测试拨好的时钟不走，停在拨好那一刻的剩余秒数。
class _SecondsCountdown extends StatefulWidget {
  const _SecondsCountdown({super.key, required this.deadline, required this.left, required this.live, required this.style, required this.unit});
  final DateTime deadline;
  final int left;
  final bool live;
  final TextStyle style;
  final TextStyle unit;

  @override
  State<_SecondsCountdown> createState() => _SecondsCountdownState();
}

class _SecondsCountdownState extends State<_SecondsCountdown> {
  Timer? _tick;

  int get _left {
    if (!widget.live) return widget.left;
    final millis = widget.deadline.difference(DateTime.now()).inMilliseconds;
    return millis <= 0 ? 0 : (millis / 1000).ceil();
  }

  // 下一次换数字时再醒：剩余毫秒越过下一个整秒的那一刻。
  void _schedule() {
    _tick?.cancel();
    _tick = null;
    if (!widget.live || !TickerMode.valuesOf(context).enabled) return;
    final millis = widget.deadline.difference(DateTime.now()).inMilliseconds;
    if (millis <= 0) return;
    _tick = Timer(Duration(milliseconds: millis % 1000 + 5), () {
      if (!mounted) return;
      setState(() {});
      _schedule();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(_SecondsCountdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deadline != widget.deadline || oldWidget.live != widget.live) _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = _left, minutes = left ~/ 60;
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      if (minutes > 0) ...[CampusRollingText('$minutes', style: widget.style, countsDown: true), Text('分', style: widget.unit)],
      CampusRollingText(minutes > 0 ? (left % 60).toString().padLeft(2, '0') : '${left % 60}', style: widget.style, countsDown: true),
      Text('秒', style: widget.unit),
    ]);
  }
}

// 起止时刻进度条：浅轨道上填激活色，末端一个小圆点标出此刻；随分钟时钟平滑推进，减少动画时直接到位。
// 上课中此刻点定时向外漾开一圈淡去（同苹果地图的定位点）：一圈 1.4 秒、每 2.4 秒一次，中间停着不出帧；
// [人工决策-2026-11-09 19:18:09] 漾开跟背景云雾同拍（用户选定）：按共用节拍 campusDecorTick 每 50ms 走一步，和云雾在同一拍里合成一帧，
// 不按屏幕刷新率出帧（原因见 campus_motion.dart 的 campusDecorTick）。
// 装饰动效不能动时（减少动画、后台、分支或页面不在最前）不漾。只重画这条进度条。
class _TimeTrack extends StatefulWidget {
  const _TimeTrack({required this.fraction, required this.pulse});
  final double fraction;
  final bool pulse;

  @override
  State<_TimeTrack> createState() => _TimeTrackState();
}

class _TimeTrackState extends State<_TimeTrack> {
  // 漾开进度 0–1；一圈走完到下一圈之前停在 0，值不变就不重画。
  final _ripple = ValueNotifier<double>(0);
  static final _rippleSteps = 1400 ~/ campusDecorStep.inMilliseconds;
  static final _beatSteps = 2400 ~/ campusDecorStep.inMilliseconds;
  var _step = 0;
  var _running = false;

  void _sync() {
    final run = widget.pulse && CampusMotion.allowed(context);
    if (run == _running) return;
    _running = run;
    _step = 0;
    _ripple.value = 0;
    run ? campusDecorTick.addListener(_advance) : campusDecorTick.removeListener(_advance);
  }

  void _advance() {
    _step = (_step + 1) % _beatSteps;
    _ripple.value = _step < _rippleSteps ? _step / _rippleSteps : 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_TimeTrack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    if (_running) campusDecorTick.removeListener(_advance);
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return RepaintBoundary(child: SizedBox(height: 10, child: TweenAnimationBuilder<double>(
      tween: Tween(end: widget.fraction),
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 600),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => CustomPaint(size: Size.infinite, painter: _TimeTrackPainter(value: value, ripple: _ripple, track: palette.primary.withValues(alpha: .18), fill: palette.accent, knob: palette.surface)),
    )));
  }
}

class _TimeTrackPainter extends CustomPainter {
  _TimeTrackPainter({required this.value, required this.ripple, required this.track, required this.fill, required this.knob}) : super(repaint: ripple);
  final double value;
  final ValueNotifier<double> ripple;
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
    // 漾开的一圈：半径从此刻点向外扩到约 2.6 倍，同时淡到透明。
    final spread = Curves.easeOutCubic.transform(ripple.value);
    if (spread > 0 && spread < 1) canvas.drawCircle(center, size.height / 2 * (1 + 1.6 * spread), paint..color = fill.withValues(alpha: fill.a * .4 * (1 - spread)));
    canvas.drawCircle(center, size.height / 2, paint..color = fill);
    canvas.drawCircle(center, size.height / 2 - 2.5, paint..color = knob);
  }

  @override
  bool shouldRepaint(_TimeTrackPainter oldDelegate) => oldDelegate.value != value || oldDelegate.ripple != ripple || oldDelegate.track != track || oldDelegate.fill != fill || oldDelegate.knob != knob;
}

// 顶栏日期的两行：日期（这页的标题）与离今天多远；_dateHeader 画、_topBarHeight 量，同一份样式。
const _datePrimary = TextStyle(fontSize: CampusFontSize.cardTitle, fontWeight: FontWeight.w600);
const _dateSecondary = TextStyle(fontSize: CampusFontSize.secondary, height: 1.2);

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
