import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  unawaited(HapticFeedback.successNotification());
  final best = session.store.best(session.game.id, session.tier);
  final harder = session.tier.index + 1 < PuzzleTier.values.length ? PuzzleTier.values[session.tier.index + 1] : null;
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
        Text(playDuration(session.elapsed), style: TextStyle(fontSize: 40, fontWeight: FontWeight.w600, height: 1.15, color: palette.onSurface, fontFeatures: const [FontFeature.tabularFigures()])),
        const SizedBox(height: 4),
        DotSeparatedText([session.tier.label, ?detail, if (!newBest && best != null) '最好 ${playDuration(Duration(milliseconds: best.millis))}'].join(' · '), style: secondary),
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
