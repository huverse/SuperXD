import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:superxd/theme/campus_icons.dart';

// 方向操作的游戏（冰面滑行、推箱子）共用的两样：棋盘上的滑动识别器与棋盘下方的十字方向键。方向编码统一 0 上、1 右、2 下、3 左
// （同各游戏规则里的答案编码）。另有格子太小时双指缩放的共用算法 PlayPinch。

const playUp = 0, playRight = 1, playDown = 2, playLeft = 3;

// 棋盘上的滑动：手指一落下就赢下手势竞争（iOS 的页面任意位置右滑返回也在抢横向移动，见 campus_transitions.dart 的 _IosBackSwipe），
// 走过触摸门槛后按横竖哪边走得多认一个方向，这一笔里只认一次；只跟第一根手指。
class PlaySwipeRecognizer extends OneSequenceGestureRecognizer {
  void Function(int direction)? onSwipe;
  int? _pointer;
  Offset _origin = Offset.zero;
  bool _fired = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    if (_pointer != null) return;
    super.addAllowedPointer(event);
    _pointer = event.pointer;
    _origin = event.position;
    _fired = false;
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    if (event is PointerMoveEvent && !_fired) {
      final delta = event.position - _origin;
      if (delta.distance < kTouchSlop) return;
      _fired = true;
      final direction = delta.dx.abs() > delta.dy.abs() ? (delta.dx > 0 ? playRight : playLeft) : (delta.dy > 0 ? playDown : playUp);
      invokeCallback<void>('onSwipe', () => onSwipe?.call(direction));
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) => _pointer = null;

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) => stopTrackingPointer(pointer);

  @override
  String get debugDescription => 'playground swipe';
}

// 把棋盘包上滑动识别：滑一下调 onSwipe（为空时不认）。
Widget playSwipeArea({required void Function(int direction)? onSwipe, required Widget child}) => RawGestureDetector(
  behavior: HitTestBehavior.opaque,
  excludeFromSemantics: true,
  gestures: {
    PlaySwipeRecognizer: GestureRecognizerFactoryWithHandlers<PlaySwipeRecognizer>(PlaySwipeRecognizer.new, (recognizer) => recognizer.onSwipe = onSwipe),
  },
  child: child,
);

// 棋盘下方的方向键：上下在中间一列、左右在两边，排成紧凑的十字；内容区的色调圆钮，每个都有读屏标签与长按提示（「向上」加 verb，如「滑」「走」）。
class PlayDirectionPad extends StatelessWidget {
  const PlayDirectionPad({super.key, required this.verb, required this.onPush});
  final String verb;
  final void Function(int direction)? onPush;

  static const _size = 52.0, _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    Widget key(int direction, String label, IconData icon, double left, double top) => Positioned(
      left: left,
      top: top,
      child: Tooltip(
        message: label,
        excludeFromSemantics: true,
        child: FilledButton(
          onPressed: onPush == null ? null : () => onPush!(direction),
          style: FilledButton.styleFrom(shape: const CircleBorder(), fixedSize: const Size.square(_size), minimumSize: const Size.square(_size), padding: EdgeInsets.zero),
          child: Semantics(label: label, excludeSemantics: true, child: CampusIcon(icon, size: 26)),
        ),
      ),
    );
    const middle = (_size + _gap) / 2;
    return SizedBox(width: _size * 3 + _gap * 2, height: _size * 2 + _gap, child: Stack(children: [
      key(playUp, '向上$verb', CampusIcons.collapse, _size + _gap, 0),
      key(playLeft, '向左$verb', CampusIcons.previous, 0, middle),
      key(playRight, '向右$verb', CampusIcons.next, (_size + _gap) * 2, middle),
      key(playDown, '向下$verb', CampusIcons.expand, _size + _gap, _size + _gap),
    ]));
  }
}

// 双指缩放的共用算法（数织、八皇后、扫雷、数回）：第二根手指落下时 start 记下两指的距离、中点与当时的缩放和平移；
// 之后 update 按两指距离之比缩放（1 到 maxZoom），缩放前手指中点下的那一点缩放后仍在中点下，返回新的缩放与还没夹到边界里的平移
// （origin 是可平移的那块内容在触摸区里的原点，数织的格子区在提示栏右下）。什么时候算在缩放、手指怎么记、平移怎么夹由各游戏自己管。
class PlayPinch {
  double _distance = 1, _zoom = 1;
  Offset _focal = Offset.zero, _pan = Offset.zero;

  void start(Iterable<Offset> fingers, {required double zoom, required Offset pan}) {
    final [first, second, ...] = fingers.toList();
    _distance = math.max(1, (first - second).distance);
    _focal = (first + second) / 2;
    _zoom = zoom;
    _pan = pan;
  }

  (double, Offset) update(Iterable<Offset> fingers, {required double maxZoom, Offset origin = Offset.zero}) {
    final [first, second, ...] = fingers.take(2).toList();
    final zoom = (_zoom * (first - second).distance / _distance).clamp(1.0, maxZoom);
    final anchor = (_focal - origin - _pan) / _zoom;
    return (zoom, (first + second) / 2 - origin - anchor * zoom);
  }
}
