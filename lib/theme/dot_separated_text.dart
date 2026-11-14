import 'package:flutter/widgets.dart';

import 'package:superxd/theme/campus_typesetting.dart';

// “甲 · 乙 · 丙”式的说明行：按“ · ”分项换行（Wrap），学期名再在“学年”后切开，窄处与大字号下不把“老师”“A201”“期”拆成孤字；读屏读整句。
// separator 给“，”时按句换行，逗号挂在前一句末尾（挑战的预告与钥匙行：「第 ? / 列」曾被拆到两行）。
// 一项本身比一行长时均衡折行并占满这一行（BalancedText），不在末尾留孤字（11-14「第 1 行的锁定皇后在第 ? / 列，」）。
class DotSeparatedText extends StatelessWidget {
  const DotSeparatedText(this.text, {super.key, required this.style, this.separator = ' · '});
  final String text;
  final TextStyle style;
  final String separator;

  static final _term = RegExp(r'^(.+学年)(第.+学期)$');

  @override
  Widget build(BuildContext context) {
    // 分隔的“ · ”挂在前一项末尾，换行后每行左缘对齐；Wrap 不另加间距，同一行里学年与学期紧挨着。
    // 点前用不换行空格：窄处一项自己折行时“·”跟着末字走，不单独落到下一行（学期视图课程卡曾折出一行只有“·”）。
    final parts = text.split(separator);
    final items = <String>[];
    for (final (index, part) in parts.indexed) {
      final tail = index == parts.length - 1 ? '' : separator == ' · ' ? '\u00A0· ' : separator;
      final match = _term.firstMatch(part);
      if (match == null) {
        items.add('$part$tail');
      } else {
        items..add(match.group(1)!)..add('${match.group(2)}$tail');
      }
    }
    return Semantics(label: text, excludeSemantics: true, child: Wrap(children: [for (final item in items) BalancedText(item, style: style, expandWhenWrapped: true)]));
  }
}
