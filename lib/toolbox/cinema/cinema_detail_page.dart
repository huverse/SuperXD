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
  // 换源、离开时这一处不再等上一次的选集（别处还在等就不中断请求）。
  Completer<void>? _cancel;
  // 顶栏片名：正文的大标题滚出去之后才出现（人工决策见 _onScroll）。
  final _scroll = ScrollController();
  final _heading = GlobalKey();
  var _titleShown = false;

  CinemaSourceRef get _ref => _sources[_source];

  @override
  void initState() {
    super.initState();
    unawaited(_reloadHistory());
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _cancel?.complete();
    _scroll.dispose();
    super.dispose();
  }

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
      final history = await widget.service.store.historyOf(widget.title.key);
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
    final roads = await widget.service.chapters(rule, ref.source, fresh: fresh, cancel: cancel.future);
    // 预取接着看那一集（这个源看过且线路与集还在），没看过就第一集。
    final history = await _historyFuture;
    final resume = history != null && history.ruleId == ref.ruleId && history.source == ref.source && history.road < roads.length && history.episode < roads[history.road].episodes.length;
    final episode = resume ? roads[history.road].episodes[history.episode] : roads.first.episodes.first;
    unawaited(widget.service.warm(episode.url, rule: rule, cancel: cancel.future));
    return roads;
  }

  late final Future<CinemaHistory?> _historyFuture = widget.service.store.historyOf(widget.title.key).catchError((Object error, StackTrace stack) {
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
    final resumeSource = history == null ? null : title.sources.where((ref) => ref.ruleId == history.ruleId && ref.source == history.source).firstOrNull;
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
                              [if (title.year.isNotEmpty) title.year, if (title.remarks.isNotEmpty) title.remarks, '${title.sources.length} 个源'].join(' · '),
                              style: text.bodyMedium?.copyWith(color: palette.onSurfaceVariant),
                            ),
                            if (history != null && resumeSource != null) ...[
                              const SizedBox(height: CampusGap.medium),
                              FilledButton.icon(
                                style: campusProminent,
                                onPressed: () => unawaited(_play(history.road, history.episode, start: history.position, source: resumeSource)),
                                icon: const CampusIcon(CampusIcons.resume),
                                label: Text('接着看 ${history.episodeName}'),
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
                            onPick: (index) => unawaited(index == resume?.episode ? _play(road, index, start: resume!.position) : _play(road, index)),
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
