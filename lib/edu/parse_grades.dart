import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'package:superxd/domain/grades.dart';

class ParsedGradeCourse {
  const ParsedGradeCourse({
    required this.courseCode,
    required this.courseName,
    required this.credit,
    this.score,
    this.earnedCredit,
    this.gradePoint,
    this.usualScore,
    this.midtermScore,
    this.finalScore,
    this.skillScore,
    this.totalScore,
    this.attributes = const {},
  });

  final Map<String, String> attributes;

  final String courseCode;
  final String courseName;
  final Object? credit;
  final Object? score;
  final Object? earnedCredit;
  final Object? gradePoint;
  final Object? usualScore;
  final Object? midtermScore;
  final Object? finalScore;
  final Object? skillScore;
  final Object? totalScore;
}

class GradeHeader {
  const GradeHeader({
    required this.category,
    required this.earnedCredit,
    required this.gpa,
    required this.averageScore,
    required this.weightedAverage,
  });
  final String category;
  final Object? earnedCredit;
  final Object? gpa;
  final Object? averageScore;
  final Object? weightedAverage;
}

class ParsedGrades {
  const ParsedGrades({
    required this.loginId,
    required this.name,
    required this.college,
    required this.major,
    required this.level,
    required this.className,
    required this.termLabel,
    required this.courses,
    required this.summary,
  });

  final String loginId;
  final String name;
  final String college;
  final String major;
  final String level;
  final String className;
  final String termLabel;
  final List<ParsedGradeCourse> courses;
  final List<GradeHeader> summary;
}

String buildGradeBody({
  required String kind,
  required String xn,
  required String xq,
  required String rxnj,
  required String nj,
}) {
  final xn1 = '${int.parse(xn) + 1}';
  final parts = <String>[
    'sjxz=sjxz3',
    'ysyx=$kind',
    'zx=1',
    'fx=0',
    'wz=0',
    'rxnj=$rxnj',
    'nj=$nj',
    'btnExport=%B5%BC%B3%F6',
    'xn=$xn',
    'xn1=$xn1',
    'xq=$xq',
    'ysyxS=on',
    'sjxzS=on',
    'zxC=on',
    'xsjd=1',
    'menucode_current=S40303',
  ];
  return parts.join('&');
}

ParsedGrades parseEffectiveGrades(String html) => _parse(html, original: false);
ParsedGrades parseOriginalGrades(String html) => _parse(html, original: true);

ParsedGrades _parse(String html, {required bool original}) {
  if (html.length > gradePayloadLimit) throw const FormatException('成绩页面超过容量上限');
  final document = html_parser.parse(html);
  for (final element in document.querySelectorAll('script, style')) { element.remove(); }
  for (final element in document.querySelectorAll('br')) { element.replaceWith(dom.Text(' ')); }
  for (final cell in document.querySelectorAll('td, th')) { cell.append(dom.Text(' ')); }
  final text = _text(document.body);
  if (!text.contains('学生成绩')) throw const FormatException('成绩页面结构无法识别');
  if (RegExp(r'没有访问权限|无权访问|系统维护|查询失败|服务异常|请重新登录').hasMatch(text)) throw const FormatException('成绩页面返回上游错误');
  final courses = <ParsedGradeCourse>[];
  final summary = <GradeHeader>[];
  var foundTable = false;
  for (final table in document.querySelectorAll('table').where((table) => table.querySelector('table') == null)) {
    final rows = _tableRows(table);
    var headerIndex = -1;
    List<String> headers = [];
    for (var index = 0; index < rows.length; index++) {
      final candidate = rows[index].map(_column).toList();
      if (candidate.contains('courseName') && candidate.contains('credit') && candidate.contains(original ? 'totalScore' : 'score')) { headerIndex = index; headers = candidate; break; }
    }
    if (headerIndex >= 0) {
      if (foundTable) throw const FormatException('存在多张不明确的成绩数据表');
      foundTable = true;
      final positions = <String, int>{};
      for (var index = 0; index < headers.length; index++) {
        if (headers[index].isEmpty) continue;
        if (positions.containsKey(headers[index])) throw const FormatException('成绩列头重复或合并方式未知');
        positions[headers[index]] = index;
      }
      final required = original ? ['courseName', 'credit', 'usualScore', 'midtermScore', 'finalScore', 'skillScore', 'totalScore'] : ['courseName', 'credit', 'score', 'earnedCredit', 'gradePoint'];
      if (!required.every(positions.containsKey)) throw const FormatException('成绩必需列不完整');
      for (final cells in rows.skip(headerIndex + 1)) {
        if (cells.every((cell) => cell.isEmpty) || cells.length == 1 && _empty(cells.single)) continue;
        if (cells.map(_column).toList().join('|') == headers.join('|')) continue;
        if (cells.length != headers.length) throw const FormatException('成绩数据行不完整');
        String field(String name) => positions[name] == null ? '' : cells[positions[name]!];
        if (positions.containsKey('index') && !RegExp(r'^\d+$').hasMatch(field('index'))) throw const FormatException('成绩序号无效');
        final course = _splitBracket(field('courseName'));
        if (course.$2.isEmpty) throw const FormatException('成绩课程名称缺失');
        courses.add(ParsedGradeCourse(courseCode: field('courseCode').isEmpty ? course.$1 : field('courseCode'), courseName: course.$2, credit: _numOrText(field('credit')),
          score: _numOrText(field('score')), earnedCredit: _numOrText(field('earnedCredit')), gradePoint: _numOrText(field('gradePoint')),
          usualScore: _numOrText(field('usualScore')), midtermScore: _numOrText(field('midtermScore')), finalScore: _numOrText(field('finalScore')), skillScore: _numOrText(field('skillScore')), totalScore: _numOrText(field('totalScore')),
          attributes: {for (final label in ['课程性质', '类别', '考核方式', '修读方式', '修读性质', '考试性质', '取得方式']) if (positions.containsKey(label) && field(label).isNotEmpty) label: field(label)}));
        if (courses.length > gradeRowsLimit) throw const FormatException('成绩超过1000条');
      }
    } else if (!original) {
      final index = rows.indexWhere((cells) => cells.any((cell) => _summaryColumn(cell) == 'weightedAverage'));
      if (index < 0) continue;
      final labels = rows[index].map(_summaryColumn).toList();
      final positions = {for (var index = 0; index < labels.length; index++) if (labels[index].isNotEmpty) labels[index]: index};
      if (!['gpa', 'averageScore', 'weightedAverage', 'earnedCredit'].every(positions.containsKey)) continue;
      for (final cells in rows.skip(index + 1)) {
        if (cells.every((cell) => cell.isEmpty)) continue;
        if (cells.length != labels.length) throw const FormatException('成绩汇总数据不完整');
        Object? field(String name) => _numOrText(cells[positions[name]!]);
        summary.add(GradeHeader(category: cells.first, earnedCredit: field('earnedCredit'), gpa: field('gpa'), averageScore: field('averageScore'), weightedAverage: field('weightedAverage')));
        if (summary.length > 50) throw const FormatException('成绩汇总超过容量上限');
      }
    }
  }
  // [人工决策-2026-09-25 01:48:56] 只有明确无成绩语义才写空缓存；未知、维护、权限和截断页面不得清空已同步成绩。
  if (courses.isEmpty && !_empty(text)) throw const FormatException('成绩页面未提供完整数据或明确无成绩提示');
  final declared = RegExp(r'(?:成绩记录数|记录数)[：:]\s*(\d+)').firstMatch(text)?.group(1);
  if (declared != null && int.parse(declared) != courses.length) throw const FormatException('成绩记录数与数据行数不一致');
  String pick(String label) => RegExp('$label[：:]\\s*([^\\s：:]+)').firstMatch(text)?.group(1) ?? '';
  final termLabel = RegExp(r'学年学期[：:]\s*(\d{4}\s*[-–]\s*\d{4}\s*学年\s*第?\s*[一二12]\s*学期)').firstMatch(text)?.group(1)?.replaceAll(RegExp(r'\s+'), '') ?? '';
  return ParsedGrades(loginId: pick('学号'), name: pick('姓名'), college: pick(r'院\(系\)/部'), major: pick('专业'), level: pick('培养层次'), className: pick('行政班级'), termLabel: termLabel, courses: courses, summary: summary);
}

String _text(dom.Node? node) => (node?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
bool _empty(String text) => RegExp(r'(?:没有|暂无|无)成绩(?:记录|信息|数据)?|没有检索到记录|没有符合条件的记录|(?:记录数|课程门数)[：:]\s*0(?:\D|$)').hasMatch(text);
List<List<String>> _tableRows(dom.Element table) => table.querySelectorAll('tr').map((row) => row.children.where((cell) => cell.localName == 'td' || cell.localName == 'th').map((cell) {
  final text = _text(cell);
  if (text.length > gradeTextLimit) throw const FormatException('成绩单元格超过容量上限');
  return text;
}).toList()).where((row) => row.isNotEmpty).toList();
String _column(String value) => switch (value.replaceAll(RegExp(r'\s+'), '')) {
  '序号' => 'index', '课程' || '课程名称' || '课程/环节' => 'courseName', '课程代码' || '课程编号' => 'courseCode', '学分' => 'credit',
  '成绩' || '有效成绩' => 'score', '获得学分' || '已获学分' || '取得学分' => 'earnedCredit', '绩点' => 'gradePoint',
  '平时' || '平时成绩' => 'usualScore', '期中' || '期中成绩' => 'midtermScore', '期末' || '期末成绩' => 'finalScore',
  '技能' || '技能成绩' => 'skillScore', '总评' || '总评成绩' || '综合成绩' => 'totalScore',
  '课程性质' => '课程性质', '类别' => '类别', '考核方式' => '考核方式', '修读方式' => '修读方式', '修读性质' => '修读性质', '考试性质' => '考试性质', '取得方式' => '取得方式', _ => '',
};
String _summaryColumn(String value) => switch (value.replaceAll(RegExp(r'\s+'), '')) {
  '获得学分' || '已获学分' || '取得学分' => 'earnedCredit', '平均学分绩点' || '平均绩点' || '获得平均学分绩点' => 'gpa', '平均分' || '平均成绩' => 'averageScore', '加权平均分' || '加权平均成绩' => 'weightedAverage', _ => '',
};
Object? _numOrText(String value) => value.isEmpty ? null : gradeNumber(value) ?? value;
(String, String) _splitBracket(String value) {
  final match = RegExp(r'^\[([^\]]+)\](.*)$').firstMatch(value);
  return match == null ? ('', value) : (match.group(1)!, match.group(2)!.trim());
}

