import 'dart:convert';

import 'package:superxd/domain/campus_gateway.dart';
import 'package:superxd/domain/schedule_store.dart';

const gradePayloadLimit = 4 * 1024 * 1024;
const gradeRowsLimit = 1000;
const gradeTextLimit = 2000;

class GradeDataException implements Exception {
  const GradeDataException(this.message);
  final String message;
  @override
  String toString() => message;
}

Object? gradeValue(Object? value) {
  if (value == null) return null;
  if (value is num && value.isFinite) return value;
  if (value is String && value.length <= gradeTextLimit) {
    final text = value.trim();
    return text.isEmpty ? null : text;
  }
  throw const GradeDataException('成绩字段格式异常');
}

String gradeText(Object? value, {String missing = '教务未提供'}) => value == null
    ? missing
    : value is double && value == value.truncateToDouble()
    ? value.toInt().toString()
    : '$value';
num? gradeNumber(Object? value) => value is num && value.isFinite
    ? value
    : value is String && RegExp(r'^-?\d+(?:\.\d+)?$').hasMatch(value.trim())
    ? num.tryParse(value.trim())
    : null;
String _text(Object? value) {
  if (value == null) return '';
  if (value is! String || value.length > gradeTextLimit) {
    throw const GradeDataException('成绩文本格式异常');
  }
  return value;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const GradeDataException('成绩数据结构异常');
  }
  return value.cast<String, Object?>();
}

Map<String, Object?> decodeGradeJson(String payload) {
  if (payload.length > gradePayloadLimit ||
      utf8.encode(payload).length > gradePayloadLimit) {
    throw const GradeDataException('成绩数据超过容量上限');
  }
  try {
    return _map(jsonDecode(payload));
  } on FormatException catch (_, stack) {
    Error.throwWithStackTrace(const GradeDataException('成绩缓存内容损坏'), stack);
  }
}

GradeSummary gradeSummaryFromJson(Object? value) {
  final json = _map(value);
  return GradeSummary(
    category: _text(json['category']).isEmpty ? '合计' : _text(json['category']),
    earnedCredit: gradeValue(json['earnedCredit']),
    gpa: gradeValue(json['gpa']),
    averageScore: gradeValue(json['averageScore']),
    weightedAverage: gradeValue(json['weightedAverage']),
  );
}

Map<String, Object?> gradeSummaryJson(GradeSummary summary) => {
  'category': summary.category,
  'earnedCredit': summary.earnedCredit,
  'gpa': summary.gpa,
  'averageScore': summary.averageScore,
  'weightedAverage': summary.weightedAverage,
};

List<GradeCourse> _courses(Object? value) {
  if (value is! List || value.length > gradeRowsLimit) {
    throw const GradeDataException('成绩课程列表格式异常或超过1000条');
  }
  return value.map((item) {
    final json = _map(item);
    final attributes = json['attributes'] == null
        ? <String, Object?>{}
        : _map(json['attributes']);
    if (attributes.length > 20) throw const GradeDataException('课程附加字段过多');
    final name = _text(json['courseName']);
    if (name.trim().isEmpty) throw const GradeDataException('成绩课程名称缺失');
    return GradeCourse(
      courseCode: _text(json['courseCode']),
      courseName: name,
      credit: gradeValue(json['credit']),
      score: gradeValue(json['score']),
      earnedCredit: gradeValue(json['earnedCredit']),
      gradePoint: gradeValue(json['gradePoint']),
      usualScore: gradeValue(json['usualScore']),
      midtermScore: gradeValue(json['midtermScore']),
      finalScore: gradeValue(json['finalScore']),
      skillScore: gradeValue(json['skillScore']),
      totalScore: gradeValue(json['totalScore']),
      attributes: attributes.map(
        (key, value) => MapEntry(_text(key), _text(value)),
      ),
    );
  }).toList();
}

Map<String, Object?> gradeCourseJson(GradeCourse course) => {
  'courseCode': course.courseCode,
  'courseName': course.courseName,
  'credit': course.credit,
  'score': course.score,
  'earnedCredit': course.earnedCredit,
  'gradePoint': course.gradePoint,
  'usualScore': course.usualScore,
  'midtermScore': course.midtermScore,
  'finalScore': course.finalScore,
  'skillScore': course.skillScore,
  'totalScore': course.totalScore,
  'attributes': course.attributes,
};

GradesView gradesFromJson(Map<String, Object?> json, TermRef term) {
  final rawTerm = _map(json['term']);
  if (rawTerm['xn'] != term.xn || rawTerm['xq'] != term.xq) {
    throw const GradeDataException('缓存学期与请求不一致');
  }
  final student = _map(json['student']);
  final effective = _courses(json['effective']);
  final original = _courses(json['original']);
  if (json['empty'] is! bool ||
      json['empty'] != (effective.isEmpty && original.isEmpty)) {
    throw const GradeDataException('成绩空状态与内容不一致');
  }
  final rawSummaries = json['summaries'] ?? const [];
  if (rawSummaries is! List || rawSummaries.length > 50) {
    throw const GradeDataException('成绩汇总格式异常');
  }
  final scope = json['summaryScope'] ?? 'unknown';
  if (scope != 'term' && scope != 'unknown') {
    throw const GradeDataException('成绩汇总范围异常');
  }
  return GradesView(
    empty: json['empty'] as bool,
    message: _text(json['message']),
    term: TermRef(xn: term.xn, xq: term.xq, label: _text(rawTerm['label'])),
    student: SessionView(
      loginId: _text(student['loginId']),
      name: _text(student['name']),
      className: _text(student['className']),
    ),
    summary: json['summary'] == null
        ? null
        : gradeSummaryFromJson(json['summary']),
    effective: effective,
    original: original,
    summaryScope: scope as String,
    summaries: rawSummaries.map(gradeSummaryFromJson).toList(),
  );
}

Map<String, Object?> gradesJson(GradesView view) => {
  'version': 2,
  'empty': view.empty,
  'message': view.message,
  'term': view.term.toJson(),
  'student': {
    'loginId': view.student.loginId,
    'name': view.student.name,
    'className': view.student.className,
  },
  'summaryScope': view.summaryScope,
  'summary': view.summary == null ? null : gradeSummaryJson(view.summary!),
  'summaries': view.summaries.map(gradeSummaryJson).toList(),
  'effective': view.effective.map(gradeCourseJson).toList(),
  'original': view.original.map(gradeCourseJson).toList(),
};
Map<String, Object?> gradeOverviewJson(GradesView view) => {
  'version': 2,
  'empty': view.empty,
  'summaryScope': view.summaryScope,
  'summary': view.summary == null ? null : gradeSummaryJson(view.summary!),
  'effectiveCount': view.effective.length,
  'originalCount': view.original.length,
};
GradeTermOverview gradeOverviewFromJson(
  Map<String, Object?> json,
  TermRef term,
  String fetchedAt,
) {
  final effective = json['effectiveCount'];
  final original = json['originalCount'];
  final scope = json['summaryScope'];
  if (json['version'] != 2 ||
      json['empty'] is! bool ||
      effective is! int ||
      original is! int ||
      effective < 0 ||
      effective > gradeRowsLimit ||
      original < 0 ||
      original > gradeRowsLimit ||
      (scope != 'term' && scope != 'unknown')) {
    throw const GradeDataException('学年摘要格式异常');
  }
  return GradeTermOverview(
    term: term,
    cached: true,
    empty: json['empty'] as bool,
    fetchedAt: fetchedAt,
    effectiveCount: effective,
    originalCount: original,
    summaryScope: scope as String,
    summary: json['summary'] == null
        ? null
        : gradeSummaryFromJson(json['summary']),
  );
}

enum GradeFilter { all, numeric, text, unpublished }

enum GradeSort { original, high, low, name }

List<GradeCourse> selectGrades(
  List<GradeCourse> courses, {
  required bool original,
  String query = '',
  GradeFilter filter = GradeFilter.all,
  GradeSort sort = GradeSort.original,
}) {
  final search = query.trim().toLowerCase();
  Object? score(GradeCourse course) =>
      original ? course.totalScore : course.score;
  final selected = <({int index, GradeCourse course})>[];
  for (var index = 0; index < courses.length; index++) {
    final course = courses[index];
    final value = score(course);
    if (search.isNotEmpty &&
        !course.courseName.toLowerCase().contains(search) &&
        !course.courseCode.toLowerCase().contains(search)) {
      continue;
    }
    if (filter == GradeFilter.numeric && gradeNumber(value) == null ||
        filter == GradeFilter.text &&
            (value == null || gradeNumber(value) != null) ||
        filter == GradeFilter.unpublished && value != null) {
      continue;
    }
    selected.add((index: index, course: course));
  }
  selected.sort((left, right) {
    var order = 0;
    if (sort == GradeSort.name) {
      order = left.course.courseName.compareTo(right.course.courseName);
    }
    if (sort == GradeSort.high || sort == GradeSort.low) {
      final a = gradeNumber(score(left.course));
      final b = gradeNumber(score(right.course));
      order = a == null
          ? (b == null ? 0 : 1)
          : b == null
          ? -1
          : sort == GradeSort.high
          ? b.compareTo(a)
          : a.compareTo(b);
    }
    return order == 0 ? left.index.compareTo(right.index) : order;
  });
  return selected.map((row) => row.course).toList();
}
