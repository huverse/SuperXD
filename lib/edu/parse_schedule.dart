import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:superxd/domain/schedule_store.dart';

const _weekday = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '日': 7};

// 只传递代码定义的安全原因，不把原始HTML或字段值带到日志和弹窗。
class ScheduleParseException extends FormatException {
  const ScheduleParseException(super.message);
}

class ParsedMeeting {
  const ParsedMeeting({
    required this.raw,
    required this.parsed,
    this.parity = 'all',
    this.weeks = const [],
    this.weekday,
    this.periodStart,
    this.periodEnd,
    this.place = '',
  });

  final String raw;
  final bool parsed;
  final String parity;
  final List<int> weeks;
  final int? weekday;
  final int? periodStart;
  final int? periodEnd;
  final String place;
}

class ParsedSchedule {
  const ParsedSchedule({
    required this.termLabel,
    required this.loginId,
    required this.name,
    required this.className,
    required this.courses,
  });

  final String termLabel;
  final String loginId;
  final String name;
  final String className;
  final List<CourseRecord> courses;
}

List<int> expandWeeks(String expr, String parity) {
  final weeks = <int>[];
  for (final part in expr.split(',')) {
    final matched = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(part.trim());
    if (matched == null) throw const ScheduleParseException('课程周次无法识别');
    final start = int.parse(matched.group(1)!);
    final end = matched.group(2) == null ? start : int.parse(matched.group(2)!);
    if (start < 1 || end < start || end > 60) throw const ScheduleParseException('课程周次超出有效学期范围');
    for (var week = start; week <= end; week++) {
      if (parity == 'odd' && week.isEven) continue;
      if (parity == 'even' && week.isOdd) continue;
      weeks.add(week);
    }
  }
  return weeks;
}

List<ParsedMeeting> parseMeetings(String rawText) {
  if (rawText.isEmpty) return const [];
  return rawText.split('；').map((item) => item.trim()).where((item) => item.isNotEmpty).map((raw) {
    final matched = RegExp(r'^(.+?)周(?:\((单|双)\))?\s*([一二三四五六日])\[(\d+)(?:-(\d+))?\]\s*(.*)$').firstMatch(raw);
    if (matched == null) return ParsedMeeting(raw: raw, parsed: false);
    final parity = matched.group(2) == '单' ? 'odd' : matched.group(2) == '双' ? 'even' : 'all';
    var place = matched.group(6)!.trim();
    final capacity = RegExp(r'^(.*)\((\d+)\)\s*$').firstMatch(place);
    if (capacity != null) place = capacity.group(1)!.trim();
    return ParsedMeeting(
      raw: raw,
      parsed: true,
      parity: parity,
      weeks: expandWeeks(matched.group(1)!, parity),
      weekday: _weekday[matched.group(3)!],
      periodStart: int.parse(matched.group(4)!),
      periodEnd: int.parse(matched.group(5) ?? matched.group(4)!),
      place: place,
    );
  }).toList();
}

ParsedSchedule parseScheduleHtml(String html) {
  // 测试和部分上游返回表格片段，补父table后交给HTML5解析器修复结构。
  final markup = !RegExp(r'<table\b', caseSensitive: false).hasMatch(html)
      ? html.replaceAll(RegExp(r'<tbody', caseSensitive: false), '<table><tbody').replaceAll(RegExp(r'</tbody>', caseSensitive: false), '</tbody></table>')
      : html;
  final document = html_parser.parse(markup);
  for (final br in document.querySelectorAll('br')) { br.replaceWith(dom.Text(' ')); }
  final text = _nodeText(document.body);
  final courseCountText = RegExp(r'课程门数\s*[：:]\s*(\d+)').firstMatch(text)?.group(1);
  final courseCount = courseCountText == null ? null : int.parse(courseCountText);
  final emptyRow = RegExp(r'^(?:(?:暂无|没有|无)(?:选课|课程|课表)(?:数据|信息|记录)?|未查询到(?:相关|符合条件的)?(?:课程|课表|记录)|没有符合条件的记录|没有检索到记录)[！!。\s]*$');
  final explicitEmpty = RegExp(r'(?:暂无|没有|无)(?:选课|课程|课表)(?:数据|信息|记录)?|未查询到(?:相关|符合条件的)?(?:课程|课表|记录)|没有符合条件的记录|没有检索到记录').hasMatch(text);
  if (!text.contains('学生个人课表') && !text.contains('上课时间地点') && courseCount == null) {
    throw const ScheduleParseException('课表页面结构无法识别');
  }
  final termLabel = RegExp(r'(\d{4}\s*-\s*\d{4}\s*学年.{0,12}?学期)').firstMatch(text)?.group(1) ?? '';
  final head = text;
  final rows = document.querySelectorAll('tr');
  final courseTables = document.querySelectorAll('table').where((table) => _nodeText(table).contains('上课时间地点')).toSet();
  final courses = <CourseRecord>[];
  final identities = <String>{};
  for (final row in rows) {
    final elements = row.children.where((cell) => cell.localName == 'td' || cell.localName == 'th').toList();
    final cells = elements.map(_nodeText).toList();
    final candidate = cells.length >= 12 && RegExp(r'^\[[^\]]+\]').hasMatch(cells[2]);
    final inCourseTable = courseTables.contains(row.parent) || courseTables.contains(row.parent?.parent);
    if (!candidate && !inCourseTable && !explicitEmpty && cells.length != 1) continue;
    if (cells.any((cell) => cell.contains('上课时间地点')) || elements.every((cell) => cell.localName == 'th')) continue;
    if (!candidate && cells.length == 1 && !emptyRow.hasMatch(cells.single)) {
      if (RegExp(r'权限|失败|维护|异常|错误').hasMatch(cells.single)) throw const ScheduleParseException('课表返回上游错误提示');
      continue;
    }
    if (cells.isEmpty) continue;
    if (cells.length < 12) {
      // [人工决策-2026-09-24 20:10:21] 仅明确无课提示视为空；权限或维护错误不得生成空版本覆盖本地课表。
      if (cells.length == 1 && emptyRow.hasMatch(cells.single)) continue;
      throw const ScheduleParseException('课表课程行不完整');
    }
    final course = _splitBracket(cells[2]);
    if (course.$2.isEmpty) throw const ScheduleParseException('课表课程名称缺失');
    final teacher = _splitBracket(cells[6]);
    var sectionId = cells[0];
    for (final cell in elements) {
      if (cell.id.toLowerCase().endsWith('_skbjdm')) sectionId = _nodeText(cell);
    }
    if (course.$1.isEmpty || sectionId.isEmpty) throw const ScheduleParseException('课表课程标识缺失');
    if (!identities.add('${course.$1}\u0000$sectionId')) throw const ScheduleParseException('课表包含重复教学班记录');
    final parsedMeetings = parseMeetings(cells[10]);
    if (parsedMeetings.any((meeting) => !meeting.parsed)) throw const ScheduleParseException('课表包含无法识别的上课安排');
    final meetings = parsedMeetings
        .map((meeting) => CourseMeeting(
              weekday: meeting.weekday!,
              periodStart: meeting.periodStart!,
              periodEnd: meeting.periodEnd!,
              place: meeting.place,
              weeks: meeting.weeks,
              parity: meeting.parity,
            ))
        .toList();
    courses.add(CourseRecord(
      courseCode: course.$1,
      courseName: course.$2,
      sectionId: sectionId,
      credit: cells[4].isEmpty ? null : num.parse(cells[4]),
      teacherName: teacher.$2,
      meetings: meetings,
    ));
  }
  // [人工决策-2026-09-24 21:39:35] 同课程可拆成多个教学班；课程门数核对唯一课程代码，保留全部教学班。
  if (courseCount != null && courseCount != courses.map((course) => course.courseCode).toSet().length) {
    throw const ScheduleParseException('课表课程门数与唯一课程数不一致');
  }
  if (courses.isEmpty && courseCount != 0 && !explicitEmpty) {
    throw const ScheduleParseException('课表页面缺少课程数据区');
  }
  return ParsedSchedule(
    termLabel: termLabel.replaceAll(RegExp(r'\s+'), ''),
    loginId: RegExp(r'学号：\s*(\S+)').firstMatch(head)?.group(1) ?? '',
    name: RegExp(r'姓名：\s*(\S+)').firstMatch(head)?.group(1) ?? '',
    className: RegExp(r'所在班级：\s*(.+?)\s*(?:课程门数|$)').firstMatch(head)?.group(1) ?? '',
    courses: courses,
  );
}

(String, String) _splitBracket(String value) {
  final matched = RegExp(r'^\[([^\]]+)\](.*)$').firstMatch(value);
  if (matched == null) return ('', value);
  return (matched.group(1)!, matched.group(2)!.trim());
}

String _nodeText(dom.Node? node) => (node?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
