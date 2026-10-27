import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// 按 Text 实际排版的口径量文字：合并 DefaultTextStyle（主题给正文带了字距）、系统「粗体文本」时同样加粗（Text 自己会加粗），
// 带上字号缩放、语言与方向。少了任何一项，量出来就比画出来的窄，按它定宽的格子会把末字裁掉（10-27 iPhone 系统字体下「09:40」缺半个 0）。
// 凡按文字尺寸决定布局的都用它，不自己 new TextPainter；用完调用方 dispose。textScaler 给了就按它量（界面页算别的字号下排不排得开），默认是当前字号。
TextPainter campusTextPainter(BuildContext context, String text, {TextStyle? style, int? maxLines, double maxWidth = double.infinity, TextScaler? textScaler}) {
  var effective = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) effective = effective.merge(const TextStyle(fontWeight: FontWeight.bold));
  return TextPainter(
    text: TextSpan(text: text, style: effective),
    textDirection: Directionality.of(context),
    locale: Localizations.maybeLocaleOf(context),
    textScaler: textScaler ?? MediaQuery.textScalerOf(context),
    textHeightBehavior: DefaultTextStyle.of(context).textHeightBehavior,
    maxLines: maxLines,
  )..layout(maxWidth: maxWidth);
}

double campusTextWidth(BuildContext context, String text, {TextStyle? style, TextScaler? textScaler}) {
  final painter = campusTextPainter(context, text, style: style, maxLines: 1, textScaler: textScaler);
  final width = painter.width;
  painter.dispose();
  return width;
}

// 短句换行均衡（同 CSS text-wrap: balance）：一行放不下时，在不增加行数的前提下把各行排得尽量一样长，
// 末行不剩一两个字（「马克思主义基本原 / 理」排成「马克思主义 / 基本原理」）。只管四行以内的短句（课名、教室、提示），
// 更长的段落照常排。量的是子组件自己的排版，支持外层 IntrinsicHeight；居中对齐时收窄后的文字仍居中。
class BalancedText extends StatelessWidget {
  const BalancedText(this.text, {super.key, this.style, this.textAlign});
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) => _Balanced(centered: textAlign == TextAlign.center, child: Text(text, style: style, textAlign: textAlign));
}

class _Balanced extends SingleChildRenderObjectWidget {
  const _Balanced({required this.centered, required super.child});
  final bool centered;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBalanced(centered);

  @override
  void updateRenderObject(BuildContext context, _RenderBalanced renderObject) => renderObject.centered = centered;
}

class _RenderBalanced extends RenderShiftedBox {
  _RenderBalanced(this._centered) : super(null);
  bool _centered;
  set centered(bool value) {
    if (value == _centered) return;
    _centered = value;
    markNeedsLayout();
  }

  // 行数不变的最窄宽度；一行放得下或超过四行时就是给的最大宽度。
  double _balancedWidth(RenderBox child, double maxWidth) {
    if (!maxWidth.isFinite) return maxWidth;
    final height = child.getDryLayout(BoxConstraints(maxWidth: maxWidth)).height;
    final line = child.getDryLayout(const BoxConstraints()).height;
    if (line <= 0 || height < line * 1.5 || height > line * 4.5) return maxWidth;
    var low = maxWidth * line / height / 2, high = maxWidth;
    for (var step = 0; step < 10 && high - low > .5; step++) {
      final middle = (low + high) / 2;
      if (child.getDryLayout(BoxConstraints(maxWidth: middle)).height <= height + .5) {
        high = middle;
      } else {
        low = middle;
      }
    }
    return high.ceilToDouble();
  }

  BoxConstraints _childConstraints(RenderBox child, BoxConstraints constraints) {
    final width = math.min(constraints.maxWidth, _balancedWidth(child, constraints.maxWidth));
    return BoxConstraints(maxWidth: width, minHeight: constraints.minHeight, maxHeight: constraints.maxHeight);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(_childConstraints(child, constraints)));
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(_childConstraints(child, constraints), parentUsesSize: true);
    size = constraints.constrain(child.size);
    (child.parentData! as BoxParentData).offset = Offset(_centered ? (size.width - child.size.width) / 2 : 0, 0);
  }

  @override
  double computeMinIntrinsicHeight(double width) => child?.getMinIntrinsicHeight(width) ?? 0;
  @override
  double computeMaxIntrinsicHeight(double width) => child?.getMaxIntrinsicHeight(width) ?? 0;
  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0;
  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0;
}
