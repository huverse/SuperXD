import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_glass_button.dart';
import 'package:superxd/theme/campus_icons.dart';
import 'package:superxd/theme/campus_palette.dart';
import 'package:superxd/theme/campus_typesetting.dart';
import 'package:superxd/theme/glass_panel.dart';

// 下拉触发的顶栏按钮（同 Claude 侧栏右上角的搜索）：平时是顶栏玻璃圆钮；往下拉时沿圆周描一圈激活色（pull 0–1，拉到位描满），
// 到位后铺满激活色、展开成带名字的胶囊（同强调按钮的白字），松手由调用方触发；点按照常触发。减少动画时不展开、不描圈，直接铺色。
// 激活色是画在玻璃上面的一层（不给玻璃套半透明的祖先，见 campus_glass_surface.dart）。
class CampusPullButton extends StatelessWidget {
  const CampusPullButton({super.key, required this.icon, required this.label, required this.pull, required this.onPressed, this.size = 44, this.caption});
  final IconData icon;
  // 读屏与提示框的名字。
  final String label;
  // 展开成胶囊时写的字（默认同 label）：名字跟着状态换了（搜索变关闭搜索）时，正在收回的胶囊里照旧写原来的字，不闪出新名字。
  final String? caption;
  final double pull;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = CampusPalette.of(context);
    final armed = pull >= 1;
    final reduce = MediaQuery.disableAnimationsOf(context);
    const labelStyle = TextStyle(fontSize: 16, fontWeight: FontWeight.w600);
    final caption = this.caption ?? label;
    final wide = size + campusTextWidth(context, caption, style: labelStyle) + 16;
    final duration = reduce ? Duration.zero : const Duration(milliseconds: 240);
    return CampusChrome(child: Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: armed && !reduce ? wide : size),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, width, _) {
          // 展开了多少（0 是圆钮、1 是整个胶囊），名字随它露出。
          final open = wide <= size ? 0.0 : ((width - size) / (wide - size)).clamp(0.0, 1.0);
          return FilledButton(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              shape: const StadiumBorder(),
              fixedSize: Size(width, size),
              minimumSize: Size(width, size),
              padding: EdgeInsets.zero,
              backgroundBuilder: (context, states, child) => CampusGlassButtonSurface(states: states, round: true, child: child!),
            ),
            child: Semantics(
              label: label,
              excludeSemantics: true,
              child: SizedBox.expand(child: CustomPaint(
                foregroundPainter: armed || pull <= 0 || reduce ? null : _PullRing(pull.clamp(0.0, 1.0), palette.accent),
                child: Stack(fit: StackFit.expand, children: [
                  AnimatedOpacity(
                    opacity: armed ? 1 : 0,
                    duration: duration,
                    child: DecoratedBox(decoration: ShapeDecoration(shape: const StadiumBorder(), color: palette.accent)),
                  ),
                  Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    TweenAnimationBuilder<Color?>(
                      tween: ColorTween(end: armed ? Colors.white : palette.onSurface),
                      duration: duration,
                      // 换图标（搜索变关闭）时原地转过去：新图标从小转大，旧的反着收走。
                      builder: (context, color, _) => AnimatedSwitcher(
                        duration: duration,
                        transitionBuilder: (child, animation) => RotationTransition(
                          turns: Tween(begin: -.25, end: 0.0).animate(animation),
                          child: ScaleTransition(scale: animation, child: child),
                        ),
                        child: CampusIcon(icon, key: ValueKey(icon), size: 20, color: color),
                      ),
                    ),
                    if (open > 0)
                      ClipRect(child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: open,
                        child: Padding(padding: const EdgeInsets.only(left: 6), child: Text(caption, maxLines: 1, softWrap: false, style: labelStyle.copyWith(color: Colors.white))),
                      )),
                  ])),
                ]),
              )),
            ),
          );
        },
      ),
    ));
  }
}

// 沿圆周描的进度：从正上方顺时针，圆头。
class _PullRing extends CustomPainter {
  const _PullRing(this.progress, this.color);
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.5;
    final rect = Offset.zero & size;
    canvas.drawArc(rect.deflate(stroke / 2), -math.pi / 2, 2 * math.pi * progress, false, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color);
  }

  @override
  bool shouldRepaint(_PullRing oldDelegate) => oldDelegate.progress != progress || oldDelegate.color != color;
}
