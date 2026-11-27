import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_motion.dart';
import 'package:superxd/theme/campus_typesetting.dart';

// [人工决策-2026-11-27 13:51:18] 单行放不下时横向滚动（跑马灯；用户 11-27 选定，没选「放不下时变两行」「课名与教室轮流显示」；
// 同 Apple Music 迷你播放条、安卓 TextView 的 marquee；今天页此刻条的「课名 · 教室」用）：
// 先停 _pause，再按 _velocity 匀速往左滚过「原文 + 间隔」，首尾接上回到开头再停；停着时只渐隐尾端，滚动中首端随滚出渐显、到位前渐隐，不突变。
// 最多滚 rounds 遍（默认 3，同安卓 TextView 跑马灯的默认遍数）就停在开头：这个上限是我按 11-09 那条定的（见 campus_motion.dart 的 campusDecorTick：
// 今天页常开着，滚动按屏幕刷新率出帧、每帧都要重新合成底栏玻璃，一直滚等于今天页一直满帧）。内容或宽度变了、重新能动（回到前台、回到这一页、
// 盖在上面的页面或弹窗关掉）时从头算。
// 放得下、或装饰动效不能动（CampusMotion.allowed：减少动画、后台、省电、不在最前）时显示 child（没给就单行省略）。宽度经 campusTextWidth 量（同 Text 的口径）。
// 找过的库：marquee 2.3.0 放得下也一直滚、两遍之间的停顿是取消不了的 Future.delayed；text_scroll 0.3.0 开着时一直跑 50ms 的轮询计时器、
// 两端渐隐固定（停在开头时首字也被淡掉）；两个都不跟 CampusMotion 的暂停条件，所以自己写。
class CampusMarquee extends StatefulWidget {
  const CampusMarquee(this.text, {super.key, this.style, this.child, this.rounds = 3});
  final String text;
  final TextStyle? style;
  final Widget? child;
  final int rounds;

  @override
  State<CampusMarquee> createState() => _CampusMarqueeState();
}

class _CampusMarqueeState extends State<CampusMarquee> with SingleTickerProviderStateMixin {
  static const _pause = Duration(seconds: 3);
  // 每秒滚多少逻辑像素。
  static const _velocity = 32.0;
  static const _gap = 40.0;
  static const _fade = 16.0;
  late final _scroll = AnimationController(vsync: this)..addListener(_follow)..addStatusListener(_settle);
  final _position = ScrollController();
  Timer? _wait;
  // 一遍滚过的距离（原文宽加间隔）；为空是没在滚。
  double? _distance;
  var _round = 0;

  void _follow() {
    final distance = _distance;
    if (distance != null && _position.hasClients) _position.jumpTo(_scroll.value * distance);
  }

  // 滚完一遍：回到开头（同一画面，看不出跳），没到遍数就再停一会儿接着滚。
  void _settle(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _scroll.value = 0;
    _round++;
    if (_round < widget.rounds) _wait = Timer(_pause, () => _scroll.forward(from: 0));
  }

  // 布局之后按这一帧量出的结果开始或停下（构建与布局当中不动动画）。
  void _apply(double? distance) {
    if (distance == _distance) return;
    _wait?.cancel();
    _scroll.stop();
    _distance = distance;
    _round = 0;
    _scroll.value = 0;
    if (distance == null || widget.rounds <= 0) return;
    _scroll.duration = Duration(milliseconds: (distance / _velocity * 1000).round());
    _wait = Timer(_pause, () => _scroll.forward(from: 0));
  }

  @override
  void didUpdateWidget(CampusMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换了内容（上课、下课、换下一节）从头算：先作废，布局后按新内容重新开始。
    if (oldWidget.text != widget.text) _apply(null);
  }

  @override
  void dispose() {
    _wait?.cancel();
    _scroll.dispose();
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = CampusMotion.allowed(context);
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    return LayoutBuilder(builder: (context, constraints) {
      final width = campusTextWidth(context, widget.text, style: style);
      final distance = allowed && width > constraints.maxWidth ? width + _gap : null;
      if (distance != _distance) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _apply(distance);
        });
      }
      if (distance == null) return widget.child ?? Text(widget.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      Widget copy() => Text(widget.text, maxLines: 1, softWrap: false, style: style);
      return RepaintBoundary(child: AnimatedBuilder(
        animation: _scroll,
        builder: (context, child) {
          // 首端渐隐的强弱：停在开头时没有，滚出 _fade 后满，快回到开头时再收掉（回到开头那一帧和起点一样）。
          final offset = _scroll.value * distance;
          final lead = math.min(offset, distance - offset).clamp(0.0, _fade) / _fade;
          return ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) => LinearGradient(
              colors: [Colors.black.withValues(alpha: 1 - lead), Colors.black, Colors.black, Colors.transparent],
              stops: [0, _fade / rect.width, 1 - _fade / rect.width, 1],
            ).createShader(rect),
            child: child,
          );
        },
        child: SingleChildScrollView(
          controller: _position,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: Row(children: [copy(), const SizedBox(width: _gap), copy()]),
        ),
      ));
    });
  }
}
