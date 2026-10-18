import 'package:flutter/material.dart';

// 数字滚动（同 iOS 实时活动、灵动岛的数字过渡）：文字变了时只有变了的那几位滚动，新字从下方滚入、旧字向上滚出并淡去；
// 倒数（countsDown）时方向相反，像往回拨。没变的位不动，位按右对齐配对，位数变了（10:00 → 9:59）多出的那位直接淡出。
// 每位一个 AnimatedSwitcher，没用 animated_flip_counter：它只认整数加前后缀、会滚过中间每个数字，排不了「4:59」这种带分隔的串。
// 减少动画时直接换字。读屏请由调用方给整句标签。
class CampusRollingText extends StatelessWidget {
  const CampusRollingText(this.text, {super.key, this.style, this.countsDown = false});
  final String text;
  final TextStyle? style;
  final bool countsDown;

  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.disableAnimationsOf(context);
    final glyphs = text.characters.toList();
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
      for (final (index, glyph) in glyphs.indexed)
        instant
            ? Text(glyph, style: style)
            : AnimatedSwitcher(
                key: ValueKey(glyphs.length - index),
                duration: const Duration(milliseconds: 360),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                // 旧字与新字叠在同一格里、按基线对齐，格宽取两者较宽的那个。
                layoutBuilder: (current, previous) => Stack(alignment: Alignment.bottomCenter, children: [...previous, ?current]),
                transitionBuilder: (child, animation) {
                  // 新字从起点滑到位；旧字的动画倒放，从原位滑向反方向。
                  final entering = child.key == ValueKey(glyph);
                  final offset = (entering ? .6 : -.6) * (countsDown ? -1 : 1);
                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: animation.drive(Tween(begin: Offset(0, offset), end: Offset.zero)), child: child),
                  );
                },
                child: Text(glyph, key: ValueKey(glyph), style: style),
              ),
    ]);
  }
}
