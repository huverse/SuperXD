import 'package:flutter/widgets.dart';

// “甲 · 乙 · 丙”式的说明行：按“ · ”分项换行（Wrap），学期名再在“学年”后切开，窄处与大字号下不把“老师”“A201”“期”拆成孤字；读屏读整句。
class DotSeparatedText extends StatelessWidget {
  const DotSeparatedText(this.text, {super.key, required this.style});
  final String text;
  final TextStyle style;

  static final _term = RegExp(r'^(.+学年)(第.+学期)$');

  @override
  Widget build(BuildContext context) {
    // 分隔的“ · ”挂在前一项末尾，换行后每行左缘对齐；Wrap 不另加间距，同一行里学年与学期紧挨着。
    final parts = text.split(' · ');
    final items = <String>[];
    for (final (index, part) in parts.indexed) {
      final tail = index == parts.length - 1 ? '' : ' · ';
      final match = _term.firstMatch(part);
      if (match == null) {
        items.add('$part$tail');
      } else {
        items..add(match.group(1)!)..add('${match.group(2)}$tail');
      }
    }
    return Semantics(label: text, excludeSemantics: true, child: Wrap(children: [for (final item in items) Text(item, style: style)]));
  }
}
