import 'dart:convert';
import 'package:uuid/uuid.dart';

import 'package:superxd/domain/week.dart';

const scheduleRevisionLimit = 100;
const syncOverwriteMessage = '继续同步将用教务课表替换当前自定义内容。每学期最多保留100个版本，保留范围内可恢复；开学日和作息不变。';

class RevisionConflict implements Exception {
  const RevisionConflict();
  String get message => '课表已有新版本，未覆盖新内容。请重新读取后再修改，或在历史版本中预览恢复。';
  @override
  String toString() => message;
}

class ScheduleConflict implements Exception {
  ScheduleConflict(this.plan);
  final SyncPlan plan;
  String get code => 'SYNC_CONFLICT';
  @override
  String toString() => plan.message ?? syncOverwriteMessage;
}

class SyncPlan {
  const SyncPlan({required this.conflict, required this.action, this.message, this.revisionId});
  final bool conflict;
  final String action;
  final String? message;
  final String? revisionId;
}

class CourseMeeting {
  CourseMeeting({
    required this.weekday,
    required this.periodStart,
    required this.periodEnd,
    required this.place,
    required this.weeks,
    this.parity = 'all',
  });

  final int weekday;
  final int periodStart;
  final int periodEnd;
  final String place;
  final List<int> weeks;
  final String parity;

  CourseMeeting copy() {
    return CourseMeeting(
      weekday: weekday,
      periodStart: periodStart,
      periodEnd: periodEnd,
      place: place,
      weeks: List<int>.from(weeks),
      parity: parity,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'weekday': weekday,
      'periodStart': periodStart,
      'periodEnd': periodEnd,
      'place': place,
      'weeks': weeks,
      'parity': parity,
    };
  }

  static CourseMeeting fromJson(Map<String, Object?> json) {
    return CourseMeeting(
      weekday: json['weekday'] as int,
      periodStart: json['periodStart'] as int,
      periodEnd: json['periodEnd'] as int,
      place: json['place'] as String? ?? '',
      weeks: (json['weeks'] as List<dynamic>? ?? const []).cast<int>(),
      parity: json['parity'] as String? ?? 'all',
    );
  }
}

class CourseRecord {
  CourseRecord({
    required this.courseCode,
    required this.courseName,
    required this.sectionId,
    required this.credit,
    required this.teacherName,
    required this.meetings,
    this.localId,
  });

  final String courseCode;
  final String courseName;
  final String sectionId;
  final num? credit;
  final String teacherName;
  final List<CourseMeeting> meetings;
  final String? localId;

  CourseRecord copy() {
    return CourseRecord(
      courseCode: courseCode,
      courseName: courseName,
      sectionId: sectionId,
      credit: credit,
      teacherName: teacherName,
      meetings: meetings.map((meeting) => meeting.copy()).toList(),
      localId: localId,
    );
  }

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'courseCode': courseCode,
      'courseName': courseName,
      'sectionId': sectionId,
      'credit': credit,
      'teacherName': teacherName,
      'meetings': meetings.map((meeting) => meeting.toJson()).toList(),
    };
    if (localId != null) json['localId'] = localId;
    return json;
  }

  static CourseRecord fromJson(Map<String, Object?> json) {
    return CourseRecord(
      courseCode: json['courseCode'] as String? ?? '',
      courseName: json['courseName'] as String? ?? '',
      sectionId: json['sectionId'] as String? ?? '',
      credit: json['credit'] as num?,
      teacherName: json['teacherName'] as String? ?? '',
      meetings: (json['meetings'] as List<dynamic>? ?? const [])
          .map((item) => CourseMeeting.fromJson((item as Map).cast<String, Object?>()))
          .toList(),
      localId: json['localId'] as String?,
    );
  }
}

class TermRef {
  const TermRef({required this.xn, required this.xq, this.label = ''});
  final String xn;
  final String xq;
  final String label;

  String get key => '$xn-$xq';

  Map<String, Object?> toJson() => {'xn': xn, 'xq': xq, 'label': label};

  static TermRef fromJson(Map<String, Object?> json) {
    return TermRef(
      xn: '${json['xn']}',
      xq: '${json['xq']}',
      label: json['label'] as String? ?? '',
    );
  }
}

class ScheduleRevision {
  ScheduleRevision({
    required this.id,
    required this.termKey,
    required this.xn,
    required this.xq,
    required this.source,
    required this.parentId,
    required this.createdAt,
    required this.summary,
    required this.courses,
    this.sequence = 0,
    this.operation = 'edit',
    this.restoredFromId,
  });

  final int sequence;
  final String operation;
  final String? restoredFromId;
  final String id;
  final String termKey;
  final String xn;
  final String xq;
  final String source;
  final String? parentId;
  final String createdAt;
  final String summary;
  final List<CourseRecord> courses;
}

class ScheduleStore {
  ScheduleStore({Map<String, TermRef>? terms}) : terms = terms ?? {};

  final Map<String, TermRef> terms;
  final List<ScheduleRevision> revisions = [];
  final Map<String, String> heads = {};
  final Map<String, String> termStarts = {};

  TermRef setTermStart(TermRef term, String startDate) {
    parseIsoDate(startDate);
    final current = terms[term.key] ?? TermRef(xn: term.xn, xq: term.xq, label: term.label);
    final next = TermRef(xn: current.xn, xq: current.xq, label: term.label.isEmpty ? current.label : term.label);
    terms[term.key] = next;
    termStarts[term.key] = startDate;
    return next;
  }

  String? termStart(TermRef term) => termStarts[term.key];

  void load({
    required List<ScheduleRevision> revisions,
    required Map<String, String> heads,
    required Map<String, String> termStarts,
    required Map<String, TermRef> terms,
  }) {
    this.revisions
      ..clear()
      ..addAll(revisions);
    this.heads
      ..clear()
      ..addAll(heads);
    this.termStarts
      ..clear()
      ..addAll(termStarts);
    this.terms
      ..clear()
      ..addAll(terms);
  }

  ScheduleRevision? head(TermRef term) {
    final id = heads[term.key];
    if (id == null) return null;
    for (final row in revisions) {
      if (row.id == id) return row;
    }
    return null;
  }

  List<ScheduleRevision> revisionsOf(TermRef term) {
    return revisions.where((row) => row.termKey == term.key).toList();
  }

  ScheduleRevision edit(TermRef term, List<CourseRecord> courses, String summary, String now) {
    final current = head(term);
    if (current != null && fingerprint(current.courses) == fingerprint(courses)) return current;
    return _append(term, courses, 'user', summary.isEmpty ? '自定义课表' : summary, now);
  }

  SyncPlan planSync(TermRef term, List<CourseRecord> incoming) {
    final current = head(term);
    if (current == null) return const SyncPlan(conflict: false, action: 'insert');
    if (fingerprint(current.courses) == fingerprint(incoming)) {
      return SyncPlan(conflict: false, action: 'unchanged', revisionId: current.id);
    }
    if (current.source == 'user') {
      return SyncPlan(conflict: true, action: 'needs_confirm', message: syncOverwriteMessage, revisionId: current.id);
    }
    return SyncPlan(conflict: false, action: 'insert', revisionId: current.id);
  }

  ScheduleRevision? commitSync(TermRef term, List<CourseRecord> incoming, {required bool confirm, required String now}) {
    final plan = planSync(term, incoming);
    if (plan.action == 'unchanged') return head(term);
    if (plan.action == 'needs_confirm' && !confirm) throw ScheduleConflict(plan);
    return _append(term, incoming, 'edu', '从教务同步', now, operation: 'sync');
  }

  ScheduleRevision restore(TermRef term, String revisionId, String now) {
    final target = revisionsOf(term).where((row) => row.id == revisionId).firstOrNull;
    if (target == null) throw StateError('找不到要回退的版本');
    final current = head(term);
    if (current != null && fingerprint(current.courses) == fingerprint(target.courses)) return current;
    // [人工决策-2026-09-25 00:19:22] 人工恢复一律产生本地版本，后续教务替换必须确认，历史不倒退覆盖。
    return _append(term, target.courses, 'user', '恢复版本 #${target.sequence}', now, operation: 'restore', restoredFromId: target.id);
  }

  ScheduleRevision _append(TermRef term, List<CourseRecord> courses, String source, String summary, String now, {String operation = 'edit', String? restoredFromId}) {
    final current = head(term);
    final row = ScheduleRevision(
      id: 'rev-${const Uuid().v4()}',
      sequence: (current?.sequence ?? 0) + 1,
      operation: operation,
      restoredFromId: restoredFromId,
      termKey: term.key,
      xn: term.xn,
      xq: term.xq,
      source: source,
      parentId: heads[term.key],
      createdAt: now,
      summary: summary,
      courses: courses.map((course) => course.copy()).toList(),
    );
    revisions.add(row);
    heads[term.key] = row.id;
    final termRows = revisionsOf(term).reversed.toList();
    final protected = {row.id, ?termRows.where((revision) => revision.source == 'edu').firstOrNull?.id};
    final keep = {...protected, ...termRows.where((revision) => !protected.contains(revision.id)).take(scheduleRevisionLimit - protected.length).map((revision) => revision.id)};
    revisions.removeWhere((revision) => revision.termKey == term.key && !keep.contains(revision.id));
    return row;
  }
}

String courseKey(CourseRecord course) {
  if (course.localId != null && course.localId!.isNotEmpty) return 'local:${course.localId}';
  final section = course.sectionId.isNotEmpty ? course.sectionId : course.courseName;
  return '${course.courseCode}\u0000$section';
}

String fingerprint(List<CourseRecord> courses) {
  final lines = courses.map((course) {
    final meetings = course.meetings.map((meeting) {
      final weeks = meeting.weeks.toSet().toList()..sort();
      return jsonEncode([meeting.weekday, meeting.periodStart, meeting.periodEnd, meeting.place.trim(), weeks]);
    }).toList()..sort();
    return jsonEncode([courseKey(course), course.courseName.trim(), course.credit, course.teacherName.trim(), meetings]);
  }).toList()..sort();
  return jsonEncode(lines);
}

List<CourseRecord> visibleCourses(List<CourseRecord> courses, ScheduleScope scope) {
  if (scope.kind == 'term' || scope.kind == 'currentTerm') {
    return courses.map((course) => course.copy()).toList();
  }
  if (scope.kind == 'week') {
    final week = scope.week;
    if (week == null) throw StateError('按周显示需要周次');
    return _keep(courses, (meeting) => meeting.weeks.contains(week));
  }
  if (scope.kind == 'day') {
    if (scope.termStartDate == null || scope.termStartDate!.isEmpty) throw StateError('按天显示需要开学日');
    if (scope.date == null || scope.date!.isEmpty) throw StateError('按天显示需要日期');
    final week = weekIndex(scope.termStartDate!, scope.date!);
    if (week < 1) return const [];
    final weekday = weekdayOf(scope.date!);
    return _keep(courses, (meeting) => meeting.weekday == weekday && meeting.weeks.contains(week));
  }
  return courses.map((course) => course.copy()).toList();
}

List<CourseRecord> _keep(List<CourseRecord> courses, bool Function(CourseMeeting meeting) match) {
  final kept = <CourseRecord>[];
  for (final course in courses) {
    final meetings = course.meetings.where(match).map((meeting) => meeting.copy()).toList();
    if (meetings.isEmpty) continue;
    kept.add(CourseRecord(
      courseCode: course.courseCode,
      courseName: course.courseName,
      sectionId: course.sectionId,
      credit: course.credit,
      teacherName: course.teacherName,
      meetings: meetings,
      localId: course.localId,
    ));
  }
  return kept;
}

class ScheduleScope {
  const ScheduleScope.day({required this.term, required this.date, required this.termStartDate})
      : kind = 'day',
        week = null;
  const ScheduleScope.week({required this.term, required this.week})
      : kind = 'week',
        date = null,
        termStartDate = null;
  const ScheduleScope.currentTerm(this.term)
      : kind = 'currentTerm',
        date = null,
        termStartDate = null,
        week = null;
  const ScheduleScope.term(this.term)
      : kind = 'term',
        date = null,
        termStartDate = null,
        week = null;

  final String kind;
  final TermRef term;
  final String? date;
  final String? termStartDate;
  final int? week;
}

List<CourseRecord> coursesFromJson(Object? raw) {
  final list = raw as List<dynamic>? ?? const [];
  return list.map((item) => CourseRecord.fromJson((item as Map).cast<String, Object?>())).toList();
}
