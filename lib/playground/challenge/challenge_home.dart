import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/challenge_run.dart';
import 'package:superxd/playground/challenge/challenge_run_page.dart';
import 'package:superxd/playground/challenge/points_page.dart';
import 'package:superxd/playground/playground_game.dart';
import 'package:superxd/playground/playground_store.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';

// 游乐场的「挑战」一栏（人工决策见 challenge_rules.dart）：要登录教务并登录应用账号；上面是积分，下面是本周开放的挑战
// （服务器下发，每周一换，同一挑战再玩只补超过最好成绩的部分）。还有一局没结束时顶上给「继续」。
class ChallengeHome extends StatefulWidget {
  const ChallengeHome({super.key, required this.hub, required this.games, required this.store, required this.openAccount, required this.openLogin, required this.bottom});
  final ChallengeHub hub;
  final List<PlaygroundGame> games;
  final PlaygroundStore store;
  // 去「我的 › 账号」登录应用账号、去登录教务（组合根给，游乐场不认识那几页）。
  final void Function(BuildContext context) openAccount;
  final void Function(BuildContext context) openLogin;
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

  Set<String> get _supported => {for (final game in widget.games) if (game.challengeable) game.id};

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
    if (!widget.hub.signedIn) {
      if (mounted) setState(() => _catalog = null);
      return;
    }
    setState(() => _error = null);
    try {
      final catalog = await widget.hub.catalog(_supported);
      final points = await widget.hub.points();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _points = points;
      });
    } on ChallengeException catch (error) {
      if (mounted) setState(() => _error = error.message);
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
      message: '${challenge.levels} 关，限时 $minutes 分钟，从现在开始计时；切到后台、来电话也照走，到点按已经过了的关结算。',
      action: '开始',
    );
    if (!confirmed || !mounted) return;
    setState(() => _starting = challenge.id);
    try {
      await _openRun(await widget.hub.start(challenge.id, _supported));
    } on ChallengeException catch (error) {
      if (!mounted) return;
      if (error.failure == ChallengeFailure.runActive && error.runId != null) {
        if (await showCampusConfirm(context, title: '上一局还没结束', message: '同一时间只能进行一局。先回到那一局，做完或提前结束后再开新的。', action: '回到那一局')) await _resume(error.runId!);
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
    // 没登录教务或应用账号：说明一句，给去登录的按钮。
    if (!hub.campusSignedIn || !hub.signedIn) {
      return ListView(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + widget.bottom), children: [
        CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            CampusIcon(CampusIcons.challenge, size: 28, color: palette.primary),
            const SizedBox(width: 12),
            Expanded(child: Text('挑战要先登录', style: Theme.of(context).textTheme.titleMedium)),
          ]),
          const SizedBox(height: 8),
          Text(hub.campusSignedIn ? '挑战由服务器出题、核对和计分，成绩记进应用账号的积分。' : '挑战的成绩记进应用账号，应用账号用教务账号登录。', style: secondary),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => hub.campusSignedIn ? widget.openAccount(context) : widget.openLogin(context),
            icon: const CampusIcon(CampusIcons.login),
            label: Text(hub.campusSignedIn ? '登录应用账号' : '登录教务'),
          ),
        ])),
      ]);
    }
    final catalog = _catalog;
    if (catalog == null) return _error == null ? const CampusLoading(label: '正在读本周的挑战') : CampusLoadError(message: _error!, onRetry: () => unawaited(_load()));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + widget.bottom), children: [
        CampusSurface(
          onTap: () => Navigator.of(context).push(CampusPageRoute<void>(builder: (context) => PointsPage(hub: hub))),
          padding: const EdgeInsets.all(20),
          child: Row(children: [
            CampusIcon(CampusIcons.points, size: 28, color: palette.primary),
            const SizedBox(width: 20),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('积分 ${_points?.balance ?? 0}', style: Theme.of(context).textTheme.titleMedium),
              if ((_points?.expiring ?? 0) > 0) Text('30 天内有 ${_points!.expiring} 分到期', style: secondary),
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
        if (catalog.challenges.isEmpty) Text('这周还没有挑战，过两天再来看看。', style: secondary),
        for (final challenge in catalog.challenges) ...[
          CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              CampusIcon(CampusIcons.challenge, size: 28, color: palette.primary),
              const SizedBox(width: 20),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${challenge.label} · ${challenge.title}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  ['${challenge.levels} 关', '限时 ${challenge.timeLimit.inMinutes} 分钟', if (challenge.best case final best?) '最好 $best 分', _left(challenge.endsAt)].join(' · '),
                  style: secondary,
                ),
              ])),
            ]),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: challenge.playable
                ? FilledButton.icon(
                    onPressed: _starting == null ? () => unawaited(_start(challenge)) : null,
                    icon: _starting == challenge.id ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const CampusIcon(CampusIcons.resume),
                    label: Text(challenge.best == null ? '开始' : '再挑战'),
                  )
                : Text('里面有新游戏，更新应用后才能玩', style: secondary)),
          ])),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }
}
