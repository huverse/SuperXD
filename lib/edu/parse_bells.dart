class ParsedBell {
  const ParsedBell({
    required this.period,
    required this.dayPart,
    required this.dayPartCode,
    required this.start,
    required this.end,
  });
  final int period;
  final String dayPart;
  final String dayPartCode;
  final String start;
  final String end;
}

class ParsedBells {
  const ParsedBells({required this.empty, required this.message, required this.termLabel, required this.periods});
  final bool empty;
  final String message;
  final String termLabel;
  final List<ParsedBell> periods;
}

const _dayPart = {'上午': 'morning', '下午': 'afternoon', '晚上': 'evening'};

ParsedBells parseBellsHtml(String html) {
  final title = (RegExp(r'作息时间[\s\S]{0,40}').firstMatch(html)?.group(0) ?? '').replaceAll(RegExp(r'\s+'), '');
  final termLabel = (RegExp(r'山东现代学院([^<]*作息时间)').firstMatch(html)?.group(1) ?? title).replaceAll(RegExp(r'\s+'), '');
  if (html.contains('未设置作息时间')) {
    return ParsedBells(empty: true, message: '教务系统当前学期未设置作息时间', termLabel: termLabel, periods: const []);
  }
  final periods = <ParsedBell>[];
  var dayPart = '';
  for (final row in RegExp(r'<tr[\s\S]*?</tr>', caseSensitive: false).allMatches(html)) {
    final cells = RegExp(r'<t[dh][\s\S]*?</t[dh]>', caseSensitive: false)
        .allMatches(row.group(0)!)
        .map((cell) => _text(cell.group(0)!))
        .toList();
    if (cells.isEmpty || cells[0] == '上课节次') continue;
    late final int period;
    late final String start;
    late final String end;
    if (RegExp(r'^\d+$').hasMatch(cells[0]) && cells.length >= 3) {
      period = int.parse(cells[0]);
      start = cells[1];
      end = cells[2];
    } else if (cells.length >= 4 && RegExp(r'^\d+$').hasMatch(cells[1])) {
      dayPart = cells[0];
      period = int.parse(cells[1]);
      start = cells[2];
      end = cells[3];
    } else {
      continue;
    }
    periods.add(ParsedBell(
      period: period,
      dayPart: dayPart,
      dayPartCode: _dayPart[dayPart] ?? '',
      start: start,
      end: end,
    ));
  }
  return ParsedBells(
    empty: periods.isEmpty,
    message: periods.isEmpty ? '教务系统当前学期未设置作息时间' : '',
    termLabel: termLabel,
    periods: periods,
  );
}

String _text(String html) {
  return html.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll(RegExp(r'&nbsp;|&#160;|&ensp;'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}
