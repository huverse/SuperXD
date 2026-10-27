import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

// 内容层在浮动玻璃栏下的柔和滚动边缘：只渐隐内容本身，露出真实动态背景，不叠纯色遮罩。
// 遮罩把子树放进离屏层，子树内不能再有玻璃，否则玻璃取不到外层背景；高对比度时不渐隐。
class ScrollEdgeFade extends StatelessWidget {
  const ScrollEdgeFade({super.key, this.top = 0, required this.bottom, required this.child, this.keep = false, this.tail = 0});
  // 内容已滚过上缘时的淡出高度，0表示未滚动不淡出；调用方须保证遮罩层有无不随滚动切换。
  final double top;
  // 子树底部被玻璃栏覆盖的高度，0表示没有浮动栏。
  final double bottom;
  final Widget child;
  // 上下都不淡出时仍保留遮罩层：上缘随滚动出现时不切换图层、不重建子树。
  final bool keep;
  // 没有浮动栏时，下面还有内容的那段下缘自身淡出的高度（最多 24），滚到底为 0，不留一条硬切的线。
  final double tail;

  @override
  Widget build(BuildContext context) {
    if ((top <= 0 && bottom <= 0 && tail <= 0 && !keep) || MediaQuery.highContrastOf(context)) return child;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        final height = bounds.height;
        const solid = Colors.white;
        final colors = <Color>[];
        final stops = <double>[];
        final entered = (top / height).clamp(0.0, 1.0);
        if (top > 0) {
          colors.addAll([solid.withValues(alpha: 0), solid]);
          stops.addAll([0, entered]);
        } else {
          colors.add(solid);
          stops.add(0);
        }
        if (bottom > 0) {
          // 进入玻璃前开始淡出，玻璃上部仍透出内容，下缘前完全透明，避免残字和列表裁切线。
          final start = ((height - bottom - 16) / height).clamp(entered, 1.0);
          final under = ((height - bottom * .6) / height).clamp(start, 1.0);
          final clear = ((height - bottom * .2) / height).clamp(under, 1.0);
          colors.addAll([solid, solid.withValues(alpha: .55), solid.withValues(alpha: 0), solid.withValues(alpha: 0)]);
          stops.addAll([start, under, clear, 1]);
        } else if (tail > 0) {
          colors.addAll([solid, solid.withValues(alpha: 0)]);
          stops.addAll([((height - tail) / height).clamp(entered, 1.0), 1]);
        } else {
          colors.add(solid);
          stops.add(1);
        }
        return LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: colors, stops: stops).createShader(bounds);
      },
      // 完全透明段直接不画：遮罩边缘落在非整数像素时最后一行会漏出内容细线。
      child: ClipRect(clipper: _VisibleClip(bottom * .2), child: child),
    );
  }
}

class _VisibleClip extends CustomClipper<Rect> {
  const _VisibleClip(this.hidden);
  final double hidden;
  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, 0, size.width, size.height - hidden);
  @override
  bool shouldReclip(_VisibleClip oldClipper) => oldClipper.hidden != hidden;
}

// 页面滚动区的柔和边缘（鸿蒙标题栏渐变、iOS 滚动边缘的轻量做法）：透明顶栏下，内容滚过上缘时自身渐隐（最多24dp），
// 露出真实背景而不是被一条硬线截断；下缘有浮动底栏时按覆盖高度渐隐，没有时下面还有内容就同样自身渐隐（最多24dp，滚到底不淡），
// 不在滚动区下缘留一条硬切的线（10-27 课表学期视图底部被截成一条直线后加）。听子树里的纵向滚动（含横向翻页里的每页列表）。子树里同样不能放玻璃。
class CampusScrollFade extends StatefulWidget {
  const CampusScrollFade({super.key, this.bottom = 0, required this.child});
  final double bottom;
  final Widget child;
  @override
  State<CampusScrollFade> createState() => _CampusScrollFadeState();
}

class _CampusScrollFadeState extends State<CampusScrollFade> {
  double _top = 0;
  double _tail = 0;

  // 倒序列表（会话页最新在下）视觉上缘是列表的末端，看 extentAfter、下缘反过来；首次排版的尺寸通知也算，打开时上下已有内容就渐隐。
  bool _scrolled(ScrollMetrics metrics) {
    if (metrics.axis != Axis.vertical) return false;
    final reversed = metrics.axisDirection == AxisDirection.up;
    final top = (reversed ? metrics.extentAfter : metrics.extentBefore).clamp(0.0, 24.0);
    final tail = (reversed ? metrics.extentBefore : metrics.extentAfter).clamp(0.0, 24.0);
    if (top == _top && tail == _tail) return false;
    void apply() {
      if (!mounted) return;
      setState(() {
        _top = top;
        _tail = tail;
      });
    }
    // 滚动位置可能在排版当中被校正（字号过渡时的滚动锚定、内容变矮被夹住），那时发来的通知不能当场重建，等这一帧画完再改。
    SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks ? SchedulerBinding.instance.addPostFrameCallback((_) => apply()) : apply();
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (notification) => _scrolled(notification.metrics),
    child: NotificationListener<ScrollNotification>(
      onNotification: (notification) => _scrolled(notification.metrics),
      child: ScrollEdgeFade(top: _top, bottom: widget.bottom, tail: _tail, keep: true, child: widget.child),
    ),
  );
}
