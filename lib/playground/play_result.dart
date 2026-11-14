import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:superxd/domain/challenge.dart';
import 'package:superxd/playground/challenge/play_challenge.dart';
import 'package:superxd/playground/play_frame.dart';
import 'package:superxd/playground/puzzle_rules.dart';
import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_transitions.dart';
import 'package:superxd/theme/dot_separated_text.dart';

// 完成后的结果弹层：用时、步数、新纪录或这一档的最好成绩；「再来一局」是主操作，有下一档时另给「换到下一档」（不用「挑战」二字，那是挑战模式）。
// 返回选了什么：再来一局（同档换题）、下一档、关掉（看看解开的棋盘）。
enum PlayResultChoice { again, harder, close }

Future<PlayResultChoice> showPlayResult(BuildContext context, {required PlaySession<Object?, Object?> session, required bool newBest, String? detail}) async {
  if (session.challenge != null) return _showLevelResult(context, session, detail);
  unawaited(HapticFeedback.successNotification());
  final best = session.store.best(session.game.id, session.tier);
  final harder = session.tier.index + 1 < PuzzleTier.values.length ? PuzzleTier.values[session.tier.index + 1] : null;
  // 拼手速的游戏用时写到 0.1 秒（大字与「最好」同一种写法），其余写分:秒。
  String duration(Duration elapsed) => playDuration(elapsed, tenths: session.game.timeInTenths);
  final choice = await showCampusSheet<PlayResultChoice>(context: context, builder: (context) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    return CampusSheetPanel(child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          CampusIcon(newBest ? CampusIcons.trophy : CampusIcons.success, size: 28, color: palette.accentText),
          const SizedBox(width: 12),
          Expanded(child: Text(newBest ? '新纪录' : '解开了', style: Theme.of(context).textTheme.titleLarge)),
        ]),
        const SizedBox(height: 16),
        Text(duration(session.elapsed), style: TextStyle(fontSize: 40, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 4),
        DotSeparatedText([session.tier.label, ?detail, if (!newBest && best != null) '最好 ${duration(Duration(milliseconds: best.millis))}'].join(' · '), style: secondary),
        const SizedBox(height: 20),
        FilledButton.icon(style: campusProminent, onPressed: () => Navigator.pop(context, PlayResultChoice.again), icon: const CampusIcon(CampusIcons.shuffle), label: const Text('再来一局')),
        if (harder != null) ...[
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: () => Navigator.pop(context, PlayResultChoice.harder), icon: const CampusIcon(CampusIcons.next), label: Text('换到${harder.label}')),
        ],
      ]),
    ));
  });
  return choice ?? PlayResultChoice.close;
}

// 挑战里的一关解开后：先在弹层里等服务器核对（原地写「正在核对」），过了写明拿到的钥匙交给哪一关；连不上可以原样再交；
// 服务器说不对或这一局已经结束就照实写。关掉弹层即回到挑战那一页（这一关已经交完，不留在棋盘上）；等着时划掉弹层也一样，结果由挑战那一页接着收。
Future<PlayResultChoice> _showLevelResult(BuildContext context, PlaySession<Object?, Object?> session, String? detail) async {
  final challenge = session.challenge!;
  await showCampusSheet<void>(context: context, builder: (context) => StatefulBuilder(builder: (context, setState) {
    final palette = CampusPalette.of(context);
    final secondary = TextStyle(fontSize: 14, color: palette.onSurfaceVariant);
    return CampusSheetPanel(child: Padding(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder<PlayVerdict>(future: session.submission, builder: (context, snapshot) {
        final verdict = snapshot.data;
        final failed = snapshot.hasError;
        final waiting = !failed && verdict == null;
        if (verdict?.correct ?? false) unawaited(HapticFeedback.successNotification());
        final (icon, title, line) = switch ((waiting, failed, verdict)) {
          (true, _, _) => (CampusIcons.sync, '正在交给服务器核对', '用时 ${playDuration(session.elapsed)}'),
          (_, true, _) => (CampusIcons.warning, '没交上', snapshot.error is ChallengeException ? (snapshot.error as ChallengeException).message : '连不上服务器'),
          (_, _, PlayVerdict(correct: true, :final key)) => (
            CampusIcons.success,
            '${challenge.name}过了',
            key == null || challenge.target == null ? '用时 ${playDuration(session.elapsed)}' : '拿到钥匙 $key，交给${challenge.target}',
          ),
          (_, _, PlayVerdict(over: true)) => (CampusIcons.timer, '这一局已经结束', '这一关没算上'),
          _ => (CampusIcons.warning, '服务器核对没通过', '可以回去重做这一关'),
        };
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (waiting) const SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)) else CampusIcon(icon, size: 28, color: palette.accentText),
            const SizedBox(width: 12),
            Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
          ]),
          const SizedBox(height: 8),
          DotSeparatedText([line, ?detail].join(' · '), style: secondary),
          const SizedBox(height: 20),
          if (failed) ...[
            FilledButton.icon(style: campusProminent, onPressed: () => setState(session.resubmit), icon: const CampusIcon(CampusIcons.sync), label: const Text('重新交')),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            style: failed ? null : campusProminent,
            onPressed: waiting ? null : () => Navigator.pop(context),
            icon: const CampusIcon(CampusIcons.back),
            label: const Text('回到挑战'),
          ),
        ]);
      }),
    ));
  }));
  if (context.mounted) unawaited(Navigator.maybePop(context));
  return PlayResultChoice.close;
}
