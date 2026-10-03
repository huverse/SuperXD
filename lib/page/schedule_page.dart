import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/application/campus_reminders.dart';
import 'package:superxd/domain/period_spans.dart';
import 'package:superxd/page/reminder_dialog.dart';
import 'package:superxd/page/calendar_export.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/domain/week.dart';
import 'package:superxd/page/course_cards.dart';
import 'package:superxd/page/date_rail.dart';
import 'package:superxd/page/schedule_calendar.dart';
import 'package:superxd/page/schedule_editor_page.dart';
import 'package:superxd/page/term_start_dialog.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/domain/campus_log.dart';

enum ScheduleRange { day, term, year }

class ScheduleSelection {
  const ScheduleSelection({required this.range, required this.year, required this.date, this.month, this.week, this.inYearTerm = false, this.detailKey});
  final ScheduleRange range;
  final String year;
  final String date;
  final int? month;
  final int? week;
  final bool inYearTerm;
  final String? detailKey;
  bool get yearOverview => range == ScheduleRange.year && !inYearTerm;
  bool get showRail => range != ScheduleRange.day && !yearOverview;
  ScheduleSelection copy({ScheduleRange? range, String? year, String? date, int? month, int? week, bool? inYearTerm, String? detailKey, bool clearDetail = false, bool clearDrill = false}) => ScheduleSelection(
    range: range ?? this.range, year: year ?? this.year, date: date ?? this.date,
    month: clearDrill ? null : month ?? this.month, week: clearDrill ? null : week ?? this.week,
    inYearTerm: inYearTerm ?? this.inYearTerm, detailKey: clearDetail ? null : detailKey ?? this.detailKey,
  );
}

class SchedulePage extends StatefulWidget {
  const SchedulePage({super.key, required this.gateway, this.reminders, this.openCalendar = openCalendarFile});
  final CampusGateway gateway;
  // 为空时不显示课前提醒入口（测试与未接入提醒的环境）。
  final CampusReminders? reminders;
  final CalendarOpener openCalendar;
  @override
  State<SchedulePage> createState() => _SchedulePageState();
}

class _SchedulePageState extends State<SchedulePage> with SingleTickerProviderStateMixin {
  List<TermRef> _terms = [];
  TermRef? _term;
  String? _start;
  List<BellPeriod> _bells = [];
  List<CourseRecord> _courses = [];
  final Map<String, List<PeriodSpan>> _byDay = {};
  late ScheduleSelection _selection = ScheduleSelection(range: ScheduleRange.day, year: '', date: campusToday());
  PageController? _pager;
  String? _first;
  String? _last;
  int _request = 0;
  int _recenterRequest = 0;
  int _weekCount = 1;
  bool _loading = true;
  bool _refreshingCurrent = false;
  bool _knownSchedule = false;
  Widget? _outgoingDay;
  late final _dayTransition = AnimationController(vsync: this, duration: const Duration(milliseconds: 250), value: 1);
  late final _dayCurve = CurvedAnimation(parent: _dayTransition, curve: Curves.easeInOutCubic);

  @override
  void initState() {
    super.initState();
    _dayTransition.addStatusListener((status) { if (status == AnimationStatus.completed && mounted && _outgoingDay != null) setState(() => _outgoingDay = null); });
    _load();
  }
  @override
  void dispose() { _pager?.dispose(); _dayCurve.dispose(); _dayTransition.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final listed = await widget.gateway.listTerms();
      if (!mounted) return;
      if (!listed.ok || listed.data?.isNotEmpty != true) {
        setState(() => _loading = false);
        await _notice(listed.error?.message ?? '尚未同步课表，请先在今天页选择同步范围。');
        return;
      }
      _terms = listed.data!;
      await _loadTerm(_terms.first, date: campusToday());
    } catch (error, stack) {
      campusLog('[Schedule] action=load errorType=${error.runtimeType}\n$stack');
      if (mounted) { setState(() => _loading = false); await _notice('读取本地课表失败'); }
    }
  }

  Future<void> _loadTerm(TermRef term, {String? date}) async {
    final request = ++_request;
    setState(() { _refreshingCurrent = _term?.key == term.key; _loading = true; });
    try {
      final full = await widget.gateway.readSchedule(ScheduleScope.term(term));
      final bells = await widget.gateway.readBells(term);
      if (!mounted || request != _request) return;
      if (!full.ok || full.data == null) { setState(() => _loading = false); await _notice(full.error?.message ?? '课表读取失败'); return; }
      _term = term;
      _courses = full.data!.courses;
      _knownSchedule = full.data!.revisionId != null;
      _start = full.data!.termStartDate;
      _bells = bells.data?.periods ?? [];
      _selection = _selection.copy(year: term.xn, date: date ?? _selection.date, clearDrill: true, clearDetail: true);
      _rebuildCalendar();
      setState(() => _loading = false);
      if (!bells.ok) await _notice(bells.error?.message ?? '作息读取失败');
    } catch (error, stack) {
      campusLog('[Schedule] action=load_term errorType=${error.runtimeType}\n$stack');
      if (mounted && request == _request) { setState(() => _loading = false); await _notice('课表读取失败'); }
    }
  }

  void _rebuildCalendar() {
    _byDay.clear();
    _weekCount = maxCourseWeek(_courses);
    final old = _pager;
    _pager = null;
    _first = _start;
    _last = _start == null ? null : weekRange(_start!, _weekCount).end;
    if (_first != null && _last != null) {
      var selected = _selection.date;
      if (selected.compareTo(_first!) < 0 || selected.compareTo(_last!) > 0) selected = _first!;
      _selection = _selection.copy(date: selected, clearDetail: true);
      _pager = PageController(initialPage: _indexOf(selected));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  int _indexOf(String date) => parseIsoDate(date).difference(parseIsoDate(_first!)).inDays;
  String _dateAt(int index) => formatIsoDate(parseIsoDate(_first!).add(Duration(days: index)));
  List<PeriodSpan> _spans(String date) {
    final saved = _byDay[date];
    if (saved != null) return saved;
    final courses = visibleCourses(_courses, ScheduleScope.day(term: _term!, date: date, termStartDate: _start!));
    if (_byDay.length >= 5) _byDay.remove(_byDay.keys.first);
    return _byDay[date] = List.unmodifiable(periodSpans(courses, bells: _bells, termLastPeriod: maxCoursePeriod(_courses)));
  }

  void _selectDate(String date, {bool fromSwipe = false}) {
    if (_first == null || _last == null || date.compareTo(_first!) < 0 || date.compareTo(_last!) > 0) return;
    final week = weekIndex(_start!, date);
    if (date != _selection.date && !fromSwipe && !MediaQuery.disableAnimationsOf(context)) {
      _outgoingDay = IgnorePointer(child: CourseDayCards(key: ValueKey('outgoing-${_selection.date}'), spans: _spans(_selection.date), bells: _bells, date: _selection.date));
      _dayTransition.forward(from: 0);
    }
    setState(() => _selection = _selection.copy(date: date, month: parseIsoDate(mondayOf(date)).month, week: week, clearDetail: true));
    // 显式目标一次提交，绝不经过中间月份。手势页自身移动，不反向驱动controller。
    if (!fromSwipe) {
      if (_pager?.hasClients == true) {
        _pager!.jumpToPage(_indexOf(date));
      } else {
        final old = _pager;
        _pager = PageController(initialPage: _indexOf(date));
        WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      }
    }
  }

  void _selectRange(ScheduleRange range) {
    if (range == _selection.range) return;
    setState(() => _selection = _selection.copy(range: range, inYearTerm: false, clearDetail: true, clearDrill: true));
  }

  Future<void> _openTerm(TermRef term) async {
    setState(() => _selection = _selection.copy(inYearTerm: true, year: term.xn, clearDrill: true, clearDetail: true));
    await _loadTerm(term);
  }

  Future<void> _today() async {
    if (_terms.isEmpty) return;
    if (_term?.key != _terms.first.key) await _loadTerm(_terms.first, date: campusToday());
    if (!mounted) return;
    if (_start == null) { await _notice('请先设置当前学期的开学日。'); return; }
    final date = campusToday();
    if (date.compareTo(_first!) < 0 || date.compareTo(_last!) > 0) { await _notice('今天不在已同步课表的教学日期范围内。'); return; }
    setState(() {
      _selection = _selection.copy(inYearTerm: _selection.range == ScheduleRange.year);
      _recenterRequest++;
    });
    _selectDate(date);
  }

  Future<void> _editStart() async {
    final term = _term;
    if (term == null || _loading) return;
    final saved = await editTermStart(context, widget.gateway, term, _start);
    if (!mounted || saved == null || _term?.key != term.key) return;
    ++_request;
    _start = saved;
    _selection = _selection.copy(clearDrill: true, clearDetail: true);
    _rebuildCalendar();
    setState(() {});
  }

  Future<void> _manage({CourseRecord? course, CourseMeeting? slot}) async {
    final term = _term;
    if (term == null || _loading) return;
    final selection = _selection;
    await Navigator.push<bool>(context, MaterialPageRoute(builder: (context) => ScheduleEditorPage(
      gateway: widget.gateway, term: term, courseId: course == null ? null : courseKey(course), slot: slot,
      selectedWeek: _start == null ? null : weekIndex(_start!, _selection.date),
    )));
    if (!mounted) return;
    await _loadTerm(term, date: selection.date);
    if (!mounted) return;
    final selectedDate = _selection.date;
    setState(() => _selection = selection.copy(date: selectedDate, clearDetail: true,
      clearDrill: selectedDate != selection.date || selection.week != null && selection.week! > _weekCount));
    if (selectedDate != selection.date) await _notice('课程日期范围已变化，已切换到当前课表的有效日期。');
  }

  // [人工决策-2026-09-29 01:01:28] 无课时段预填当天星期与节次，周次仅本周，扩大周次须用户在时段里自选；可新增或安排已有课程，仅课表页，今天页保持只读。
  CourseMeeting _slot(String date, PeriodSpan span) => CourseMeeting(weekday: weekdayOf(date), periodStart: span.start, periodEnd: span.end, place: '', weeks: [weekIndex(_start!, date)]);

  Future<void> _arrange(String date, PeriodSpan span) async {
    final chosen = await showCampusDialog<CourseRecord>(context: context, builder: (context) => CampusGlassDialog(
      title: const Text('安排已有课程'),
      options: [for (final course in _courses) SimpleDialogOption(onPressed: () => Navigator.pop(context, course), child: Text(course.teacherName.isEmpty ? course.courseName : '${course.courseName} · ${course.teacherName}'))],
    ));
    if (mounted && chosen != null) await _manage(course: chosen, slot: _slot(date, span));
  }

  bool get _canPop => _selection.detailKey == null && (_selection.range == ScheduleRange.day || _selection.month == null) && !_selection.inYearTerm;
  void _back() {
    if (_selection.detailKey != null) { setState(() => _selection = _selection.copy(clearDetail: true)); return; }
    if (_selection.range != ScheduleRange.day && _selection.month != null) { setState(() => _selection = _selection.copy(clearDrill: true)); return; }
    if (_selection.inYearTerm) { setState(() => _selection = _selection.copy(inYearTerm: false)); return; }
    context.pop();
  }

  Future<void> _notice(String text) async {
    if (mounted) await showCampusNotice(context, text);
  }

  Future<void> _more(BuildContext anchor) async {
    final action = await showCampusMenu<String>(anchor, items: [
      if (widget.reminders != null) const CampusMenuItem(value: 'reminder', label: '课前提醒', icon: CampusIcons.reminder),
      if (_term != null) const CampusMenuItem(value: 'export', label: '导出到日历', icon: CampusIcons.exportCalendar),
    ]);
    if (!mounted) return;
    switch (action) {
      case 'reminder':
        await showReminderSettings(context, gateway: widget.gateway, reminders: widget.reminders!);
      case 'export' when !_knownSchedule:
        await _notice('该学期尚未同步，请在今天页选择这个学年同步。');
      case 'export':
        await exportTermCalendar(context, term: _term!, termStartDate: _start, bells: _bells, courses: _courses, open: widget.openCalendar);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 300);
    return PopScope(canPop: _canPop, onPopInvokedWithResult: (didPop, _) { if (!didPop) _back(); }, child: CampusBackground(child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(bottom: true, top: false, child: Column(children: [
        CampusTopBar(child: SizedBox(height: 56 * scale, child: Row(children: [
          IconButton(tooltip: '返回', onPressed: _back, icon: const CampusIcon(CampusIcons.back)),
          Expanded(child: Text(_selection.yearOverview && _selection.year.isNotEmpty ? '${_selection.year}–${int.parse(_selection.year)+1}' : '课表', style: Theme.of(context).textTheme.titleLarge)),
          TextButton(onPressed: _term == null || _loading ? null : _editStart, child: const Text('开学日')),
          TextButton(onPressed: _loading ? null : _today, child: const Text('今天')),
          IconButton(tooltip: '管理课程', onPressed: _term == null || _loading ? null : _manage, icon: const CampusIcon(CampusIcons.manageSchedule)),
          Builder(builder: (anchor) => IconButton(tooltip: '更多操作', onPressed: _loading || _term == null && widget.reminders == null ? null : () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
        ]))),
        SizedBox(height: 48 * scale, child: Row(children: [for (final range in ScheduleRange.values) Expanded(child: InkWell(
          onTap: () => _selectRange(range), child: Center(child: AnimatedContainer(duration: motion, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: range == _selection.range ? CampusPalette.of(context).surfaceSelected : Colors.transparent, borderRadius: BorderRadius.circular(12)), child: Text(switch(range) { ScheduleRange.day => '天', ScheduleRange.term => '学期', ScheduleRange.year => '学年' }, style: TextStyle(fontSize: 16, color: range == _selection.range ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant)))),
        ))])),
        // 日期栏从不因钻取/范围改变被销毁。只在更换学期时替换其日期集合。
        SizedBox(height: DateRail.heightOf(context), child: _first == null || _last == null
            ? Center(child: Text(_term?.label ?? '课表', style: const TextStyle(fontSize: 14)))
            : DateRail(first: _first!, last: _last!, selected: _selection.date, recenterRequest: _recenterRequest, onSelect: _selectDate)),
        if (_loading && _refreshingCurrent) const CampusLoading(label: '正在更新课表', inline: true),
        Expanded(child: _loading && !_refreshingCurrent ? const Center(child: CampusLoading(label: '正在读取课表')) : CampusScrollFade(child: AnimatedSwitcher(duration: motion,
          child: _selection.yearOverview ? _years() : _content(scale, motion),
        ))),
      ])),
    )));
  }

  Widget _years() {
    final years = _terms.map((term) => term.xn).toSet().toList()..sort();
    final index = years.indexOf(_selection.year);
    return ListView(key: const ValueKey('years'), padding: const EdgeInsets.all(16), children: [
      Row(children: [
        TextButton(onPressed: index <= 0 ? null : () => setState(() => _selection = _selection.copy(year: years[index-1])), child: const Text('上一年')),
        const Spacer(),
        TextButton(onPressed: index < 0 || index >= years.length-1 ? null : () => setState(() => _selection = _selection.copy(year: years[index+1])), child: const Text('下一年')),
      ]),
      for (final term in _terms.where((term) => term.xn == _selection.year)) Padding(padding: const EdgeInsets.only(bottom: 12), child: _tile(term.label.isEmpty ? term.key : term.label, false, () => _openTerm(term), minHeight: 72)),
    ]);
  }

  Widget _content(double scale, Duration motion) {
    if (!_knownSchedule) return Center(key: const ValueKey('not-synced'), child: TextButton(onPressed: () => _notice('该学期尚未同步，请在今天页选择这个学年同步。'), child: const Text('尚未同步此学期')));
    if (_start == null) return Center(key: const ValueKey('start'), child: FilledButton(onPressed: _editStart, child: const Text('设置开学日')));
    final showRail = _selection.showRail;
    return LayoutBuilder(key: const ValueKey('calendar-body'), builder: (context, constraints) {
      final railWidth = math.min(112 * scale, constraints.maxWidth * .34);
      return Padding(padding: const EdgeInsets.all(16), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AnimatedContainer(duration: motion, curve: Curves.easeInOutCubic, width: showRail ? railWidth : 0,
          child: ClipRect(child: OverflowBox(alignment: Alignment.topLeft, minWidth: railWidth, maxWidth: railWidth, child: IgnorePointer(ignoring: !showRail, child: _months(scale, constraints.maxHeight))))),
        AnimatedContainer(duration: motion, width: showRail ? 12 : 0),
        Expanded(child: Stack(children: [
          FadeTransition(opacity: _dayCurve, child: PageView.builder(
          key: ValueKey('days-${_term!.key}-$_start'), controller: _pager,
          itemCount: _indexOf(_last!) + 1,
          onPageChanged: (index) { final date = _dateAt(index); if (date != _selection.date) _selectDate(date, fromSwipe: true); },
          itemBuilder: (context, index) {
            final date = _dateAt(index);
            return CourseDayCards(key: ValueKey(date), spans: _spans(date), bells: _bells, date: date,
              detailKey: date == _selection.date ? _selection.detailKey : null,
              onDetail: (key) => setState(() => _selection = _selection.copy(detailKey: key, clearDetail: key == null)),
              onEdit: (course) => _manage(course: course),
              onCreate: (span) => _manage(slot: _slot(date, span)),
              onArrange: _courses.isEmpty ? null : (span) => _arrange(date, span),
            );
          },
        )),
          if (_outgoingDay != null) Positioned.fill(child: FadeTransition(opacity: ReverseAnimation(_dayCurve), child: _outgoingDay)),
        ])),
      ]));
    });
  }

  Widget _months(double scale, double availableHeight) {
    final months = monthsOfTerm(_start!, _weekCount);
    final gap = (availableHeight / 90).clamp(6.0, 12.0);
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 300);
    return ListView(padding: EdgeInsets.zero, children: [for (final month in months) ...[
      Padding(padding: EdgeInsets.only(bottom: gap), child: _tile('$month月', month == _selection.month, () => setState(() {
        _selection = month == _selection.month ? _selection.copy(clearDrill: true) : _selection.copy(month: month, clearDetail: true);
      }), minHeight: 48 * scale)),
      AnimatedSize(duration: motion, curve: Curves.easeInOutCubic, alignment: Alignment.topCenter, child: month != _selection.month ? const SizedBox(width: double.infinity) : Column(children: [
        for (final week in weeksOfMonth(_start!, _weekCount, month)) Padding(padding: EdgeInsets.only(bottom: gap), child: _tile(weekRailLabel(_start!, week), week == _selection.week, () => _selectDate(dayInWeek(termStartDate: _start!, week: week, today: campusToday())), minHeight: 64 * scale)),
      ])),
    ]]);
  }

  Widget _tile(String label, bool selected, VoidCallback tap, {required double minHeight}) => Material(
    color: selected ? CampusPalette.of(context).surfaceSelected : CampusPalette.of(context).surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).outlineSubtle)),
    child: InkWell(borderRadius: BorderRadius.circular(16), onTap: tap, child: ConstrainedBox(constraints: BoxConstraints(minHeight: minHeight), child: Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: Text(label, style: TextStyle(fontSize: 14, color: selected ? CampusPalette.of(context).primary : CampusPalette.of(context).onSurfaceVariant)))))),
  );
}
