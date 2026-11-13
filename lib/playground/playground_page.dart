import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 游乐场首页（自由模式）：最上面一行「最近玩过」，下面按子类分组列出游戏卡（同应用商店按分类分组的货架）；
// 有多个板块时顶部再加板块切换（现在只有益智一个，不显示）。挑战模式做好后在标题下加「自由 | 挑战」分段。
class PlaygroundPage extends StatelessWidget {
  const PlaygroundPage({super.key, required this.store, required this.games, required this.groups});
  final PlaygroundStore store;
  final List<PlaygroundGame> games;
  final List<PlaygroundGroup> groups;

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => context.pop(), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('游乐场'),
      ),
      body: CampusScrollFade(bottom: inset, child: FutureBuilder<void>(
        future: store.ready,
        builder: (context, snapshot) => snapshot.connectionState != ConnectionState.done
            ? const CampusLoading(label: '正在准备游乐场')
            : ListenableBuilder(listenable: store, builder: (context, _) => ListView(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
                children: [
                  if (_recent case final recent when recent.isNotEmpty) ...[
                    Text('最近玩过', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final game in recent) OutlinedButton.icon(onPressed: () => _open(context, game), icon: CampusIcon(game.icon), label: Text(game.name)),
                    ]),
                    const SizedBox(height: 24),
                  ],
                  for (final group in groups)
                    if (games.where((game) => game.group.id == group.id).toList() case final members when members.isNotEmpty) ...[
                      Text(group.name, style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _GameGrid(games: members, store: store, onOpen: (game) => _open(context, game)),
                      const SizedBox(height: 24),
                    ],
                ],
              )),
      )),
    );
  }

  List<PlaygroundGame> get _recent => [
    for (final id in store.recent) ?games.where((game) => game.id == id).firstOrNull,
  ];

  void _open(BuildContext context, PlaygroundGame game) => context.push('/playground/${game.id}');
}

// 游戏卡：手机上一行一张（同百宝箱与服务页的入口卡），宽屏放得下两张整行卡时才两列，同一行的卡等高。
class _GameGrid extends StatelessWidget {
  const _GameGrid({required this.games, required this.store, required this.onOpen});
  final List<PlaygroundGame> games;
  final PlaygroundStore store;
  final ValueChanged<PlaygroundGame> onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    // 一张卡要放得下一句十个字的玩法不折行：按真实字体量，手机上与大字号下自然是一列。
    final least = campusTextWidth(context, '把一叠盘子挪到目标柱', style: const TextStyle(fontSize: 14)) + 20 + 28 + 20 + 12 + 24 + 20;
    final columns = constraints.maxWidth >= 2 * least + 12 ? 2 : 1;
    final rows = <Widget>[];
    for (var start = 0; start < games.length; start += columns) {
      final slice = games.sublist(start, math.min(start + columns, games.length));
      rows.add(Padding(
        padding: EdgeInsets.only(top: start == 0 ? 0 : 12),
        child: IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var index = 0; index < columns; index++) ...[
            if (index > 0) const SizedBox(width: 12),
            Expanded(child: index < slice.length ? _GameCard(game: slice[index], store: store, onOpen: onOpen) : const SizedBox.shrink()),
          ],
        ])),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  });
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.game, required this.store, required this.onOpen});
  final PlaygroundGame game;
  final PlaygroundStore store;
  final ValueChanged<PlaygroundGame> onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final top = store.topBest(game.id);
    // 同百宝箱入口卡的规格：内边距 20、图标 28、图标与文字间距 20、右侧「›」。
    return CampusSurface(
      onTap: () => onOpen(game),
      padding: const EdgeInsets.all(20),
      child: Row(children: [
        CampusIcon(game.icon, size: 28, color: palette.primary),
        const SizedBox(width: 20),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(game.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          BalancedText(game.summary, style: secondary),
          if (top != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              CampusIcon(CampusIcons.trophy, size: 16, color: palette.onSurfaceVariant),
              const SizedBox(width: 6),
              Flexible(child: Text('${top.tier.label} ${playDuration(Duration(milliseconds: top.best.millis), tenths: game.timeInTenths)}', style: secondary)),
            ]),
          ],
        ])),
        const SizedBox(width: 12),
        CampusIcon(CampusIcons.next, color: palette.onSurfaceVariant),
      ]),
    );
  }
}

// 对局页的外壳：等本机记录读好再建对局页（对局页按记录取上次的档），打开时记进最近玩过。
class PlaygroundGameHost extends StatefulWidget {
  const PlaygroundGameHost({super.key, required this.game, required this.store});
  final PlaygroundGame game;
  final PlaygroundStore store;

  @override
  State<PlaygroundGameHost> createState() => _PlaygroundGameHostState();
}

class _PlaygroundGameHostState extends State<PlaygroundGameHost> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.store.opened(widget.game.id).catchError((Object error, StackTrace stack) => campusLog('[Playground] action=recent_save errorType=${error.runtimeType}\n$stack')));
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: widget.store.ready,
    builder: (context, snapshot) => snapshot.connectionState == ConnectionState.done
        ? widget.game.builder(context, widget.game, widget.store)
        : const Scaffold(body: CampusLoading(label: '正在准备')),
  );
}
