import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

// 排版体检：扫当前屏上所有可见文字，找被裁的字、孤字与单独成行的标点。
// 种类：clip-width（单行文字比格子宽被裁）、clip-lines（超出行数被截掉且没有省略号）、clip-height（比格子高）、
// parent-clip（被祖先的裁切框切掉一部分，滚动视口除外）、lone-punct（一行只有标点）、orphan（多字的句子里一行只剩一个汉字，括号整体换行除外）、
// truncate（省略号或渐隐，属有意截断，只报告不算错）。
class TextIssue {
  const TextIssue(this.kind, this.text, this.detail);
  final String kind;
  final String text;
  final String detail;
  @override
  String toString() => '$kind「${text.replaceAll('\n', '⏎')}」$detail';
}

final _han = RegExp(r'[㐀-鿿]');
final _letters = RegExp(r'[A-Za-z0-9㐀-鿿]');
final _punctuation = RegExp(r'[\s\p{P}·]', unicode: true);

bool _hidden(RenderObject object) {
  for (RenderObject? node = object; node != null; node = node.parent) {
    if (node is RenderOpacity && node.opacity == 0 || node is RenderAnimatedOpacity && node.opacity.value == 0) return true;
  }
  return false;
}

Rect? _clipOf(RenderBox paragraph) {
  Rect? clip;
  for (var node = paragraph.parent; node != null; node = node.parent) {
    if (node is RenderAbstractViewport || node is RenderSliver) break;
    if (node is RenderClipRect || node is RenderClipRRect || node is RenderClipPath) {
      final box = node as RenderBox;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      clip = clip == null ? rect : clip.intersect(rect);
    }
  }
  return clip;
}

// 照 RenderParagraph 的参数复排一份，按行取出文字。
List<String> _lines(RenderParagraph paragraph) {
  final painter = TextPainter(text: paragraph.text, textAlign: paragraph.textAlign, textDirection: paragraph.textDirection, textScaler: paragraph.textScaler, maxLines: paragraph.maxLines, locale: paragraph.locale, strutStyle: paragraph.strutStyle, textWidthBasis: paragraph.textWidthBasis, textHeightBehavior: paragraph.textHeightBehavior)
    ..layout(maxWidth: paragraph.softWrap ? paragraph.size.width : double.infinity);
  final plain = paragraph.text.toPlainText();
  final lines = [
    for (final line in painter.computeLineMetrics())
      switch (painter.getLineBoundary(painter.getPositionForOffset(Offset(line.left + .5, line.baseline - line.ascent / 2)))) {
        final range when range.isValid => plain.substring(range.start.clamp(0, plain.length), range.end.clamp(0, plain.length)),
        _ => '',
      },
  ];
  painter.dispose();
  return lines;
}

List<TextIssue> scanTexts(WidgetTester tester) {
  final issues = <TextIssue>[];
  final screen = Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  final seen = <RenderParagraph>{};
  for (final element in find.byType(RichText).evaluate()) {
    final paragraph = element.renderObject;
    if (paragraph is! RenderParagraph || !paragraph.attached || !paragraph.hasSize || !seen.add(paragraph)) continue;
    final plain = paragraph.text.toPlainText();
    if (plain.trim().isEmpty || _hidden(paragraph)) continue;
    final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
    if (!rect.overlaps(screen)) continue;
    final clipped = paragraph.overflow == TextOverflow.clip || paragraph.overflow == TextOverflow.visible;
    if (paragraph.textSize.width > paragraph.size.width + .5) {
      issues.add(TextIssue(clipped ? 'clip-width' : 'truncate', plain, '${paragraph.textSize.width.toStringAsFixed(1)} > ${paragraph.size.width.toStringAsFixed(1)}'));
    } else if (paragraph.didExceedMaxLines) {
      issues.add(TextIssue(clipped ? 'clip-lines' : 'truncate', plain, 'maxLines ${paragraph.maxLines}'));
    }
    if (paragraph.textSize.height > paragraph.size.height + .5) issues.add(TextIssue('clip-height', plain, '${paragraph.textSize.height.toStringAsFixed(1)} > ${paragraph.size.height.toStringAsFixed(1)}'));
    final clip = _clipOf(paragraph);
    if (clip != null && rect.overlaps(clip) && !(clip.inflate(.5).contains(rect.topLeft) && clip.inflate(.5).contains(rect.bottomRight))) issues.add(TextIssue('parent-clip', plain, '$rect / $clip'));
    if (paragraph.textSize.height < paragraph.textScaler.scale(14) * 1.8) continue;
    final lines = _lines(paragraph);
    final hanCount = _han.allMatches(plain).length;
    for (final (index, line) in lines.indexed) {
      final content = line.trim();
      if (content.isEmpty || lines.length < 2) continue;
      if (!_letters.hasMatch(content)) {
        issues.add(TextIssue('lone-punct', plain, '第${index + 1}行「$content」'));
      // 括号里的一个字单独一行（「大学英语 / （三）」）是整个括号放不下前一行，不算孤字。
      } else if (hanCount >= 3 && content.replaceAll(_punctuation, '').length == 1 && _han.hasMatch(content) && !content.startsWith('（') && !content.startsWith('(')) {
        issues.add(TextIssue('orphan', plain, '第${index + 1}行「$content」'));
      }
    }
  }
  return issues;
}
