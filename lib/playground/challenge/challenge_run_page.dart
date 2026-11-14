import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_glass_menu.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 一局挑战的总览（人工决策见 challenge_rules.dart）：上面是剩下的时间（服务器计时、不暂停）与过了几关，下面按关列出：
// 开着的点进去做，锁着的写预告（挖掉的写 ?）与在等哪几关的钥匙，过了的写拿到的钥匙交给哪一关。结算后上面换成成绩与加了多少积分。
// 回到前台、到点时拉一次局面（到点的服务器顺手结算）。
class ChallengeRunPage extends StatefulWidget {
  const ChallengeRunPage({super.key, required this.controller, required this.games, required this.store});
  final ChallengeRunController controller;
  final List<PlaygroundGame> games;
  final PlaygroundStore store;

  @override
  State<ChallengeRunPage> createState() => _ChallengeRunPageState();
}

class _ChallengeRunPageState extends State<ChallengeRunPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  ChallengeRunController get _controller => widget.controller;
  late final Ticker _ticker = createTicker((_) => _tick());
  var _shownSeconds = -1;
  var _expiring = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_changed);
    _ticker.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _controller.run.running) unawaited(_controller.refresh());
  }

  void _changed() {
    if (!mounted) return;
    if (_controller.run.running && !_ticker.isActive) unawaited(_ticker.start());
    if (!_controller.run.running && _ticker.isActive) _ticker.stop();
    setState(() {});
  }

  // 按秒刷新倒计时；到点拉一次局面，服务器那边结算。
  void _tick() {
    final seconds = _controller.remaining.inSeconds;
    if (seconds != _shownSeconds) setState(() => _shownSeconds = seconds);
    if (seconds <= 0 && !_expiring) {
      _expiring = true;
      unawaited(_controller.refresh().whenComplete(() => _expiring = false));
    }
  }

  PlaygroundGame? _game(String id) => widget.games.where((game) => game.id == id).firstOrNull;

  Future<void> _open(ChallengeLevel level) async {
    final game = _game(level.game);
    if (game == null || level.state != ChallengeLevelState.open || !_controller.run.running) return;
    await Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => game.builder(context, game, widget.store, _controller.challengeFor(level.id))));
  }

  Future<void> _end() async {
    if (!await showCampusConfirm(context, title: '提前结束这一局？', message: '按已经过了的关结算，没过的关不算分。', action: '结束', destructive: true) || !mounted) return;
    final error = await _controller.end();
    if (error != null && mounted) showCampusToast(context, error.message);
  }

  Future<void> _more(BuildContext anchor) async {
    final choice = await showCampusMenu<String>(anchor, items: const [CampusMenuItem(value: 'end', label: '提前结束', icon: CampusIcons.stop)]);
    if (choice == 'end') await _end();
  }

  static const _rules = '解开一关，服务器核对通过后给这一关的钥匙（一个数）。收钥匙的关题面里挖掉了几处，钥匙齐了才解锁，挖掉的地方正好由钥匙补上。\n'
      '限时从开始算起，切到后台、来电话也照走，到点按已经过了的关结算。\n'
      '成绩看每关的难度、用时和错交次数，过的关越多、越难越高；全部过关另有奖励。同一个挑战再玩，只补超过最好成绩的部分进积分。';

  @override
  Widget build(BuildContext context) {
    final run = _controller.run;
    final palette = CampusPalette.of(context);
    final inset = MediaQuery.paddingOf(context).bottom;
    final solved = run.levels.where((level) => level.state == ChallengeLevelState.solved).length;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.maybePop(context), icon: const CampusIcon(CampusIcons.back)),
        title: Text('${run.label} · ${run.title}'),
        actions: [
          CampusGlassCircleButton(label: '玩法', size: 44, onPressed: () => showCampusNotice(context, _rules, title: '挑战的玩法'), icon: const CampusIcon(CampusIcons.info)),
          if (run.running) ...[
            const SizedBox(width: 4),
            Builder(builder: (anchor) => CampusGlassCircleButton(label: '更多操作', size: 44, onPressed: () => _more(anchor), icon: const CampusIcon(CampusIcons.manage))),
          ],
          const SizedBox(width: 8),
        ],
      ),
      body: CampusScrollFade(bottom: inset, child: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
        children: [
          if (run.result case final result?)
            _ResultCard(result: result, solved: solved, total: run.levels.length)
          else
            CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
              CampusIcon(CampusIcons.timer, size: 28, color: palette.primary),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('剩 ${playDuration(_controller.remaining.isNegative ? Duration.zero : _controller.remaining)}',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
                Text('已过 $solved/${run.levels.length} 关', style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant)),
              ])),
            ])),
          const SizedBox(height: 16),
          for (final level in run.levels) ...[
            _LevelCard(level: level, name: _controller.nameOf(level.id), game: _game(level.game), nameOf: _controller.nameOf, running: run.running, onOpen: () => _open(level)),
            const SizedBox(height: 12),
          ],
        ],
      )),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.result, required this.solved, required this.total});
  final ChallengeResult result;
  final int solved, total;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final title = switch (result.ending) {
      'cleared' => '全部过关',
      'timeout' => '时间到了',
      'stuck' => '剩下的关开不了了',
      _ => '这一局结束了',
    };
    return CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        CampusIcon(result.ending == 'cleared' ? CampusIcons.trophy : CampusIcons.flag, size: 28, color: palette.accentText),
        const SizedBox(width: 12),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
      ]),
      const SizedBox(height: 12),
      Text('${result.points} 分', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface)),
      const SizedBox(height: 4),
      Text(
        ['过了 $solved/$total 关', result.awarded > 0 ? '加了 ${result.awarded} 积分' : '没超过这个挑战的最好成绩，不加积分'].join(' · '),
        style: TextStyle(fontSize: 14, color: palette.onSurfaceVariant),
      ),
    ]));
  }
}

class _LevelCard extends StatelessWidget {
  const _LevelCard({required this.level, required this.name, required this.game, required this.nameOf, required this.running, required this.onOpen});
  final ChallengeLevel level;
  final String name;
  final PlaygroundGame? game;
  final String Function(String id) nameOf;
  final bool running;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final tier = PuzzleTier.named(level.tier)?.label ?? level.tier;
    final open = running && level.state == ChallengeLevelState.open && game != null;
    final (icon, status) = switch (level.state) {
      ChallengeLevelState.open => (game?.icon ?? CampusIcons.puzzle, running ? (level.errors > 0 ? '可以做 · 错交 ${level.errors} 次' : '可以做') : '没做完'),
      ChallengeLevelState.solved => (CampusIcons.success, level.key == null || level.output == null ? '过了' : '过了 · 钥匙 ${level.key} 交给${nameOf(level.output!)}'),
      ChallengeLevelState.failed => (CampusIcons.failed, '错交太多次，没过'),
      ChallengeLevelState.locked => (CampusIcons.locked, '等${level.inputs.map(nameOf).join('、')}的钥匙'),
    };
    return CampusSurface(
      onTap: open ? onOpen : null,
      padding: const EdgeInsets.all(20),
      child: Row(children: [
        CampusIcon(icon, size: 28, color: open ? palette.primary : palette.onSurfaceVariant),
        const SizedBox(width: 20),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$name · ${game?.name ?? '这个版本没有的游戏'}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 2),
          Text('$tier · $status', style: secondary),
          if (level.state == ChallengeLevelState.locked && level.teaser != null) ...[
            const SizedBox(height: 4),
            Text(level.teaser!, style: secondary),
          ],
        ])),
        if (open) ...[const SizedBox(width: 12), CampusIcon(CampusIcons.next, color: palette.onSurfaceVariant)],
      ]),
    );
  }
}
