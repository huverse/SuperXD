import 'package:flutter/material.dart';

import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_search_field.dart';
import 'package:superxd/application/campus_sync.dart';
import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/grades.dart' as grades;
import 'package:superxd/domain/schedule_store.dart';
import 'package:superxd/page/campus_sync_dialogs.dart';
import 'package:superxd/page/sync_selection_dialog.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/glass_panel.dart';
import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/domain/campus_log.dart';

class GradesPage extends StatefulWidget {
  const GradesPage({
    super.key,
    required this.gateway,
    this.isAccountCurrent,
    this.onLoginRequired,
  });
  final CampusGateway gateway;
  final bool Function()? isAccountCurrent;
  final VoidCallback? onLoginRequired;
  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> with SingleTickerProviderStateMixin {
  final _search = TextEditingController();
  late final _syncService = CampusSync(widget.gateway);
  List<TermRef> _terms = [];
  TermRef? _term;
  String _year = '';
  bool _yearMode = false;
  bool _original = false;
  bool _loading = true;
  bool _syncing = false;
  bool _summaryExpanded = false;
  CampusSyncProgress _syncProgress = const CampusSyncProgress('准备同步');
  bool _choosing = false;
  bool _needsLogin = false;
  int _generation = 0;
  GradesView? _view;
  String? _fetchedAt;
  String? _error;
  List<GradeTermOverview> _overview = [];
  String? _overviewYear;
  bool get _hasVisibleData => _yearMode ? _overviewYear == _year : _view?.term.key == _term?.key && _view != null;
  grades.GradeFilter _filter = grades.GradeFilter.all;
  grades.GradeSort _sort = grades.GradeSort.original;
  List<GradeCourse> _visible = [];
  Map<String, List<GradeCourse>> _originalByCode = {};
  bool get _active => mounted && (widget.isAccountCurrent?.call() ?? true);
  // [人工决策-2026-10-04 16:08:17] 成绩页切换学期详情/学年概览、学期、学年时淡出淡入，分段控件立即滑过去；用户实测确认。
  // 学期详情与学年概览、学期、学年之间的切换（淡出淡入）：旧内容先淡出，看不见时再换数据、读本地，
  // 读到（最多等 300ms）再淡入，高度与滚动位置的变化都发生在看不见的时候。分段控件按待切换的值立即滑过去，不等内容。
  // 内容区只有卡片与色调胶囊、没有玻璃，可以整体改不透明度。减少动画时直接切换。
  late final _content = AnimationController(vsync: this, value: 1);
  int _switching = 0;
  bool? _pendingYearMode;
  TermRef? _pendingTerm;

  Future<void> _switchContent(VoidCallback apply, {bool? yearMode, TermRef? term}) async {
    final switching = ++_switching;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(apply);
      await _loadView();
      return;
    }
    setState(() {
      _pendingYearMode = yearMode;
      _pendingTerm = term;
    });
    try {
      await _content.animateTo(0, duration: const Duration(milliseconds: 110), curve: Curves.easeInCubic).orCancel;
      if (!mounted || switching != _switching) return;
      setState(() {
        apply();
        _pendingYearMode = null;
        _pendingTerm = null;
      });
      await Future.any([_loadView(), Future<void>.delayed(const Duration(milliseconds: 300))]);
      if (!mounted || switching != _switching) return;
      await _content.animateTo(1, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic).orCancel;
    } on TickerCanceled {
      // 新的切换接手了动画，从当前不透明度继续。
    }
  }

  @override
  void initState() {
    super.initState();
    _search.addListener(_selectRows);
    _loadTerms();
  }

  @override
  void dispose() {
    _content.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadTerms() async {
    final request = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.gateway.listTerms();
      if (!_active || request != _generation) return;
      if (!result.ok) {
        setState(() {
          _loading = false;
          _error = result.error?.message ?? '读取学期失败';
        });
        return;
      }
      _terms = result.data!;
      _term =
          _terms.where((term) => term.key == _term?.key).firstOrNull ??
          _terms.firstOrNull;
      _year = _term?.xn ?? '';
      if (_term == null) {
        setState(() => _loading = false);
        return;
      }
      await _loadView();
    } catch (error, stack) {
      campusLog(
        '[GradesPage] action=terms errorType=${error.runtimeType}\n$stack',
      );
      if (_active && request == _generation) {
        setState(() {
          _loading = false;
          _error = '读取学期失败，请重试';
        });
      }
    }
  }

  Future<void> _loadView() async {
    if (_term == null) return;
    final request = ++_generation;
    final term = _term!;
    final year = _year;
    final yearMode = _yearMode;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (yearMode) {
        final result = await widget.gateway.readGradeYear(year);
        if (!_active || request != _generation) return;
        setState(() {
          if (result.ok) { _overview = result.data!; _overviewYear = year; }
          _error = result.ok ? null : result.error?.message;
          _loading = false;
        });
      } else {
        final result = await widget.gateway.readGrades(term);
        if (!_active || request != _generation) return;
        setState(() {
          if (result.ok) { _view = result.data; _fetchedAt = result.data?.cached == true ? result.fetchedAt : null; }
          _error = result.ok ? null : result.error?.message;
          _loading = false;
          _originalByCode = {};
          for (final course in _view?.original ?? <GradeCourse>[]) {
            if (course.courseCode.isNotEmpty) {
              _originalByCode
                  .putIfAbsent(course.courseCode, () => [])
                  .add(course);
            }
          }
          _updateRows();
        });
      }
    } catch (error, stack) {
      campusLog(
        '[GradesPage] action=read errorType=${error.runtimeType}\n$stack',
      );
      if (_active && request == _generation) {
        setState(() {
          _loading = false;
          _error = '读取成绩失败，请重试';
        });
      }
    }
  }

  void _updateRows() {
    _visible = grades.selectGrades(
      _original ? _view?.original ?? [] : _view?.effective ?? [],
      original: _original,
      query: _search.text,
      filter: _filter,
      sort: _sort,
    );
  }

  void _selectRows() {
    if (mounted) setState(_updateRows);
  }

  void _chooseTerm(TermRef term) {
    _switchContent(() {
      _term = term;
      _year = term.xn;
      _yearMode = false;
      _view = null;
      _visible = [];
    }, yearMode: false, term: term);
  }

  Future<void> _sync() async {
    if (_syncing || _choosing) return;
    _choosing = true;
    try {
      // [人工决策-2026-09-25 01:48:56] 成绩专页默认所选学年且只同步成绩；仍由用户确认学年，不自动联网或扩展同步项。
      final selection = await chooseSyncSelection(
        context,
        widget.gateway,
        initialYear: _year.isEmpty ? null : _year,
        initialContents: {SyncContent.grades},
        allowedContents: {SyncContent.grades},
      );
      if (!_active || selection == null) return;
      setState(() {
        _syncing = true;
        _error = null;
      });
      final report = await _syncService.run(
        contents: selection.contents,
        years: selection.years,
        isActive: () => _active,
        confirmSchedule: (_, _) async => false,
        chooseBells: (_, _) async => BellsChoice.cancel,
        onProgress: (progress) { if (_active) setState(() => _syncProgress = progress); },
      );
      if (!_active) return;
      _needsLogin = report.sessionExpired;
      await _loadTerms();
      if (!mounted || !_active || report.cancelled) return;
      if (report.busy) {
        setState(() => _error = '已有同步进行中，请稍后重试');
        return;
      }
      await showCampusSyncReport(context, report);
      if (_active && report.sessionExpired) widget.onLoginRequired?.call();
    } catch (error, stack) {
      campusLog(
        '[GradesPage] action=sync errorType=${error.runtimeType}\n$stack',
      );
      if (_active) setState(() => _error = '同步未完成，已有本地成绩保留');
    } finally {
      _choosing = false;
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _details(GradeCourse course) {
    final originals = _original
        ? [course]
        : _originalByCode[course.courseCode] ?? [];
    showCampusSheet<void>(
      context: context,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: .75,
        maxChildSize: .95,
        minChildSize: .35,
        builder: (context, controller) => CampusSheetPanel(child: ListView(
          controller: controller,
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    course.courseName,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: '关闭详情',
                  onPressed: () => Navigator.pop(context),
                  icon: const CampusIcon(CampusIcons.close),
                ),
              ],
            ),
            SelectableText(
              '课程代码：${course.courseCode.isEmpty ? '教务未提供' : course.courseCode}\n学分：${grades.gradeText(course.credit)}',
            ),
            if (!_original)
              SelectableText(
                '有效成绩：${grades.gradeText(course.score, missing: '未公布')}\n已获学分：${grades.gradeText(course.earnedCredit)}\n绩点：${grades.gradeText(course.gradePoint)}',
              ),
            for (final entry in course.attributes.entries)
              Text('${entry.key}：${entry.value}'),
            const SizedBox(height: 16),
            Text(
              '原始成绩记录 · ${originals.length}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (originals.isEmpty) const Text('教务未提供可按课程代码关联的原始记录。'),
            for (var index = 0; index < originals.length; index++)
              _panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '记录 ${index + 1} · ${originals[index].courseName}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    for (final value in <String, Object?>{
                      '平时成绩': originals[index].usualScore,
                      '期中成绩': originals[index].midtermScore,
                      '期末成绩': originals[index].finalScore,
                      '技能成绩': originals[index].skillScore,
                      '总评成绩': originals[index].totalScore,
                    }.entries)
                      SelectableText(
                        '${value.key}：${grades.gradeText(value.value, missing: '未公布 / 未提供')}',
                      ),
                    for (final entry in originals[index].attributes.entries)
                      Text('${entry.key}：${entry.value}'),
                  ],
                ),
              ),
          ],
        )),
      ),
    );
  }

  Widget _panel({required Widget child}) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: CampusSurface(child: child));

  // [人工决策-2026-10-18 15:32:24] 筛选收成一行「搜索框 + 筛选按钮」，成绩类型、显示范围与排序放进弹层、点了就生效，改过几项写在按钮上（同 iOS 文件、App Store）；
  // 成绩按行列在一张分组卡里：课名与学分绩点在左、分数右侧大号（同银行流水、iOS 设置分组列表），课程代码只在详情里。
  // 用户从实物截图中选定（未选横向标签条、每门一张两行卡）；以前筛选控件占满首屏，默认字号第一门课只露出一半。
  String _filterLabel(grades.GradeFilter filter) => switch (filter) {
    grades.GradeFilter.all => '全部',
    grades.GradeFilter.numeric => '数值成绩',
    grades.GradeFilter.text => '等级或状态',
    grades.GradeFilter.unpublished => '未公布',
  };

  String _sortLabel(grades.GradeSort sort) => switch (sort) {
    grades.GradeSort.original => '教务原始顺序',
    grades.GradeSort.high => '数值成绩从高到低',
    grades.GradeSort.low => '数值成绩从低到高',
    grades.GradeSort.name => '课程名称',
  };

  Widget _filterBar() {
    final changed = (_original ? 1 : 0) + (_filter == grades.GradeFilter.all ? 0 : 1) + (_sort == grades.GradeSort.original ? 0 : 1);
    return Row(children: [
      Expanded(child: CampusSearchField(controller: _search, hint: '搜索课程名称或代码')),
      const SizedBox(width: 8),
      FilledButton.icon(onPressed: _openFilters, icon: const CampusIcon(CampusIcons.filter, size: 20), label: Text(changed == 0 ? '筛选' : '筛选 $changed')),
    ]);
  }

  // 筛选弹层：同设置类选项，点了就勾上并立即生效，页面跟着更新；弹层自己的 setState 只重画勾选。
  Future<void> _openFilters() => showCampusSheet<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, setSheet) {
    void choose(VoidCallback change) {
      setState(() {
        change();
        _updateRows();
      });
      setSheet(() {});
    }
    Widget group(String title, List<Widget> chips) => Padding(padding: const EdgeInsets.only(right: 12, bottom: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: chips),
    ]));
    return CampusSheetPanel(child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Padding(padding: const EdgeInsets.only(top: 10), child: Text('筛选', style: Theme.of(context).textTheme.titleLarge))),
          IconButton(tooltip: '关闭', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.close)),
        ]),
        const SizedBox(height: 8),
        group('成绩', [
          CampusGlassChip(label: '有效成绩', selected: !_original, onSelected: (_) => choose(() => _original = false)),
          CampusGlassChip(label: '原始成绩', selected: _original, onSelected: (_) => choose(() => _original = true)),
        ]),
        group('显示', [for (final filter in grades.GradeFilter.values) CampusGlassChip(label: _filterLabel(filter), selected: _filter == filter, onSelected: (_) => choose(() => _filter = filter))]),
        group('排序', [for (final sort in grades.GradeSort.values) CampusGlassChip(label: _sortLabel(sort), selected: _sort == sort, onSelected: (_) => choose(() => _sort = sort))]),
      ]),
    ));
  }));

  // 一学期的课不多（十几到几十门），整组一次画完；按下整行变暗，读屏读整句。
  Widget _gradeList() => Padding(padding: const EdgeInsets.only(top: 8), child: CampusSurface(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: [
    for (final (index, course) in _visible.indexed) ...[
      if (index > 0) Divider(height: 1, indent: 16, endIndent: 16, color: CampusPalette.of(context).outline.withValues(alpha: .3)),
      _gradeRow(course),
    ],
  ])));

  Widget _gradeRow(GradeCourse course) {
    final palette = CampusPalette.of(context);
    final score = grades.gradeText(_original ? course.totalScore : course.score, missing: '未公布');
    final detail = '学分 ${grades.gradeText(course.credit)}${_original ? '' : ' · 绩点 ${grades.gradeText(course.gradePoint)}'}';
    return Semantics(
      button: true,
      label: '${course.courseName}，${_original ? '总评' : '成绩'} $score，${detail.replaceAll(' · ', '，')}',
      onTap: () => _details(course),
      excludeSemantics: true,
      child: InkWell(
        onTap: () => _details(course),
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 12, 10), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(course.courseName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.3, color: palette.onSurface)),
            const SizedBox(height: 2),
            DotSeparatedText(detail, style: TextStyle(fontSize: 14, height: 1.3, color: palette.onSurfaceVariant)),
          ])),
          const SizedBox(width: 12),
          Text(score, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 4),
          CampusIcon(CampusIcons.next, color: palette.onSurfaceVariant),
        ])),
      ),
    );
  }

  Widget _summary(GradeSummary? summary, String scope) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        scope == 'term' ? '教务汇总 · 本学期' : '旧缓存教务汇总 · 范围未核实',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (scope != 'term') const Text('需重新同步核对范围，不将以下数值当作本学期指标。'),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth >= 440
              ? (constraints.maxWidth - 12) / 2
              : constraints.maxWidth;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final value in <String, Object?>{
                '绩点': summary?.gpa,
                '平均分': summary?.averageScore,
                '加权平均分': summary?.weightedAverage,
                '已获学分': summary?.earnedCredit,
              }.entries)
                SizedBox(
                  width: width,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Text(value.key)),
                      Flexible(
                        child: Text(
                          grades.gradeText(value.value),
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: CampusPalette.of(context).onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );

  Widget _controls() {
    final yearTerms = _terms.where((term) => term.xn == _year).toList()
      ..sort((left, right) => left.xq.compareTo(right.xq));
    final years = _terms.map((term) => term.xn).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final yearMode = _pendingYearMode ?? _yearMode;
    final selectedTerm = _pendingTerm ?? _term;
    final motion = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 260);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CampusMenuField<String>(
          label: '学年',
          value: _year,
          items: [
            for (final year in years)
              CampusMenuItem(value: year, label: '$year–${int.parse(year) + 1}学年'),
          ],
          onChanged: _syncing
              ? null
              : (year) => _switchContent(() {
                  _year = year;
                  _term = _terms.firstWhere((term) => term.xn == year);
                  _view = null;
                  _overview = [];
                }),
        ),
        const SizedBox(height: 12),
        // 二选一用分段控件（同 iOS、鸿蒙），切换时选中块滑过去。
        CampusSegmented<bool>(
          values: const [false, true],
          selected: yearMode,
          label: (year) => year ? '学年概览' : '学期详情',
          onSelected: (year) {
            if (year == yearMode) return;
            _switchContent(() => _yearMode = year, yearMode: year);
          },
        ),
        // 学期一行随模式展开、收起，与分段控件同时开始，不等内容。
        AnimatedSize(
          duration: motion,
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: motion,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
            // 学年只有一个学期（新学年刚开学）时没得选，不画单项分段；学期名已在下方标题里。
            child: yearMode || yearTerms.length == 1
                ? const SizedBox(key: ValueKey('no-terms'), width: double.infinity)
                : yearTerms.length <= 3 && yearTerms.any((term) => term.key == selectedTerm?.key)
                ? Padding(
                    key: const ValueKey('term-segments'),
                    padding: const EdgeInsets.only(top: 4),
                    child: CampusSegmented<String>(
                      values: [for (final term in yearTerms) term.key],
                      selected: selectedTerm!.key,
                      label: (key) => _termLabel(yearTerms.firstWhere((term) => term.key == key)),
                      onSelected: (key) => _chooseTerm(yearTerms.firstWhere((term) => term.key == key)),
                    ),
                  )
                : Padding(
                    key: const ValueKey('term-chips'),
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final term in yearTerms)
                          CampusGlassChip(
                            label: _termLabel(term),
                            selected: selectedTerm?.key == term.key,
                            onSelected: (_) => _chooseTerm(term),
                          ),
                      ],
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  String _termLabel(TermRef term) => term.xq == '0' ? '第一学期' : term.xq == '1' ? '第二学期' : term.label;

  @override
  Widget build(BuildContext context) => CampusBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            CampusTopBar(
              child: Padding(
                // 返回图标对齐 16、标题从 56 起，同 AppBar（见 campus_theme.dart 的顶栏人工决策）。
                padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回服务',
                      onPressed: () => Navigator.pop(context),
                      icon: const CampusIcon(CampusIcons.back),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '成绩',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    // 顶栏操作与今天页一致：带图标的玻璃胶囊。
                    FilledButton.icon(
                      onPressed: _syncing || _choosing ? null : _sync,
                      icon: const CampusIcon(CampusIcons.sync, size: 20),
                      label: Text(_syncing ? '同步中' : '同步', style: const TextStyle(fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
            if (_syncing) CampusLoading(label: _syncProgress.label, inline: true, network: true, animating: !_syncProgress.waitingForInput),
            Expanded(
              child: CampusScrollFade(child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 0),
                    sliver: SliverToBoxAdapter(child: _terms.isNotEmpty ? _controls() : const SizedBox.shrink()),
                  ),
                  SliverFadeTransition(opacity: _content, sliver: SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_loading && !_syncing)
                            CampusLoading(label: _hasVisibleData ? '正在更新本地显示' : '正在读取成绩', inline: _hasVisibleData),
                          if (_error != null)
                            _panel(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(_error!),
                                  TextButton(
                                    onPressed: _loading ? null : _loadTerms,
                                    child: const Text('重新读取本地成绩'),
                                  ),
                                ],
                              ),
                            ),
                          if (_needsLogin)
                            TextButton(
                              onPressed: widget.onLoginRequired,
                              child: const Text('登录教务后重试（本地成绩保留）'),
                            ),
                          if (!_loading && _terms.isEmpty)
                            _panel(child: const Text('还没有学期，点「同步」获取')),
                          if (_yearMode && (_hasVisibleData || !_loading)) ...[
                            const SizedBox(height: 12),
                            // [人工决策-2026-09-25 01:48:56] 学年只并列教务学期汇总，不平均绩点、不累加来源不明的学分。
                            // [人工决策-2026-10-18 16:37:59] 去掉界面上复述这条口径的说明句，行为不变（用户选定删冗长文案）。
                            for (final overview in _overview)
                              _panel(
                                child: InkWell(
                                  onTap: () => _chooseTerm(overview.term),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              overview.term.label.isEmpty
                                                  ? overview.term.key
                                                  : overview.term.label,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium,
                                            ),
                                          ),
                                          const CampusIcon(CampusIcons.next),
                                        ],
                                      ),
                                      Text(
                                        overview.error ??
                                            (!overview.cached
                                                ? '尚未同步'
                                                : overview.empty
                                                ? '教务明确暂无成绩'
                                                : '有效记录 ${overview.effectiveCount} 条 · 原始记录 ${overview.originalCount} 条'),
                                      ),
                                      if (overview.fetchedAt != null)
                                        Text(
                                          '上次同步：${formatCampusTimestamp(overview.fetchedAt!)}',
                                        ),
                                      if (overview.cached &&
                                          overview.error == null) ...[
                                        const SizedBox(height: 12),
                                        if (overview.summaryScope == 'term')
                                          _summary(
                                            overview.summary,
                                            overview.summaryScope,
                                          )
                                        else
                                          const Text('旧汇总范围未核实，请同步后查看学期指标。'),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                          ],
                          if (!_yearMode && _hasVisibleData) ...[
                            const SizedBox(height: 12),
                            Text(
                              _term!.label.isEmpty ? _term!.key : _term!.label,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              _view!.cached
                                  ? '上次成功同步：${formatCampusTimestamp(_fetchedAt!)}'
                                  : '尚未同步此学期',
                            ),
                            if (!_view!.cached)
                              _panel(
                                child: const Text('点「同步」获取成绩'),
                              )
                            else ...[
                              _panel(
                                child: _summary(
                                  _view!.summary,
                                  _view!.summaryScope,
                                ),
                              ),
                              if (_view!.summaries.isNotEmpty)
                                ExpansionTile(
                                  onExpansionChanged: (expanded) => setState(() => _summaryExpanded = expanded),
                                  trailing: CampusMorphIcon(from: CampusIcons.expand, to: CampusIcons.collapse, selected: _summaryExpanded),
                                  title: const Text('教务汇总明细'),
                                  children: [
                                    for (final row in _view!.summaries)
                                      Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(
                                          '${row.category} · 已获学分 ${grades.gradeText(row.earnedCredit)} · 绩点 ${grades.gradeText(row.gpa)} · 平均分 ${grades.gradeText(row.averageScore)} · 加权平均分 ${grades.gradeText(row.weightedAverage)}',
                                        ),
                                      ),
                                  ],
                                ),
                              if (!_view!.empty) ...[
                                _filterBar(),
                                const SizedBox(height: 12),
                                DotSeparatedText(
                                  '${_original ? '原始成绩 · ' : ''}显示 ${_visible.length} 条 · 点击课程查看分项',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                if (_visible.isEmpty)
                                  _panel(
                                    child: const Text('没有符合筛选条件的成绩'),
                                  ),
                              ],
                            ],
                          ],
                        ],
                      ),
                    ),
                  )),
                  if (_hasVisibleData &&
                      !_yearMode &&
                      _view?.cached == true &&
                      _view?.empty == false)
                    SliverFadeTransition(opacity: _content, sliver: SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverToBoxAdapter(child: _gradeList()),
                    )),
                ],
              )),
            ),
          ],
        ),
      ),
    ),
  );
}
