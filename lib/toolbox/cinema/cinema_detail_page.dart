import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_theme.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';
import 'package:superxd/toolbox/cinema/cinema_consent.dart';
import 'package:superxd/toolbox/cinema/cinema_episodes.dart';
import 'package:superxd/toolbox/cinema/cinema_http.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';
import 'package:superxd/toolbox/cinema/cinema_player_page.dart';
import 'package:superxd/toolbox/cinema/cinema_poster.dart';
import 'package:superxd/toolbox/cinema/cinema_rule.dart';
import 'package:superxd/toolbox/cinema/cinema_service.dart';

// 一部片的选集页：选片源（同一部片在各源里的版本）、选线路、点一集播放；看过的给「接着看」。
// 片源按这台手机上最近能不能播排（rankCinemaSources，进页面时排一次、之后不跳动），默认选最前面的，名字后标「上次能播」「上次没播成」；
// 取到选集后预取接着看那一集（没看过就第一集）的播放清单，点播放时把已取到的选集交给播放页，不再请求一次（人工决策见 cinema_service.dart 的 warm 与 sourceStats）。
class CinemaDetailPage extends StatefulWidget {
  const CinemaDetailPage({super.key, required this.service, required this.title});
  final CinemaService service;
  final CinemaTitle title;
  @override
  State<CinemaDetailPage> createState() => _CinemaDetailPageState();
}

class _CinemaDetailPageState extends State<CinemaDetailPage> {
  var _source = 0;
  var _road = 0;
  // 排好的片源（读到播放记录后排一次）。
  late List<CinemaSourceRef> _sources = widget.title.sources;
  late Future<List<CinemaRoad>> _roads = _start();
  CinemaHistory? _history;
  // 最近取到选集的片源与它的选集（「接着看」据此知道有没有下一集）。
  (CinemaSourceRef, List<CinemaRoad>)? _loaded;
  // 换源、离开时这一处不再等上一次的选集（别处还在等就不中断请求）。
  Completer<void>? _cancel;
  // 顶栏片名：正文的大标题滚出去之后才出现（人工决策见 _onScroll）。
  final _scroll = ScrollController();
  final _heading = GlobalKey();
  var _titleShown = false;
  late final StreamSubscription<void> _sourceChanges;

  CinemaSourceRef get _ref => _sources[_source];

  @override
  void initState() {
    super.initState();
    unawaited(_reloadHistory());
    _scroll.addListener(_onScroll);
    _sourceChanges = widget.title.changes.listen((_) => _onSources());
  }

  @override
  void dispose() {
    unawaited(_sourceChanges.cancel());
    _cancel?.complete();
    _scroll.dispose();
    super.dispose();
  }

  // 进页面以后搜索又回来的源接在菜单末尾（11-21 Codex 指出原来进页面时复制一份就不变了，晚到的源只在「几个源」里数得到、菜单里没有）。
  void _onSources() => setState(() => _sources = appendCinemaSources(_sources, widget.title.sources));

  // [人工决策-2026-11-20 22:54:48] 顶栏片名滚动后才出现（同 iOS 大标题，用户选的）：正文已有大标题，顶栏先不写，大标题整个滚出列表顶端时淡入。
  void _onScroll() {
    final heading = _heading.currentContext?.size?.height;
    if (heading == null) return;
    final shown = _scroll.offset > CampusGap.large + heading;
    if (shown != _titleShown) setState(() => _titleShown = shown);
  }

  Future<List<CinemaRoad>> _start() async {
    try {
      final stats = await widget.service.sourceStats();
      if (mounted) setState(() => _sources = rankCinemaSources(widget.title.sources, stats));
    } catch (error, stack) {
      campusLog('[Cinema] action=source_stats errorType=${error.runtimeType}\n$stack');
    }
    return _load();
  }

  Future<void> _reloadHistory() async {
    try {
      final history = await widget.service.store.historyOf(widget.title.key, DateTime.now());
      if (mounted) setState(() => _history = history);
    } catch (error, stack) {
      campusLog('[Cinema] action=history errorType=${error.runtimeType}\n$stack');
    }
  }

  Future<List<CinemaRoad>> _load({bool fresh = false}) async {
    final ref = _ref;
    final rule = widget.service.rule(ref.ruleId);
    if (rule == null) throw const CinemaRuleException('这个源已经下架，换一个源试试');
    _cancel?.complete();
    final cancel = _cancel = Completer<void>();
    // 源还没同意（换了接口主机或改走转发）当场问（人工决策见 cinema_consent.dart）。
    final roads = await cinemaChapters(context, widget.service, rule, ref.source, fresh: fresh, cancel: cancel.future, carried: ref.carried);
    if (mounted) setState(() => _loaded = (ref, roads));
    // 预取接着看那一集（这个源看过且线路与集还在；看完了是下一集），没看过就第一集。
    final history = await _historyFuture;
    final resume = history != null && history.ruleId == ref.ruleId && history.source == ref.source && history.road < roads.length && history.episode < roads[history.road].episodes.length;
    final episode = resume ? roads[history.road].episodes[_resumeTarget(history, roads).episode] : roads.first.episodes.first;
    unawaited(widget.service.warm(episode.url, rule: rule, cancel: cancel.future));
    return roads;
  }

  // 「接着看」去哪：没看完接着上次的位置；看完了有下一集就下一集、没有就这一集从头（人工决策见 CinemaHistory.finished）。
  // roads 是记录里那个源的选集，不知道时为空：看完了就按这一集从头，不猜有没有下一集。
  ({int road, int episode, Duration start, String label}) _resumeTarget(CinemaHistory history, List<CinemaRoad>? roads) {
    if (!history.finished) return (road: history.road, episode: history.episode, start: history.position, label: '接着看 ${history.episodeName}');
    final episodes = roads != null && history.road < roads.length ? roads[history.road].episodes : const <CinemaEpisode>[];
    if (history.episode + 1 < episodes.length) return (road: history.road, episode: history.episode + 1, start: Duration.zero, label: '看下一集 ${episodes[history.episode + 1].name}');
    return (road: history.road, episode: history.episode, start: Duration.zero, label: '从头看 ${history.episodeName}');
  }

  late final Future<CinemaHistory?> _historyFuture = widget.service.store.historyOf(widget.title.key, DateTime.now()).catchError((Object error, StackTrace stack) {
    campusLog('[Cinema] action=history errorType=${error.runtimeType}\n$stack');
    return null;
  });

  void _pickSource(int index) => setState(() {
    _source = index;
    _road = 0;
    _roads = _load();
  });

  // 播的是当前片源时把已取到的选集交给播放页；接着看别的源时播放页自己取（缓存里有就不发请求）。
  Future<void> _play(int road, int episode, {Duration start = Duration.zero, CinemaSourceRef? source}) async {
    final ref = source ?? _ref;
    List<CinemaRoad>? roads;
    if (ref == _ref) {
      try {
        roads = await _roads;
      } catch (_) {
        roads = null;
      }
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      CampusPageRoute(builder: (_) => CinemaPlayerPage.title(service: widget.service, title: widget.title, source: ref, road: road, episode: episode, start: start, roads: roads)),
    );
    await _reloadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title;
    final palette = CampusPalette.of(context);
    final text = Theme.of(context).textTheme;
    final history = _history;
    final resumeSource = history == null ? null : _sources.where((ref) => ref.ruleId == history.ruleId && ref.source == history.source).firstOrNull;
    final loaded = _loaded;
    final target = history == null || resumeSource == null ? null : _resumeTarget(history, loaded != null && loaded.$1.same(resumeSource) ? loaded.$2 : resumeSource.carried?.$2);
    return Scaffold(
      appBar: AppBar(
        title: AnimatedOpacity(opacity: _titleShown ? 1 : 0, duration: const Duration(milliseconds: 200), child: Text(title.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.pop(context), icon: const CampusIcon(CampusIcons.back)),
      ),
      body: CampusScrollFade(
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.all(16),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CinemaPoster(urls: title.covers, width: 96, height: 138),
                      const SizedBox(width: CampusGap.large),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title.name, key: _heading, style: text.titleLarge),
                            const SizedBox(height: CampusGap.tight),
                            Text(
                              [if (title.year.isNotEmpty) title.year, if (title.category.isNotEmpty) title.category, if (title.remarks.isNotEmpty) title.remarks, '${title.sources.length} 个源'].join(' · '),
                              style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
                            ),
                            if (target != null) ...[
                              const SizedBox(height: CampusGap.medium),
                              FilledButton.icon(
                                style: campusProminent,
                                onPressed: () => unawaited(_play(target.road, target.episode, start: target.start, source: resumeSource)),
                                icon: const CampusIcon(CampusIcons.resume),
                                label: Text(target.label),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: CampusGap.section),
                  CampusSurface(
                    padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                    child: CampusMenuField<int>(
                      label: '片源',
                      value: _source,
                      items: [
                        for (final (index, ref) in _sources.indexed)
                          CampusMenuItem(value: index, label: cinemaSourceLabel(widget.service, ref)),
                      ],
                      onChanged: _pickSource,
                    ),
                  ),
                  const SizedBox(height: CampusGap.large),
                  FutureBuilder<List<CinemaRoad>>(
                    future: _roads,
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        final error = snapshot.error;
                        return CampusLoadError(
                          message: switch (error) {
                            CinemaRuleException(:final message) => message,
                            CinemaHttpException(:final message) => '这个源$message，换一个源试试',
                            _ => '选集没取到',
                          },
                          onRetry: () => setState(() {
                            _roads = _load(fresh: true);
                          }),
                        );
                      }
                      final roads = snapshot.data;
                      if (roads == null) return const CampusLoading(label: '正在取选集', inline: true, network: true, remote: '片源站');
                      final road = _road.clamp(0, roads.length - 1);
                      // 上次看到的那集标成选中，点它从上次的位置接着看。
                      final resume = history != null && resumeSource == _ref && history.road == road ? history : null;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (roads.length > 1 && roads.length <= 3) ...[
                            CampusSegmented<int>(values: [for (var index = 0; index < roads.length; index++) index], label: (index) => roads[index].name, selected: road, onSelected: (index) => setState(() => _road = index)),
                            const SizedBox(height: CampusGap.medium),
                          ] else if (roads.length > 3) ...[
                            CampusSurface(
                              padding: EdgeInsets.fromLTRB(16, campusFieldGap(context), 16, 16),
                              child: CampusMenuField<int>(
                                label: '线路',
                                value: road,
                                items: [for (final (index, item) in roads.indexed) CampusMenuItem(value: index, label: item.name)],
                                onChanged: (index) => setState(() => _road = index),
                              ),
                            ),
                            const SizedBox(height: CampusGap.medium),
                          ],
                          CinemaEpisodeGrid(
                            episodes: roads[road].episodes,
                            selected: resume?.episode,
                            onPick: (index) => unawaited(index == resume?.episode && !resume!.finished ? _play(road, index, start: resume.position) : _play(road, index)),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
