import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/playground/challenge/challenge_rules.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/challenge/challenge_run_page.dart';
import 'package:superxd/playground/challenge/points_page.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_refresh.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 游乐场的「挑战」一栏（人工决策见 challenge_rules.dart）：要登录应用账号（与教务各管各的）；上面是积分与等级，下面是本周开放的挑战
// （服务器下发，每周一换，同一挑战再玩只补超过最好成绩的部分；有门票的开局即扣、不退，积分不够时不给开始）。还有一局没结束时顶上给「继续」。
class ChallengeHome extends StatefulWidget {
  const ChallengeHome({super.key, required this.hub, required this.games, required this.store, required this.openAccount, required this.bottom, this.unlocks});
  final ChallengeHub hub;
  // 积分页列能买的解锁用；没配中转时为空。
  final UnlockAccess? unlocks;
  final List<PlaygroundGame> games;
  final PlaygroundStore store;
  // 去应用账号页登录（组合根给，游乐场不认识那一页）。
  final void Function(BuildContext context) openAccount;
  final double bottom;

  @override
  State<ChallengeHome> createState() => _ChallengeHomeState();
}

class _ChallengeHomeState extends State<ChallengeHome> {
  late final StreamSubscription<void> _changes;
  ChallengeCatalog? _catalog;
  PointsSummary? _points;
  String? _error;
  String? _starting;
  // 第几次读：登录状态变了、下拉刷新或从一局回来会再读，只认最近一次（先发的晚回来不盖掉新的，退出登录后回来的也不显示）。
  var _loads = 0;

  // 这个版本玩得了的挑战游戏连同题面写法版本（「hanoi@1」，人工决策见 challenge_rules.dart 的 11-15 19:18 那条）。
  Set<String> get _supported => challengeGameTokens([for (final game in widget.games) if (game.challengeable) game.id]);

  @override
  void initState() {
    super.initState();
    _changes = widget.hub.changes.listen((_) => unawaited(_load()));
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_changes.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final load = ++_loads;
    if (!widget.hub.signedIn) {
      setState(() {
        _catalog = null;
        _points = null;
      });
      return;
    }
    setState(() => _error = null);
    try {
      final catalog = await widget.hub.catalog(_supported);
      final points = await widget.hub.points();
      if (!mounted || load != _loads) return;
      setState(() {
        _catalog = catalog;
        _points = points;
      });
    } on ChallengeException catch (error) {
      if (mounted && load == _loads) setState(() => _error = error.message);
    }
  }

  Future<void> _openRun(ChallengeRun run) async {
    final controller = ChallengeRunController(hub: widget.hub, run: run);
    await Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => ChallengeRunPage(controller: controller, games: widget.games, store: widget.store)));
    controller.dispose();
    if (mounted) await _load();
  }

  Future<void> _resume(String runId) async {
    try {
      await _openRun(await widget.hub.run(runId));
    } on ChallengeException catch (error) {
      if (mounted) showCampusToast(context, error.message);
      await _load();
    }
  }

  Future<void> _start(ChallengeSummary challenge) async {
    final minutes = challenge.timeLimit.inMinutes;
    final confirmed = await showCampusConfirm(
      context,
      title: '开始「${challenge.title}」？',
      message: ['${challenge.levels} 关 · $minutes 分钟，计时不暂停', if (challenge.ticket > 0) '门票 ${challenge.ticket} 积分，不退'].join('\n'),
      action: '开始',
    );
    if (!confirmed || !mounted) return;
    setState(() => _starting = challenge.id);
    try {
      await _openRun(await widget.hub.start(challenge.id, _supported));
    } on ChallengeException catch (error) {
      if (!mounted) return;
      if (error.failure == ChallengeFailure.runActive && error.runId != null) {
        if (await showCampusConfirm(context, title: '上一局还没结束', message: '同时只能进行一局', action: '回到那一局')) await _resume(error.runId!);
      } else {
        showCampusToast(context, error.message);
        await _load();
      }
    } finally {
      if (mounted) setState(() => _starting = null);
    }
  }

  String _left(DateTime endsAt) {
    final left = endsAt.difference(DateTime.now());
    if (left.inDays >= 1) return '还剩 ${left.inDays} 天';
    return left.inHours >= 1 ? '还剩 ${left.inHours} 小时' : '快结束了';
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final hub = widget.hub;
    // 没登录应用账号：只给去登录的按钮。
    if (!hub.signedIn) {
      return ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + widget.bottom), children: [
        CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CampusIcon(CampusIcons.challenge, size: 28, color: palette.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('挑战要先登录', style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => widget.openAccount(context),
            icon: const CampusIcon(CampusIcons.login),
            label: const Text('登录应用账号'),
          ),
        ])),
      ]);
    }
    final catalog = _catalog;
    if (catalog == null) return _error == null ? const CampusLoading(label: '正在读本周的挑战') : CampusLoadError(message: _error!, onRetry: () => unawaited(_load()));
    // 下拉刷新用应用自己的曲线动效（同消息页、开发者的话，见 theme/campus_refresh.dart），不用 Material 的下拉小球。
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      slivers: [
        CampusRefreshControl(onRefresh: _load),
        SliverPadding(padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + widget.bottom), sliver: SliverList.list(children: [
        CampusSurface(
          onTap: () => Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => PointsPage(hub: hub, unlocks: widget.unlocks))),
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            CampusIcon(CampusIcons.points, size: 28, color: palette.primary),
            const SizedBox(width: 20),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DotSeparatedText(['积分 ${_points?.balance ?? 0}', if (_points case final points? when pointsLevelShown(points)) 'Lv${points.level}'].join(' · '), style: Theme.of(context).textTheme.titleMedium),
              if ((_points?.expiring ?? 0) > 0) Text('30 天内 ${_points!.expiring} 分到期', style: secondary),
            ])),
            CampusIcon(CampusIcons.next, color: palette.onSurfaceVariant),
          ]),
        ),
        if (catalog.activeRun case final runId?) ...[
          const SizedBox(height: 12),
          CampusSurface(padding: const EdgeInsets.all(20), child: Row(children: [
            CampusIcon(CampusIcons.timer, size: 28, color: palette.primary),
            const SizedBox(width: 20),
            Expanded(child: Text('有一局还没结束', style: Theme.of(context).textTheme.titleMedium)),
            FilledButton.icon(onPressed: () => unawaited(_resume(runId)), icon: const CampusIcon(CampusIcons.resume), label: const Text('继续')),
          ])),
        ],
        const SizedBox(height: 24),
        Text('本周挑战', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (catalog.challenges.isEmpty) Text('本周暂无挑战', style: secondary),
        for (final challenge in catalog.challenges) ...[
          CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              ChallengeShape(tiers: challenge.tiers, edges: challenge.edges),
              const SizedBox(width: 16),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                DotSeparatedText('${challenge.label} · ${challenge.title}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                DotSeparatedText(
                  [
                    '${challenge.levels} 关',
                    '限时 ${challenge.timeLimit.inMinutes} 分钟',
                    if (challenge.ticket > 0) '门票 ${challenge.ticket} 分',
                    if (challenge.best case final best?) '最好 $best 分',
                    _left(challenge.endsAt),
                  ].join(' · '),
                  style: secondary,
                ),
              ])),
            ]),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: !challenge.playable
                ? Text('更新应用后可玩', style: secondary)
                : challenge.ticket > (_points?.balance ?? 0)
                ? Text('积分不够付门票', style: secondary)
                : FilledButton(
                    onPressed: _starting == null ? () => unawaited(_start(challenge)) : null,
                    child: CampusBusyContent(busy: _starting == challenge.id, label: challenge.best == null ? '开始' : '再挑战', busyLabel: challenge.best == null ? '开始' : '再挑战', icon: const CampusIcon(CampusIcons.resume)),
                  )),
          ])),
          const SizedBox(height: 12),
        ],
        ])),
      ],
    );
  }
}

// 挑战卡上的结构缩略图（人工决策见 challenge_rules.dart 的 11-14 23:11 那条）：从左往右按串联深度排，每关一个档位色调的点，线是碎片进门的方向；
// 一眼看出几关并联、在哪汇合、整体偏哪几档。
class ChallengeShape extends StatelessWidget {
  const ChallengeShape({super.key, required this.tiers, required this.edges});
  final List<String> tiers;
  final List<(int, int)> edges;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    return Semantics(
      label: '${tiers.length} 关',
      child: CustomPaint(size: const Size(80, 56), painter: _ShapePainter(colors: [for (final tier in tiers) playTierColor(palette, PuzzleTier.named(tier) ?? PuzzleTier.entry)], edges: edges, line: palette.onSurfaceVariant.withValues(alpha: .45))),
    );
  }
}

class _ShapePainter extends CustomPainter {
  _ShapePainter({required this.colors, required this.edges, required this.line});
  final List<Color> colors;
  final List<(int, int)> edges;
  final Color line;

  // 每关最多一条出边（关卡图是树）：按到终点的距离分列，终点在最右，给碎片的关紧挨着收它的那一关；
  // 上下按整理树的排法：从终点往回走，不收碎片的关依次占一行，收碎片的关在它那几关的正中，连线不交叉；行多时点跟着缩小。
  @override
  void paint(Canvas canvas, Size size) {
    final count = colors.length;
    final target = List<int?>.filled(count, null);
    for (final (from, to) in edges) {
      if (from < count && to < count) target[from] = to;
    }
    final distance = List.filled(count, -1);
    int distanceOf(int node) => distance[node] >= 0 ? distance[node] : distance[node] = target[node] == null ? 0 : 1 + distanceOf(target[node]!);
    for (var node = 0; node < count; node++) {
      distanceOf(node);
    }
    final layers = distance.reduce((left, right) => left > right ? left : right) + 1;
    final row = List.filled(count, 0.0);
    var rows = 0;
    double place(int node) {
      final inputs = [for (var other = 0; other < count; other++) if (target[other] == node) other];
      if (inputs.isEmpty) return row[node] = (rows++).toDouble();
      return row[node] = inputs.map(place).reduce((left, right) => left + right) / inputs.length;
    }
    for (var node = 0; node < count; node++) {
      if (target[node] == null) place(node);
    }
    final pitch = rows <= 1 ? 0.0 : (size.height - 10) / (rows - 1);
    final radius = rows <= 1 ? 4.5 : (pitch * .42).clamp(2.5, 4.5).toDouble();
    final points = [
      for (var node = 0; node < count; node++)
        Offset(layers == 1 ? size.width / 2 : size.width - 5 - (size.width - 10) * distance[node] / (layers - 1), rows <= 1 ? size.height / 2 : 5 + pitch * row[node]),
    ];
    final stroke = Paint()
      ..color = line
      ..strokeWidth = 1.5;
    for (final (from, to) in edges) {
      if (from < count && to < count) canvas.drawLine(points[from], points[to], stroke);
    }
    for (var node = 0; node < count; node++) {
      canvas.drawCircle(points[node], radius, Paint()..color = colors[node]);
    }
  }

  @override
  bool shouldRepaint(_ShapePainter oldDelegate) => oldDelegate.colors != colors || oldDelegate.edges != edges || oldDelegate.line != line;
}
