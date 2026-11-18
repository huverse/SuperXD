import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:superxd/domain/campus_log.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/playground/challenge/challenge_home.dart';
import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/challenge/points_page.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_segmented.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 游乐场首页：最上面一行「最近玩过」，下面按子类分组列出游戏卡（同应用商店按分类分组的货架）；
// 有多个板块时顶部再加板块切换（现在只有益智一个，不显示）。配了中转时标题下有「自由 | 挑战」分段，挑战一栏见 challenge/challenge_home.dart。
// 新游戏抢先玩（解锁 game.<游戏 id>，人工决策见服务端 unlock_rules.ts）：锁着的卡写开放条件、点了能买的确认花积分、不能买的说明条件，
// 不进「最近玩过」；下架的不显示。
class PlaygroundPage extends StatefulWidget {
  const PlaygroundPage({super.key, required this.store, required this.games, required this.groups, this.challenges, this.unlocks, this.openAccount});
  final PlaygroundStore store;
  final List<PlaygroundGame> games;
  final List<PlaygroundGroup> groups;
  // 挑战与积分（没配中转时为空，不显示分段）与去登录应用账号（组合根给）。
  final ChallengeHub? challenges;
  // 解锁（没配中转时为空，游戏都照常开着）。
  final UnlockAccess? unlocks;
  final void Function(BuildContext context)? openAccount;

  @override
  State<PlaygroundPage> createState() => _PlaygroundPageState();
}

class _PlaygroundPageState extends State<PlaygroundPage> {
  var _challenge = false;
  StreamSubscription<void>? _unlockChanges;

  @override
  void initState() {
    super.initState();
    _unlockChanges = widget.unlocks?.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    unawaited(_unlockChanges?.cancel());
    super.dispose();
  }

  bool _locked(PlaygroundGame game) => widget.unlocks?.locked(playgroundUnlockId(game.id)) ?? false;

  RolloutUnlock? _offer(PlaygroundGame game) => widget.unlocks?.offer(playgroundUnlockId(game.id));

  // 下架的游戏（锁着又没有开放条件）不显示。
  List<PlaygroundGame> get _shown => [for (final game in widget.games) if (!_locked(game) || _offer(game) != null) game];

  Future<void> _openLocked(PlaygroundGame game, RolloutUnlock offer) async {
    final unlocks = widget.unlocks!;
    if (offer.price == null) {
      await showCampusNotice(context, unlockTerms(offer), title: '${game.name}还没开放');
      return;
    }
    if (!await showCampusConfirm(context, title: '解锁「${game.name}」？', message: '花 ${offer.price} 积分，公开后不退', action: '解锁')) return;
    try {
      await unlocks.buy(offer.id);
      if (mounted) showCampusToast(context, '已解锁「${game.name}」');
    } on UnlockException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.paddingOf(context).bottom;
    final hub = widget.challenges;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => context.pop(), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('游乐场'),
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (hub != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: CampusSegmented<bool>(values: const [false, true], label: (challenge) => challenge ? '挑战' : '自由', selected: _challenge, onSelected: (value) => setState(() => _challenge = value)),
          ),
        Expanded(child: CampusScrollFade(bottom: inset, child: hub != null && _challenge
            ? ChallengeHome(hub: hub, games: widget.games, store: widget.store, openAccount: widget.openAccount!, bottom: inset, unlocks: widget.unlocks)
            : FutureBuilder<void>(
                future: widget.store.ready,
                builder: (context, snapshot) => snapshot.connectionState != ConnectionState.done
                    ? const CampusLoading(label: '正在准备游乐场')
                    : ListenableBuilder(listenable: widget.store, builder: (context, _) => ListView(
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
                          for (final group in widget.groups)
                            if (_shown.where((game) => game.group.id == group.id).toList() case final members when members.isNotEmpty) ...[
                              Text(group.name, style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              _GameGrid(
                                games: members,
                                store: widget.store,
                                offer: (game) => _locked(game) ? _offer(game) : null,
                                onOpen: (game) => switch (_locked(game) ? _offer(game) : null) {
                                  final offer? => unawaited(_openLocked(game, offer)),
                                  null => _open(context, game),
                                },
                              ),
                              const SizedBox(height: 24),
                            ],
                        ],
                      )),
              ))),
      ]),
    );
  }

  List<PlaygroundGame> get _recent => [
    for (final id in widget.store.recent) ?widget.games.where((game) => game.id == id && !_locked(game)).firstOrNull,
  ];

  void _open(BuildContext context, PlaygroundGame game) => context.push('/playground/${game.id}');
}

// 游戏卡：手机上一行一张（同百宝箱与服务页的入口卡），宽屏放得下两张整行卡时才两列，同一行的卡等高。
class _GameGrid extends StatelessWidget {
  const _GameGrid({required this.games, required this.store, required this.offer, required this.onOpen});
  final List<PlaygroundGame> games;
  final PlaygroundStore store;
  // 锁着的游戏的开放条件，开着的为空。
  final RolloutUnlock? Function(PlaygroundGame game) offer;
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
            Expanded(child: index < slice.length ? _GameCard(game: slice[index], store: store, offer: offer(slice[index]), onOpen: onOpen) : const SizedBox.shrink()),
          ],
        ])),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  });
}

class _GameCard extends StatelessWidget {
  const _GameCard({required this.game, required this.store, required this.offer, required this.onOpen});
  final PlaygroundGame game;
  final PlaygroundStore store;
  final RolloutUnlock? offer;
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
          if (offer case final offer?) ...[
            const SizedBox(height: 6),
            // 条件折成几行时锁跟第一行对齐（高度取一行字的行高，随字号缩放）。
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: MediaQuery.textScalerOf(context).scale(14) * 1.5, child: Center(child: CampusIcon(CampusIcons.lock, size: 16, color: palette.onSurfaceVariant))),
              const SizedBox(width: 6),
              Expanded(child: DotSeparatedText(unlockTerms(offer), style: secondary)),
            ]),
          ] else if (top != null) ...[
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
// [人工决策-2026-11-15 19:18:31] 用户选「外壳读本机记录时顺便在后台把第一道题出好」（推荐）：专家档出一道题几十到上百毫秒，
// 以前在建对局页的那一帧里出，第一次打开会卡一下；现在读好记录就在另一个 isolate 里出第一道题，出好了交给对局页，界面不变。
// 只给能进挑战的游戏备（规则是纯 Dart，见 challenge_rules.dart 的 challengeRules）：画线入杯的 forge2d 不是线程安全的、舒尔特出题瞬间完成，都由对局页当场出。
// 后台最多等 firstPatience，isolate 起不来或慢得反常时不让人干等，照旧由对局页当场出。
class PlaygroundGameHost extends StatefulWidget {
  const PlaygroundGameHost({super.key, required this.game, required this.store});
  final PlaygroundGame game;
  final PlaygroundStore store;

  static const firstPatience = Duration(milliseconds: 1500);

  @override
  State<PlaygroundGameHost> createState() => _PlaygroundGameHostState();
}

class _PlaygroundGameHostState extends State<PlaygroundGameHost> {
  late final Future<PlayFirst?> _first = _prepare();
  Timer? _patience;

  @override
  void initState() {
    super.initState();
    unawaited(widget.store.opened(widget.game.id).catchError((Object error, StackTrace stack) => campusLog('[Playground] action=recent_save errorType=${error.runtimeType}\n$stack')));
  }

  @override
  void dispose() {
    _patience?.cancel();
    super.dispose();
  }

  Future<PlayFirst?> _prepare() async {
    await widget.store.ready;
    final rules = challengeRules[widget.game.id];
    if (rules == null) return null;
    final tier = widget.store.tierOf(widget.game.id), seed = math.Random().nextInt(1 << 32);
    final first = Completer<PlayFirst?>();
    _patience = Timer(PlaygroundGameHost.firstPatience, () {
      if (!first.isCompleted) first.complete(null);
    });
    unawaited(playGenerateApart(rules, seed, tier).then((draw) {
      if (!first.isCompleted) first.complete((seed: seed, tier: tier, draw: draw));
    }, onError: (Object error, StackTrace stack) {
      campusLog('[Playground] action=first_draw errorType=${error.runtimeType}\n$stack');
      if (!first.isCompleted) first.complete(null);
    }));
    final result = await first.future;
    _patience?.cancel();
    return result;
  }

  // 等第一道题时先画同对局页的顶栏（返回、游戏名），棋盘区放加载（11-17 设计审查：以前整页只有加载，慢设备上顶栏晚一拍才长出来，也没处返回）。
  @override
  Widget build(BuildContext context) => FutureBuilder<PlayFirst?>(
    future: _first,
    builder: (context, snapshot) => snapshot.connectionState == ConnectionState.done
        ? widget.game.builder(context, widget.game, widget.store, null, snapshot.data)
        : Scaffold(
            appBar: AppBar(leading: IconButton(tooltip: '返回', onPressed: () => Navigator.maybePop(context), icon: const CampusIcon(CampusIcons.back)), title: Text(widget.game.name)),
            body: const CampusLoading(label: '正在准备'),
          ),
  );
}

// 新游戏抢先玩的解锁编号：game.<游戏 id>（灰度配置 unlocks 里按这个写）。
String playgroundUnlockId(String gameId) => 'game.$gameId';
