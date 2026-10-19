import 'package:flutter/widgets.dart';

// 按行排版的长说明（协议、隐私政策、同意说明）：正文里用换行分好的几种行各有写法，扫读时一眼找得到：
// 「1. 正文」编号与正文两列，折行后与正文左缘对齐（悬挂缩进）；「登录：正文」冒号前的段内小标题半粗；
// 只有「本机：」这种以冒号结尾、没有别的标点的整行是小节标题，也半粗；空行是段落间距。文字本身原样显示。
class CampusProse extends StatelessWidget {
  const CampusProse(this.text, {super.key, this.style, this.gap = 8});
  final String text;
  final TextStyle? style;
  // 行与行之间的间距，空行再多空一份。
  final double gap;

  static final _numbered = RegExp(r'^(\d+)\.\s*(.+)$');
  static final _labelled = RegExp(r'^([^：。，；\n]{1,20})：(.+)$');
  static final _heading = RegExp(r'^[^：。，；]+：$');

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final strong = base.copyWith(fontWeight: FontWeight.w600);
    final rows = <Widget>[];
    for (final line in text.split('\n')) {
      if (line.isEmpty) {
        rows.add(SizedBox(height: gap));
        continue;
      }
      final Widget row;
      if (_numbered.firstMatch(line) case final match?) {
        row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${match[1]}. ', style: base),
          Expanded(child: _inline(match[2]!, base, strong)),
        ]);
      } else if (_heading.hasMatch(line)) {
        row = Text(line, style: strong);
      } else {
        row = _inline(line, base, strong);
      }
      rows.add(Padding(padding: EdgeInsets.only(bottom: gap), child: row));
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _inline(String line, TextStyle base, TextStyle strong) => switch (_labelled.firstMatch(line)) {
    final match? => Text.rich(TextSpan(children: [TextSpan(text: '${match[1]}：', style: strong), TextSpan(text: match[2])]), style: base),
    null => Text(line, style: base),
  };
}
