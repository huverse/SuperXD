import 'dart:async';

import 'package:flutter/widgets.dart';

// 滚动锚定（同浏览器的 overflow-anchor、iOS 设置里改文字大小时手指下的控件不动）：hold 之后，
// 整页重新排版（字号过渡、换字体）让锚点上方的内容变高变矮时，在滚动区排版的同一帧里把滚动位置校正回去，
// 锚点停在原来的屏幕位置，不晚一帧、不抖；手指一按或代码滚到某处就放开。到顶或到底校正不动的部分照常移动。
// 过了 duration 不立刻放开，等到一次不用校正、内容尺寸也不再变的排版才放开（慢的设备上过渡的最后一帧会晚到，
// 调试包在模拟器上实测约 100ms 一帧，按时放开就漏掉了变化最大的那一帧）；最晚 settleLimit 一定放开。
class CampusAnchoredScrollController extends ScrollController {
  static const settleLimit = Duration(seconds: 2);
  GlobalKey? _anchor;
  double? _anchorTop;
  bool _expired = false;
  (double, double)? _extent;
  final _timers = <Timer>[];

  // 记下锚点此刻在滚动区里的纵向位置，至少 duration 之内保持它不动。
  void hold(GlobalKey anchor, Duration duration) {
    if (!hasClients) return;
    final top = (position as _AnchoredScrollPosition)._topOf(anchor);
    if (top == null) return;
    release();
    _anchor = anchor;
    _anchorTop = top;
    _timers
      ..add(Timer(duration, () => _expired = true))
      ..add(Timer(duration + settleLimit, release));
  }

  void release() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _anchor = null;
    _anchorTop = null;
    _expired = false;
    _extent = null;
  }

  @override
  ScrollPosition createScrollPosition(ScrollPhysics physics, ScrollContext context, ScrollPosition? oldPosition) => _AnchoredScrollPosition(
    controller: this,
    physics: physics,
    context: context,
    initialPixels: initialScrollOffset,
    keepScrollOffset: keepScrollOffset,
    oldPosition: oldPosition,
    debugLabel: debugLabel,
  );

  @override
  void dispose() {
    release();
    super.dispose();
  }
}

class _AnchoredScrollPosition extends ScrollPositionWithSingleContext {
  _AnchoredScrollPosition({required this.controller, required super.physics, required super.context, super.initialPixels, super.keepScrollOffset, super.oldPosition, super.debugLabel});
  final CampusAnchoredScrollController controller;

  // 锚点顶边在滚动区里的纵向位置；锚点不在树上或还没排版时为空。
  double? _topOf(GlobalKey anchor) {
    final box = anchor.currentContext?.findRenderObject();
    final viewport = context.notificationContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize || viewport == null) return null;
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  // 滚动区排完子项、报内容尺寸时校正：锚点偏了多少就把滚动位置挪多少（夹在新的可滚范围内），让滚动区按新位置重排一次（返回 false）；
  // 先校正再交给父类：父类看到旧位置超出变矮后的范围会起一段回弹，回弹会和校正抢位置。
  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final anchor = controller._anchor, target = controller._anchorTop;
    final top = anchor == null ? null : _topOf(anchor);
    if (top != null && target != null) {
      final corrected = (pixels + top - target).clamp(minScrollExtent, maxScrollExtent);
      if ((corrected - pixels).abs() >= .5) {
        correctPixels(corrected);
        return false;
      }
      // 过了最短时长、这次不用校正且内容尺寸和上一次一样：排版稳下来了，放开。
      final extent = (minScrollExtent, maxScrollExtent);
      if (controller._expired && controller._extent == extent) controller.release();
      controller._extent = extent;
    }
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }

  // 手指按住、拖动或代码发起的滚动（滚到某处）一开始就放开锚定，不和它们抢位置；空闲与回弹不算。
  @override
  void beginActivity(ScrollActivity? newActivity) {
    if (newActivity is HoldScrollActivity || newActivity is DragScrollActivity || newActivity is DrivenScrollActivity) controller.release();
    super.beginActivity(newActivity);
  }
}
