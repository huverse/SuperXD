import 'package:flutter/material.dart';

import 'reward_kit.dart';

// 默认主题：第一轮流光方向的卡（用户认可的奖品卡样子）。一块近黑的玻璃卡，卡头铺着缓慢流动的网格渐变、往下暗进卡身，
// 边上一道发丝流光与外面一圈光（材质在 shaders/reward_aurora.frag）。颜色全从应用配色的激活色取：渐变与流光是种子色与它两侧相邻的色相，
// 每套配色各有一张。相对第一轮的卡面只改了两处：第四个颜色从对面的色相（转 125°，会出粉橙，偏彩虹）换成同一侧更远一点的相邻色相（转 75°）；边缘光与外面那圈光收了约三成。

// 配色（OKLCH 的明度、彩度，色相跟种子）：房间、四个流光色、玻璃底、开启动效的主光、星尘、字、口令框、主按钮。
RewardPalette _palette(RewardTone tone) => RewardPalette(
  night: tone.pick(.13, .035),
  flows: [tone.pick(.7, .19), tone.pick(.68, .2, turn: 55), tone.pick(.74, .17, turn: -60), tone.pick(.7, .19, turn: 75)],
  body: tone.pick(.14, .024),
  light: tone.pick(.7, .14),
  dust: [tone.pick(.97, .025), tone.pick(.86, .1), const Color(0xFFFFFFFF)],
  ink: const Color(0xFFFFFFFF),
  muted: const Color(0xB3FFFFFF),
  slot: const Color(0x12FFFFFF),
  button: const Color(0xFFFFFFFF),
  buttonInk: tone.pick(.24, .05),
);

class RewardGlowTheme extends RewardTheme {
  const RewardGlowTheme();

  @override
  RewardPalette palette(Color seed) => _palette(RewardTone(seed));

  @override
  void paintCard(Canvas canvas, Rect card, RewardPalette palette, {required double time, required double reveal, required Offset tilt, required bool still}) {
    final shader = RewardSurface.shader(RewardGlowTheme, card: card, time: time, tilt: tilt, palette: palette, morph: reveal);
    if (shader != null) {
      canvas.drawRect(card.inflate(48), Paint()..shader = shader);
      return;
    }
    // 退路（着色器没加载好）：深色圆角底加一圈渐变的细边。
    final shape = RRect.fromRectAndRadius(card, const Radius.circular(rewardCardRadius));
    canvas.drawRRect(shape, Paint()..color = palette.body.withValues(alpha: reveal));
    canvas.drawRRect(shape, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = SweepGradient(colors: [...palette.flows, palette.flows.first]).createShader(card));
  }
}
