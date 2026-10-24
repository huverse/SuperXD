import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:superxd/domain/festival.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'reward_kit.dart';

// 奖品卡容器（所有开启动效共用）：整体一块，不分卡头卡身。下面是主题画的卡面（默认是流光卡：近黑玻璃、卡头流动的渐变、边上的发丝流光与外面一圈光，
// 可以画到卡外），上面是内容层。卡形由 body 驱动从中间一团光长出来，内容由 content 浮现。
// 内容在任何卡面上都要清楚：口令落在半透明的白框里，二维码在白底上（扫码要白底黑码）。

// 颜色常量：二维码的纸。
const _qrPaper = Color(0xFFFFFFFF);
// 按钮按下时压暗、标题的投影。
const _shadow = Color(0xFF000000);
// 节日名用宋体（同钞票与证书上刻的字），字体随应用打包。
const rewardSerif = 'Noto Serif SC';

class RewardContainer extends StatelessWidget {
  const RewardContainer({super.key, required this.theme, required this.palette, required this.clock, required this.tilt, required this.still, required this.body, required this.content, required this.child});
  final RewardTheme theme;
  final RewardPalette palette;
  final ValueListenable<double> clock;
  final ValueListenable<Offset> tilt;
  final bool still;
  // 卡形长出来的进度与内容层显出来的进度（0–1）。
  final double body;
  final double content;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final appear = Curves.easeOut.transform(content.clamp(0.0, 1.0));
    return CustomPaint(
      painter: _Surface(theme: theme, palette: palette, clock: clock, tilt: tilt, still: still, reveal: body.clamp(0.0, 1.0)),
      child: Opacity(opacity: appear, child: Transform.translate(offset: Offset(0, 12 * (1 - appear)), child: child)),
    );
  }
}

// 卡面（不裁切，外面那圈光可以画到卡外）。
class _Surface extends CustomPainter {
  _Surface({required this.theme, required this.palette, required this.clock, required this.tilt, required this.still, required this.reveal}) : super(repaint: still ? null : Listenable.merge([clock, tilt]));
  final RewardTheme theme;
  final RewardPalette palette;
  final ValueListenable<double> clock;
  final ValueListenable<Offset> tilt;
  final bool still;
  final double reveal;

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0) return;
    theme.paintCard(canvas, Offset.zero & size, palette, time: still ? 0.0 : clock.value, reveal: reveal, tilt: still ? Offset.zero : tilt.value, still: still);
  }

  @override
  bool shouldRepaint(_Surface oldDelegate) => oldDelegate.theme != theme || oldDelegate.palette != palette || oldDelegate.reveal != reveal || oldDelegate.still != still;
}

// 奖品卡的内容（透明，底由容器与主题画）：节日名与奖品类型、口令（大字、可选中复制）或二维码、附言、操作；
// 卡片至少是宽的 rewardCardAspect 倍高，多出来的高度均分在三组之间。
class RewardCard extends StatelessWidget {
  const RewardCard({super.key, required this.prize, required this.title, required this.palette, required this.qrKey, required this.onPrimary, required this.onSave, required this.onClose, required this.minHeight});
  final FestivalPrize prize;
  final String title;
  final RewardPalette palette;
  final GlobalKey qrKey;
  final VoidCallback onPrimary;
  final VoidCallback? onSave;
  final VoidCallback onClose;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final password = prize.kind == FestivalPrizeKind.password;
    return ConstrainedBox(constraints: BoxConstraints(minHeight: minHeight), child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 30, 24, 12),
      child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Column(children: [
          // 卡头的小字落在最亮的渐变上，比别处的次要字亮一档（同第一轮）。
          Text(password ? '支付宝口令红包' : '支付宝红包', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, letterSpacing: 3, color: palette.ink.withValues(alpha: .8))),
          const SizedBox(height: 10),
          Text(title, textAlign: TextAlign.center, style: TextStyle(fontFamily: rewardSerif, fontSize: 30, height: 1.25, fontWeight: FontWeight.w600, letterSpacing: 6, color: palette.ink, shadows: [Shadow(color: _shadow.withValues(alpha: .45), blurRadius: 14)])),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (password)
              // 口令落在一块半透明的白框里（同第一轮），字带一点很淡的光晕。
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 18),
                decoration: BoxDecoration(color: palette.slot, borderRadius: BorderRadius.circular(18), border: Border.all(color: palette.ink.withValues(alpha: .16))),
                child: SelectableText(prize.content, textAlign: TextAlign.center, style: TextStyle(fontSize: 32, fontWeight: FontWeight.w600, letterSpacing: 6, height: 1.2, color: palette.ink, fontFeatures: const [ui.FontFeature.tabularFigures()], shadows: [Shadow(color: palette.light.withValues(alpha: .35), blurRadius: 14)])),
              )
            else
              // 二维码在白底上（扫码要白底黑码，同第一轮）。
              Center(child: RepaintBoundary(
                key: qrKey,
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: _qrPaper, borderRadius: BorderRadius.circular(18)),
                  child: SizedBox.square(dimension: 188, child: PrettyQrView.data(data: prize.content, errorCorrectLevel: QrErrorCorrectLevel.M)),
                ),
              )),
            if (prize.note.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(prize.note, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: palette.muted)),
            ],
          ]),
        ),
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          RewardButton(icon: password ? CampusIcons.copy : CampusIcons.open, label: password ? '复制口令，去支付宝' : '在支付宝里打开', fill: palette.button, ink: palette.buttonInk, onPressed: onPrimary),
          const SizedBox(height: 4),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (onSave case final onSave?) RewardQuietButton(icon: CampusIcons.download, label: '保存二维码', color: palette.muted, onPressed: onSave),
            RewardQuietButton(icon: CampusIcons.check, label: '收下了', color: palette.muted, onPressed: onClose),
          ]),
        ]),
      ]),
    ));
  }
}

// 卡上的主按钮：实心胶囊，按下整块变暗（全应用的按压反馈，不用水波）。
class RewardButton extends StatefulWidget {
  const RewardButton({super.key, required this.icon, required this.label, required this.fill, required this.ink, required this.onPressed});
  final IconData icon;
  final String label;
  final Color fill;
  final Color ink;
  final VoidCallback onPressed;

  @override
  State<RewardButton> createState() => _RewardButtonState();
}

class _RewardButtonState extends State<RewardButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      // 子树的语义被排除了（手势的点按动作也一起没了），读屏的点按要挂在这一层。
      onTap: widget.onPressed,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          constraints: const BoxConstraints(minHeight: 52),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(26), color: widget.fill),
          foregroundDecoration: BoxDecoration(borderRadius: BorderRadius.circular(26), color: _shadow.withValues(alpha: _down ? .18 : 0)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            CampusIcon(widget.icon, size: 20, color: widget.ink),
            const SizedBox(width: 8),
            Flexible(child: Text(widget.label, textAlign: TextAlign.center, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: widget.ink))),
          ]),
        ),
      ),
    );
  }
}

// 卡上的次要按钮：只有图标与字，按下变淡。
class RewardQuietButton extends StatefulWidget {
  const RewardQuietButton({super.key, required this.icon, required this.label, required this.color, required this.onPressed});
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onPressed;

  @override
  State<RewardQuietButton> createState() => _RewardQuietButtonState();
}

class _RewardQuietButtonState extends State<RewardQuietButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 90),
              opacity: _down ? .55 : 1,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                CampusIcon(widget.icon, size: 18, color: widget.color),
                const SizedBox(width: 6),
                Text(widget.label, style: TextStyle(fontSize: 15, color: widget.color)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
