import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:superxd/theme/campus_glass_controls.dart';

// 表单排版回归须用真实字体：描边框浮动标签凸出上边框的高度取决于字形行高，测试默认字体量不出来。
Future<void> loadCampusFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final maple = FontLoader('Maple Mono NF CN');
    for (final weight in ['regular', 'medium', 'semibold']) {
      maple.addFont(rootBundle.load('assets/fonts/maple_mono_nf_cn_$weight.ttf'));
    }
    await maple.load();
    final serif = FontLoader('Noto Serif SC')..addFont(rootBundle.load('assets/fonts/noto_serif_sc_variable.ttf'));
    await serif.load();
  });
}

// 浮动标签缩放绘制，取变换后的两个角而不是组件原始尺寸。
Rect paintedRect(WidgetTester tester, Finder finder) => Rect.fromPoints(tester.getTopLeft(finder), tester.getBottomRight(finder));

Finder _inside(Finder? scope, Finder finder) => scope == null ? finder : find.descendant(of: scope, matching: finder);

// 选择标签与候选按钮（课程表单的教师、地点候选是玻璃胶囊按钮）。
Finder _chips(Finder? scope) => _inside(scope, find.byWidgetPredicate((widget) => widget is CampusGlassChip || widget is FilledButton));

// 每个输入框的标签不得压到其他输入框、选择标签或候选按钮上；弹窗下层页面仍在树里，须用scope限定。
void expectFieldLabelsClear(WidgetTester tester, List<String> labels, String scene, {Finder? scope}) {
  final decorators = _inside(scope, find.byType(InputDecorator));
  final chips = _chips(scope);
  for (final label in labels) {
    final text = find.descendant(of: decorators, matching: find.text(label)).first;
    final labelRect = paintedRect(tester, text);
    final own = find.ancestor(of: text, matching: decorators).evaluate().toSet();
    for (final element in [...decorators.evaluate(), ...chips.evaluate()]) {
      if (own.contains(element)) continue;
      final box = element.renderObject! as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      expect(labelRect.overlaps(rect), isFalse, reason: '$scene：“$label”压到了上方控件 $rect');
    }
  }
}

// 选择标签与候选按钮内的文字必须完整落在其中，不被固定高度的容器裁切。
// 容器压低高度时文字框也会被一起夹小、仍落在标签内，所以还要比对文字实际排版高度与分到的高度。
void expectChipLabelsUnclipped(WidgetTester tester, String scene, {Finder? scope}) {
  for (final element in _chips(scope).evaluate()) {
    final chip = element.renderObject! as RenderBox;
    final chipRect = chip.localToGlobal(Offset.zero) & chip.size;
    final label = find.descendant(of: find.byElementPredicate((candidate) => candidate == element), matching: find.byType(Text)).first;
    final labelRect = paintedRect(tester, label);
    expect(chipRect.inflate(.5).contains(labelRect.topLeft) && chipRect.inflate(.5).contains(labelRect.bottomRight), isTrue, reason: '$scene：选择标签文字被裁切 $labelRect / $chipRect');
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(of: label, matching: find.byType(RichText)));
    expect(paragraph.textSize.height, lessThanOrEqualTo(paragraph.size.height + .5), reason: '$scene：选择标签文字高于可用高度 ${paragraph.textSize} / ${paragraph.size}');
  }
}
