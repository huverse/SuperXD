import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_icons.dart';
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

class _GradesPageState extends State<GradesPage> {
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
  @override
  void initState() {
    super.initState();
    _search.addListener(_selectRows);
    _loadTerms();
  }

  @override
  void dispose() {
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
    setState(() {
      _term = term;
      _year = term.xn;
      _yearMode = false;
      _view = null;
      _visible = [];
    });
    _loadView();
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
            if (originals.length > 1)
              const Text('同课程代码存在多条记录，以下全部保留；不推断重修替代关系。'),
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
            const Text(
              '展示教务原始字段，不推算分项权重，不把未公布当作0分。',
              style: TextStyle(fontSize: 14),
            ),
          ],
        )),
      ),
    );
  }

  Widget _panel({required Widget child}) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: CampusSurface(child: child));
  Widget _summary(GradeSummary? summary, String scope) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        scope == 'term' ? '教务汇总 · 本学期（不随列表筛选变化）' : '旧缓存教务汇总 · 范围未核实',
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
              : (year) {
                  setState(() {
                    _year = year;
                    _term = _terms.firstWhere((term) => term.xn == year);
                    _view = null;
                    _overview = [];
                  });
                  _loadView();
                },
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            CampusGlassChip(
              label: '学期详情',
              selected: !_yearMode,
              onSelected: (_) {
                setState(() => _yearMode = false);
                _loadView();
              },
            ),
            CampusGlassChip(
              label: '学年概览',
              selected: _yearMode,
              onSelected: (_) {
                setState(() => _yearMode = true);
                _loadView();
              },
            ),
          ],
        ),
        if (!_yearMode)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final term in yearTerms)
                  CampusGlassChip(
                    label: term.xq == '0'
                          ? '第一学期'
                          : term.xq == '1'
                          ? '第二学期'
                          : term.label,
                    selected: _term?.key == term.key,
                    onSelected: (_) => _chooseTerm(term),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => CampusBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            GlassPanel(
              edge: GlassEdge.bottom,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: '返回服务',
                        onPressed: () => Navigator.pop(context),
                        icon: const CampusIcon(CampusIcons.back),
                      ),
                      Expanded(
                        child: Text(
                          '成绩',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: _syncing || _choosing ? null : _sync,
                        child: Text(_syncing ? '同步中…' : '同步'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (_syncing) CampusLoading(label: _syncProgress.label, inline: true, network: true, animating: !_syncProgress.waitingForInput),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_terms.isNotEmpty) _controls(),
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
                            _panel(child: const Text('尚无学期，请点击同步后刷新学年并选择范围。')),
                          if (_yearMode && (_hasVisibleData || !_loading)) ...[
                            const SizedBox(height: 12),
                            // [人工决策-2026-09-25 01:48:56] 学年只并列教务学期汇总，不平均绩点、不累加来源不明的学分。
                            const Text('各学期独立展示，不计算未经教务提供的全年绩点。'),
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
                                child: const Text(
                                  '可点击同步获取所选学年的成绩，或切换学年查看已有记录。',
                                ),
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
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    CampusGlassChip(
                                      label: '有效成绩',
                                      selected: !_original,
                                      onSelected: (_) => setState(() {
                                        _original = false;
                                        _updateRows();
                                      }),
                                    ),
                                    CampusGlassChip(
                                      label: '原始成绩',
                                      selected: _original,
                                      onSelected: (_) => setState(() {
                                        _original = true;
                                        _updateRows();
                                      }),
                                    ),
                                  ],
                                ),
                                SizedBox(height: campusFieldGap(context)),
                                TextField(
                                  controller: _search,
                                  decoration: InputDecoration(
                                    labelText: '搜索课程名称或代码',
                                    prefixIcon: const CampusIcon(CampusIcons.search),
                                    suffixIcon: _search.text.isEmpty
                                        ? null
                                        : IconButton(
                                            tooltip: '清空搜索',
                                            onPressed: _search.clear,
                                            icon: const CampusIcon(CampusIcons.close),
                                          ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 8,
                                  children: [
                                    for (final filter
                                        in grades.GradeFilter.values)
                                      CampusGlassChip(
                                        label: switch (filter) {
                                          grades.GradeFilter.all => '全部',
                                          grades.GradeFilter.numeric => '数值成绩',
                                          grades.GradeFilter.text => '等级或状态',
                                          grades.GradeFilter.unpublished =>
                                            '未公布',
                                        },
                                        selected: _filter == filter,
                                        onSelected: (_) => setState(() {
                                          _filter = filter;
                                          _updateRows();
                                        }),
                                      ),
                                  ],
                                ),
                                SizedBox(height: campusFieldGap(context)),
                                CampusMenuField<grades.GradeSort>(
                                  label: '排序',
                                  value: _sort,
                                  items: [
                                    for (final sort in grades.GradeSort.values)
                                      CampusMenuItem(
                                        value: sort,
                                        label: switch (sort) {
                                          grades.GradeSort.original => '教务原始顺序',
                                          grades.GradeSort.high => '数值成绩从高到低',
                                          grades.GradeSort.low => '数值成绩从低到高',
                                          grades.GradeSort.name => '课程名称',
                                        },
                                      ),
                                  ],
                                  onChanged: (sort) => setState(() {
                                    _sort = sort;
                                    _updateRows();
                                  }),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '显示 ${_visible.length} 条 · 点击课程查看分项',
                                  style: const TextStyle(fontSize: 14),
                                ),
                                if (_visible.isEmpty)
                                  _panel(
                                    child: const Text(
                                      '没有符合当前条件的记录，请切换类型或清空筛选。',
                                    ),
                                  ),
                              ],
                            ],
                          ],
                        ],
                      ),
                    ),
                  ),
                  if (_hasVisibleData &&
                      !_yearMode &&
                      _view?.cached == true &&
                      _view?.empty == false)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      sliver: SliverList.builder(
                        itemCount: _visible.length,
                        itemBuilder: (context, index) {
                          final course = _visible[index];
                          return _panel(
                            child: InkWell(
                              onTap: () => _details(course),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          course.courseName,
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      const CampusIcon(CampusIcons.next),
                                    ],
                                  ),
                                  Text(
                                    '${_original ? '总评' : '有效成绩'}：${grades.gradeText(_original ? course.totalScore : course.score, missing: '未公布')}',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                      color: CampusPalette.of(context).onSurface,
                                    ),
                                  ),
                                  Text(
                                    '学分 ${grades.gradeText(course.credit)}${_original ? '' : ' · 绩点 ${grades.gradeText(course.gradePoint)}'}',
                                  ),
                                  if (course.courseCode.isNotEmpty)
                                    Text(course.courseCode),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
