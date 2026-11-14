import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/domain/rollout.dart';
import 'package:superxd/domain/unlock.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 积分（人工决策见服务端 points.service.ts）：余额、30 天内要过期的、等级（近 12 个月获得的总数定，花了不减），与流水（从新到旧，按需往下翻）。
// 积分属于应用账号，每笔满 12 个月过期。服务器还没配等级门槛时不显示等级。
// 有能用积分买的解锁（人工决策见服务端 unlock_rules.ts）时，余额下面列出来，点「解锁」确认后花积分。
class PointsPage extends StatefulWidget {
  const PointsPage({super.key, required this.hub, this.unlocks});
  final ChallengeHub hub;
  // 没配中转时为空，不列解锁。
  final UnlockAccess? unlocks;

  @override
  State<PointsPage> createState() => _PointsPageState();
}

class _PointsPageState extends State<PointsPage> {
  PointsSummary? _summary;
  final _entries = <PointsEntry>[];
  String? _next;
  String? _error;
  var _loading = false;
  String? _buying;
  StreamSubscription<void>? _unlockChanges;

  @override
  void initState() {
    super.initState();
    _unlockChanges = widget.unlocks?.changes.listen((_) {
      if (mounted) setState(() {});
    });
    unawaited(_load());
    unawaited(widget.unlocks?.refresh());
  }

  @override
  void dispose() {
    unawaited(_unlockChanges?.cancel());
    super.dispose();
  }

  Future<void> _buy(UnlockAccess unlocks, RolloutUnlock unlock) async {
    final confirmed = await showCampusConfirm(
      context,
      title: '解锁「${unlock.title}」？',
      message: '花 ${unlock.price} 积分，公开后不退',
      action: '解锁',
    );
    if (!confirmed || !mounted) return;
    setState(() => _buying = unlock.id);
    try {
      await unlocks.buy(unlock.id);
      if (mounted) showCampusToast(context, '已解锁「${unlock.title}」');
      await _load();
    } on UnlockException catch (error) {
      if (mounted) showCampusToast(context, error.message);
    } finally {
      if (mounted) setState(() => _buying = null);
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final summary = await widget.hub.points();
      final page = await widget.hub.pointsEntries();
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _entries
          ..clear()
          ..addAll(page.entries);
        _next = page.next;
      });
    } on ChallengeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _more() async {
    final next = _next;
    if (next == null || _loading) return;
    setState(() => _loading = true);
    try {
      final page = await widget.hub.pointsEntries(before: next);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _next = page.next;
      });
    } on ChallengeException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    final inset = MediaQuery.paddingOf(context).bottom;
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: '返回', onPressed: () => Navigator.maybePop(context), icon: const CampusIcon(CampusIcons.back)),
        title: const Text('积分'),
      ),
      body: summary == null
          ? (_error == null ? const CampusLoading(label: '正在读积分') : CampusLoadError(message: _error!, onRetry: () => unawaited(_load())))
          : CampusScrollFade(bottom: inset, child: ListView(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + inset),
              children: [
                CampusSurface(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CampusIcon(CampusIcons.points, size: 28, color: palette.primary),
                    const SizedBox(width: 12),
                    Text('${summary.balance}', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface)),
                  ]),
                  if (summary.expiring > 0) ...[
                    const SizedBox(height: 4),
                    Text('30 天内 ${summary.expiring} 分到期', style: secondary),
                  ],
                  if (pointsLevelShown(summary)) ...[
                    const SizedBox(height: 16),
                    Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                      Text('Lv${summary.level}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: palette.onSurface)),
                      const SizedBox(width: 12),
                      Expanded(child: Text(switch (summary.nextLevelAt) {
                        final next? => '离 Lv${summary.level + 1} 还差 ${next - summary.earned} 分',
                        null => '最高等级',
                      }, style: secondary)),
                    ]),
                  ],
                ])),
                if (widget.unlocks case final unlocks? when unlocks.purchasable.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text('解锁', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  CampusSurface(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Column(children: [
                    for (final unlock in unlocks.purchasable)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(unlock.title, style: Theme.of(context).textTheme.bodyLarge),
                          DotSeparatedText(unlockTerms(unlock), style: secondary),
                        ])),
                        const SizedBox(width: 12),
                        FilledButton.tonalIcon(
                          onPressed: _buying == null ? () => unawaited(_buy(unlocks, unlock)) : null,
                          icon: _buying == unlock.id ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const CampusIcon(CampusIcons.unlock),
                          label: const Text('解锁'),
                        ),
                      ])),
                  ])),
                ],
                const SizedBox(height: 24),
                Text('明细', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_entries.isEmpty)
                  Text('暂无明细', style: secondary)
                else
                  CampusSurface(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8), child: Column(children: [
                    for (final entry in _entries)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(entry.note.isNotEmpty ? entry.note : _kindLabel(entry.kind), style: Theme.of(context).textTheme.bodyLarge),
                          Text('${_kindLabel(entry.kind)} · ${formatCampusRelative(entry.at.toIso8601String())}', style: secondary),
                        ])),
                        const SizedBox(width: 12),
                        Text(entry.amount > 0 ? '+${entry.amount}' : '${entry.amount}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: entry.amount > 0 ? palette.onSurface : palette.onSurfaceVariant)),
                      ])),
                  ])),
                if (_next != null) ...[
                  const SizedBox(height: 8),
                  Center(child: OutlinedButton.icon(onPressed: _loading ? null : () => unawaited(_more()), icon: const CampusIcon(CampusIcons.expand), label: const Text('更早的'))),
                ],
              ],
            )),
    );
  }

  static String _kindLabel(String kind) => switch (kind) {
    'earn' => '获得',
    'expire' => '过期',
    'spend' => '使用',
    'refund' => '退回',
    _ => '变动',
  };
}

// 服务器配了等级门槛才显示等级（没配时人人 Lv0、也没有下一级）。
bool pointsLevelShown(PointsSummary summary) => summary.level > 0 || summary.nextLevelAt != null;

// 一项解锁的条件，写成「300 分 · Lv3 · 12月1日 00:00 开放」这样一句（积分页与锁着的游戏卡共用，前面有锁或价格，不再写「起免费」「起人人可用」）。
String unlockTerms(RolloutUnlock unlock) => [
  if (unlock.price != null) '${unlock.price} 分',
  if (unlock.minLevel case final level?) 'Lv$level',
  if (unlock.percent != null && unlock.minLevel == null && unlock.price == null) '抽签',
  if (unlock.publicAt case final at?) '${formatCampusRelative(at.toIso8601String())} 开放',
].join(' · ');
