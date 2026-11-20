import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_controls.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_tokens.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/toolbox/cinema/cinema_models.dart';

// 一条线路的选集（选集页与播放页共用）。
// [人工决策-2026-11-20 22:54:48] 用户选（全选推荐）：集数等宽网格（同主流视频 App，原来按字宽长短不一）；超过 cinemaEpisodePage 集分段（1–50、51–100…）、
// 可倒序看最新一集，只建当前一段的按钮（几百上千集的片原来一次建全部按钮，屏幕很长也费性能）。一格的宽度按这一段里最长的集名量，放得下几列排几列。
const cinemaEpisodePage = 50;

class CinemaEpisodeGrid extends StatefulWidget {
  const CinemaEpisodeGrid({super.key, required this.episodes, required this.selected, required this.onPick});
  final List<CinemaEpisode> episodes;
  // 标成选中的那一集（上次看到的或正在播的），没有为空；打开时、它变了时翻到它所在的那一段。
  final int? selected;
  final ValueChanged<int> onPick;

  @override
  State<CinemaEpisodeGrid> createState() => _CinemaEpisodeGridState();
}

class _CinemaEpisodeGridState extends State<CinemaEpisodeGrid> {
  var _reversed = false;
  late var _page = _pageOf(widget.selected);
  final _currentRange = GlobalKey();
  final _ranges = ScrollController();

  int get _count => widget.episodes.length;
  int get _pages => (_count + cinemaEpisodePage - 1) ~/ cinemaEpisodePage;

  // 排在第 position 个的是第几集（倒序时从最后一集起）。
  int _at(int position) => _reversed ? _count - 1 - position : position;
  int _pageOf(int? episode) => episode == null || episode >= _count ? 0 : (_reversed ? _count - 1 - episode : episode) ~/ cinemaEpisodePage;

  @override
  void initState() {
    super.initState();
    _revealRange();
  }

  @override
  void didUpdateWidget(CinemaEpisodeGrid old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected || old.episodes != widget.episodes) {
      _page = _pageOf(widget.selected);
      _revealRange();
    }
  }

  @override
  void dispose() {
    _ranges.dispose();
    super.dispose();
  }

  // 分段多、一行放不下时，把当前那一段滚进可见区（只滚分段这一行，不带着外面的页面滚）。
  void _revealRange() {
    if (_page == 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _currentRange.currentContext?.findRenderObject();
      if (target != null && _ranges.hasClients) unawaited(_ranges.position.ensureVisible(target, alignment: .5));
    });
  }

  @override
  Widget build(BuildContext context) {
    final start = _page * cinemaEpisodePage, end = (start + cinemaEpisodePage).clamp(0, _count);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_count > 1) ...[
          Row(
            children: [
              Expanded(
                child: _pages > 1
                    ? SingleChildScrollView(
                        controller: _ranges,
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var page = 0; page < _pages; page++)
                              Padding(
                                key: page == _page ? _currentRange : null,
                                padding: const EdgeInsetsDirectional.only(end: CampusGap.small),
                                child: CampusGlassChip(
                                  label: '${_at(page * cinemaEpisodePage) + 1}–${_at((page * cinemaEpisodePage + cinemaEpisodePage).clamp(0, _count) - 1) + 1}',
                                  selected: page == _page,
                                  onSelected: (_) => setState(() => _page = page),
                                ),
                              ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _reversed = !_reversed;
                  _page = 0;
                }),
                icon: const CampusIcon(CampusIcons.arrange),
                label: Text(_reversed ? '正序' : '倒序'),
              ),
            ],
          ),
          const SizedBox(height: CampusGap.medium),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final style = Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: CampusFontSize.secondary, fontWeight: FontWeight.w600);
            var widest = 0.0;
            for (var position = start; position < end; position++) {
              final width = campusTextWidth(context, widget.episodes[_at(position)].name, style: style);
              if (width > widest) widest = width;
            }
            // 选择标签左右各 12 的内边距（主题的 FilledButton），一格至少放得下这一段最长的集名。
            final columns = ((constraints.maxWidth + CampusGap.small) / (widest + CampusGap.section + CampusGap.small)).floor().clamp(1, 6);
            final cell = (constraints.maxWidth - CampusGap.small * (columns - 1)) / columns;
            return Wrap(
              spacing: CampusGap.small,
              runSpacing: CampusGap.small,
              children: [
                for (var position = start; position < end; position++)
                  SizedBox(
                    width: cell,
                    child: CampusGlassChip(label: widget.episodes[_at(position)].name, selected: _at(position) == widget.selected, onSelected: (_) => widget.onPick(_at(position))),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
