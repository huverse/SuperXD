import 'dart:async';

import 'package:flutter/material.dart';

import 'package:superxd/domain/campus_clock.dart';
import 'package:superxd/domain/challenge.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_loading.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_surface.dart';
import 'package:superxd/theme/scroll_edge_fade.dart';

// 积分（人工决策见服务端 points.service.ts）：余额、30 天内要过期的，与流水（从新到旧，按需往下翻）。积分属于应用账号，每笔满 12 个月过期。
class PointsPage extends StatefulWidget {
  const PointsPage({super.key, required this.hub});
  final ChallengeHub hub;

  @override
  State<PointsPage> createState() => _PointsPageState();
}

class _PointsPageState extends State<PointsPage> {
  PointsSummary? _summary;
  final _entries = <PointsEntry>[];
  String? _next;
  String? _error;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
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
                  const SizedBox(height: 4),
                  Text(
                    summary.expiring > 0 && summary.expiringAt != null
                        ? '30 天内有 ${summary.expiring} 分到期，最早 ${formatCampusRelative(summary.expiringAt!.toIso8601String())}'
                        : '每笔积分满 12 个月过期',
                    style: secondary,
                  ),
                ])),
                const SizedBox(height: 24),
                Text('明细', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                if (_entries.isEmpty) Text('还没有积分。参加挑战过关就能拿到。', style: secondary),
                for (final entry in _entries)
                  Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(entry.note.isNotEmpty ? entry.note : _kindLabel(entry.kind), style: Theme.of(context).textTheme.bodyLarge),
                      Text('${_kindLabel(entry.kind)} · ${formatCampusRelative(entry.at.toIso8601String())}', style: secondary),
                    ])),
                    const SizedBox(width: 12),
                    Text(entry.amount > 0 ? '+${entry.amount}' : '${entry.amount}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: entry.amount > 0 ? palette.onSurface : palette.onSurfaceVariant)),
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
